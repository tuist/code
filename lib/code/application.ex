defmodule Code.Application do
  @moduledoc """
  The supervision tree.

  Ordering matters in one place only: the cluster process joins the process
  group that makes this node visible to the others, so it starts *after* the
  replica machinery is ready. A node that advertised itself before it could
  serve would receive hints and route decisions it was not yet able to honour.

  Everything else is independent, which is a consequence of the architecture
  rather than an accident: no component owns state another one needs, so
  nothing has to be started in a particular order to be correct.
  """

  use Application

  require Logger

  alias Code.Config

  @doc "Version of the running node."
  @spec version() :: String.t()
  def version do
    case Application.spec(:code, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  @impl true
  def start(_type, _args) do
    Code.Telemetry.attach()
    Code.Telemetry.setup_opentelemetry()
    # The receive-pack hook inherits this secret from its request process. Set
    # it once during serial application startup so concurrent first pushes can
    # never race to publish different values.
    Config.hook_token()
    log_boot()
    check_ports()

    children =
      [
        {Task.Supervisor, name: Code.TaskSupervisor},
        object_store_children(),
        {Registry, keys: :unique, name: Code.ReplicaRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: Code.ReplicaSupervisor},
        # One writer per repository, batching its index updates.
        {Registry, keys: :unique, name: Code.WriterRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: Code.WriterSupervisor},
        maintenance_runtime_children(),
        maintenance_scheduler_children(),
        auth_children(),
        {Code.Auth.JWKS, []},
        # Authorization policy lives in object storage like everything else;
        # this is only its per-node cache.
        {Code.Policy, []},
        maintenance_children(),
        listener_children(),
        prom_ex_children(),
        # Last: joining the cluster is what tells other nodes this one can
        # serve, so nothing should be advertised until it can.
        cluster_children()
      ]
      |> List.flatten()

    opts = [strategy: :one_for_one, name: Code.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("code #{Code.Application.version()} ready on #{Config.node_id()} (#{node()})")
        {:ok, pid}

      error ->
        error
    end
  end

  # A port collision otherwise surfaces as `:eaddrinuse` attributed to an
  # internal child process, which says nothing about which port or what to do
  # about it. Checking first costs three socket opens and turns a puzzle into
  # an instruction.
  defp check_ports do
    if Config.start_listeners?() do
      ports =
        if Config.serve?() do
          [
            {"git and MCP", Config.git_port(), "CODE_GIT_PORT", []},
            # The hook listener binds loopback only, so the probe has to as well:
            # a port can be free on one interface and taken on another.
            {"receive-pack hook", Config.hook_port(), "CODE_HOOK_PORT", [ip: {127, 0, 0, 1}]}
          ]
        else
          []
        end

      (ports ++ [{"admin and metrics", Config.admin_port(), "CODE_ADMIN_PORT", []}])
      |> Enum.each(fn {purpose, port, variable, options} ->
        # Deliberately without `reuseaddr`: it would let this bind succeed
        # alongside the very listener we are trying to detect, which is the
        # opposite of the point.
        case :gen_tcp.listen(port, [:binary | options]) do
          {:ok, socket} ->
            :gen_tcp.close(socket)

          {:error, :eaddrinuse} ->
            Logger.error("""
            port #{port} (#{purpose}) is already in use.

            Set #{variable} to a free port, or stop whatever is listening there.
            """)

          {:error, _other} ->
            :ok
        end
      end)
    end
  end

  # The filesystem object store needs a process to serialize compare-and-swap
  # writes; S3 gets that from the service itself and needs nothing.
  defp object_store_children do
    case Config.object_store() do
      {Code.ObjectStore.Filesystem, _opts} -> [{Code.ObjectStore.Filesystem.Lock, []}]
      _ -> []
    end
  end

  defp auth_children do
    case Config.auth() do
      {Code.Auth.Webhook, opts} -> [{Code.Auth.Webhook, opts}]
      _ -> []
    end
  end

  defp maintenance_children do
    if Config.serve?() or Config.maintain?() do
      [{Code.Replica.Reaper, []}]
    else
      []
    end
  end

  # Maintenance jobs are local supervised processes. Their durable input and
  # publication point remain the object store; this registry merely prevents
  # one node from running the same expensive job twice at once.
  defp maintenance_runtime_children do
    [
      {Registry, keys: :unique, name: Code.MaintenanceRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Code.MaintenanceSupervisor}
    ]
  end

  defp listener_children do
    if Config.start_listeners?() do
      public_listeners =
        if Config.serve?() do
          [
            # Public: Git smart HTTP, MCP, OAuth discovery.
            #
            # A clone can run for many minutes and a push can be gigabytes, so the
            # read timeout is raised well above what an ordinary web listener would
            # want. Named so the metrics plugin can count live connections, which
            # is the signal an autoscaler should use.
            listener(Code.HTTP.Public,
              plug: Code.HTTP.Router,
              port: Config.git_port(),
              thousand_island_options: [
                num_acceptors: 100,
                read_timeout: :timer.minutes(30),
                transport_options: [backlog: 1024]
              ],
              # Compression is off deliberately. Bandit will gzip a response when the
              # client offers to accept it, and every git client does — but the Git
              # protocol carries packfiles, which are already compressed, so this
              # spends CPU to make responses slightly larger. Worse, git parses the
              # reference advertisement itself and stalls when it arrives encoded,
              # which presents as a push that hangs rather than an error.
              http_options: [log_protocol_errors: false, compress: false]
            ),

            # Loopback only: the pre-receive hook's callback. This endpoint can
            # commit a push, so it must not be reachable from outside the node.
            listener(Code.HTTP.Hook,
              plug: Code.HTTP.HookRouter,
              port: Config.hook_port(),
              ip: {127, 0, 0, 1}
            )
          ]
        else
          []
        end

      # Operations: health, readiness, metrics, repository administration.
      public_listeners ++
        [listener(Code.HTTP.Admin, plug: Code.HTTP.AdminRouter, port: Config.admin_port())]
    else
      []
    end
  end

  # Bandit owns its listener's registered name, so the supervisor id is the only
  # thing we set. Live connections are counted from Bandit's telemetry instead
  # of by inspecting the listener; see `Code.Telemetry.InFlight`.
  defp listener(name, opts) do
    opts =
      opts
      |> Keyword.put(:scheme, :http)
      |> Keyword.put(:startup_log, false)

    Supervisor.child_spec({Bandit, opts}, id: name)
  end

  defp prom_ex_children do
    if Config.start_listeners?(), do: [Code.PromEx], else: []
  end

  defp cluster_children do
    if Config.start_gossip?() do
      [
        # `:pg` is the membership and broadcast primitive. Distributed Erlang
        # already knows which nodes are alive and delivers messages reliably
        # between them, so there is no gossip protocol here to write or debug.
        %{id: Code.PG, start: {:pg, :start_link, [Code.Cluster.scope()]}},
        libcluster_child(),
        {Code.Cluster, []}
      ]
      |> List.flatten()
    else
      []
    end
  end

  defp maintenance_scheduler_children do
    if Config.maintenance?(), do: [{Code.Maintenance, []}], else: []
  end

  # Discovery only. libcluster's job ends once nodes can see each other;
  # membership, failure detection and message delivery are the BEAM's.
  defp libcluster_child do
    case Application.get_env(:libcluster, :topologies) do
      nil -> []
      topologies -> [{Cluster.Supervisor, [topologies, [name: Code.ClusterSupervisor]]}]
    end
  end

  defp log_boot do
    Logger.info("""
    code #{Code.Application.version()} starting
      node:         #{Config.node_id()} (#{node()})
      roles:        #{Enum.join(Config.roles(), ", ")}
      data dir:     #{Config.data_dir()}
      object store: #{Config.object_store() |> elem(0) |> inspect()}
      auth:         #{Config.auth() |> elem(0) |> inspect()}
    """)
  end
end
