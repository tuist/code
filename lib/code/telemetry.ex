defmodule Code.Telemetry do
  @moduledoc """
  Instrumentation.

  A replica's whole job is to be consistent with something it cannot see, so
  the questions an operator actually asks are unusual ones: how often does a
  read find the log unchanged, how far behind is this node, how much of a push
  is contention rather than work. Those are the things measured here.

  The most important single metric is the outcome of the conditional read on
  the WAL index. A healthy cluster is almost all `not_modified`: replicas
  confirm they are current with a metadata round trip and serve immediately. A
  rising `modified` rate means replicas are doing real catch-up work on the
  read path, which is the first thing to look at when latency climbs.

  ## Events

    * `[:code, :wal, :read]` — `duration_us`, meta `outcome`, `repo_id`
    * `[:code, :wal, :append]` — `seq`, `attempts`, meta `repo_id`
    * `[:code, :wal, :cas_retry]` — a push lost a compare-and-swap
    * `[:code, :wal, :ambiguous_commit]` — `seq`, meta `repo_id`; a lost
      compare-and-swap turned out to be this node's own write, whose reply was
      lost
    * `[:code, :wal, :compact]` — `epoch`, `packs`
    * `[:code, :wal, :pack_upload]` / `[:code, :wal, :pack_download]` —
      `bytes`, meta `repo_id`. Packs stream to and from the store, so these
      count bytes moved, not memory held.
    * `[:code, :replica, :sync]` — `duration_ms`, `packs_downloaded`,
      `entries_behind`
    * `[:code, :replica, :evict]`
    * `[:code, :object_store, :request]` — `duration_us`, meta `operation`,
      `outcome`; every access to the source of truth
    * `[:code, :http, :request]` — `duration_us`, request and response
      bytes, meta listener, method and status class
    * `[:code, :http, :exception]` — an unhandled request exception
    * `[:code, :push, :committed]` — `duration_ms`, `refs`, `packs`
    * `[:code, :push, :rejected]` — meta `reason`
    * `[:code, :git, :command]` — `duration_us`, meta `subcommand`, `status`
      (exported with a bounded `outcome` of `ok`, `error` or `timeout`)
    * `[:code, :writer, :fallback]` — meta `reason` (`exception` or `exit`);
      the preferred writer was unreachable and this node committed itself
    * `[:code, :writer, :timeout]` — a push gave up waiting for its writer
    * `[:code, :maintenance, :job]` — `duration_us`, meta `repo_id`, `kind`,
      `mode`, `outcome` (`ok`, `not_due`, `error`, `crashed`); every job,
      including ones nobody is waiting on
    * `[:code, :git, :served]` — `duration_ms`, `bytes`, meta `service`
    * `[:code, :git, :aborted]` — client vanished or stream failed
    * `[:code, :mcp, :request]` — `duration_us`, meta `method`, `outcome`
    * `[:code, :factory, :operation]` — `duration_us`, meta `operation`,
      `outcome`; durable graph-run and account-configuration coordination
    * `[:code, :auth, :authorized]` / `[:code, :auth, :denied]`
    * `[:code, :auth, :jwks, :refresh]` — `duration_us`, meta `outcome` (`ok`,
      `error`, `crashed`); the background signing-key refresh completed. A
      failing refresh does not fail requests: stale keys keep serving.
    * `[:code, :auth, :jwks, :lookup]` — meta `source` (`cache_fresh`,
      `cache_stale`, `call_path`); which path a signing-key lookup took.
      `call_path` fell through the fast in-ETS path into the GenServer and
      may or may not have blocked on I/O — correlate with `:refresh` to tell
      "issuer down" from "unknown kid".
    * `[:code, :auth, :webhook, :cache]` — meta `outcome` (`hit`, `miss`); a
      hit avoids a call to the external authority.
    * `[:code, :auth, :webhook, :call]` — `duration_us`, meta `outcome`
      (`ok`, `denied`, `timeout`, `error`); the authority itself, distinct
      from cache-served traffic.
    * `[:code, :cluster, :nodeup]` / `[:code, :cluster, :nodedown]`
    * `[:code, :repository, :created]`
  """

  require Logger
  alias OpenTelemetry.Ctx
  alias OpenTelemetry.Span
  require OpenTelemetry.Tracer

  @doc """
  Attach the log handlers.

  Deliberately sparse: a Git server under load produces enormous numbers of
  events, and logging each one turns observability into the bottleneck.
  Metrics carry the volume; logs carry the exceptions.
  """
  @spec attach() :: :ok
  def attach do
    logging_events = [
      [:code, :push, :rejected],
      [:code, :git, :aborted],
      [:code, :wal, :compact],
      [:code, :wal, :ambiguous_commit],
      [:code, :factory, :operation]
    ]

    :telemetry.detach("code-logging")
    :telemetry.detach("code-http")
    :telemetry.attach_many("code-logging", logging_events, &__MODULE__.handle_event/4, nil)

    :telemetry.attach_many(
      "code-http",
      [[:bandit, :request, :stop], [:bandit, :request, :exception]],
      &__MODULE__.handle_http_event/4,
      nil
    )

    Code.Telemetry.InFlight.attach()
    Code.Telemetry.DiskUsage.attach()
    :ok
  end

  @doc false
  def handle_event([:code, :push, :rejected], _measurements, meta, _config) do
    Logger.info("push rejected", repo_id: meta.repo_id, reason: meta.reason)
  end

  def handle_event([:code, :git, :aborted], measurements, meta, _config) do
    Logger.debug(
      "Git stream aborted",
      repo_id: meta[:repo_id],
      service: meta[:service],
      duration_ms: measurements.duration_ms,
      reason: meta[:reason]
    )
  end

  def handle_event([:code, :wal, :compact], measurements, meta, _config) do
    Logger.info("compacted write-ahead log",
      repo_id: meta.repo_id,
      epoch: measurements.epoch,
      packs: measurements.packs
    )
  end

  # Rare and harmless when it happens, since the entry is durable, but it means
  # the object store accepted a write and lost the reply, which is worth seeing.
  def handle_event([:code, :wal, :ambiguous_commit], measurements, meta, _config) do
    Logger.info("recovered a commit whose reply was lost", repo_id: meta.repo_id, seq: measurements.seq)
  end

  def handle_event([:code, :factory, :operation], measurements, %{outcome: :error} = meta, _config) do
    Logger.warning("factory operation failed",
      operation: meta.operation,
      duration_us: measurements.duration_us
    )
  end

  def handle_event([:code, :factory, :operation], _measurements, _meta, _config), do: :ok

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @doc false
  def handle_http_event([:bandit, :request, :stop], measurements, %{conn: conn, plug: plug}, _config) do
    case listener(plug) do
      nil ->
        :ok

      listener ->
        :telemetry.execute(
          [:code, :http, :request],
          %{
            duration_us: System.convert_time_unit(measurements.duration, :native, :microsecond),
            request_bytes: Map.get(measurements, :req_body_bytes, 0),
            response_bytes: Map.get(measurements, :resp_body_bytes, 0)
          },
          %{listener: listener, method: http_method(conn.method), status: status_class(conn.status)}
        )
    end
  end

  def handle_http_event([:bandit, :request, :exception], _measurements, %{conn: conn, plug: plug}, _config) do
    case listener(plug) do
      nil ->
        :ok

      listener ->
        :telemetry.execute([:code, :http, :exception], %{}, %{listener: listener})
        Logger.error("unhandled HTTP request exception", listener: listener, method: conn.method)
    end
  end

  def handle_http_event(_event, _measurements, _meta, _config), do: :ok

  @doc """
  Add attributes to the current OpenTelemetry span, if tracing is running.

  Silently does nothing when the OpenTelemetry application is not started, so tests and
  a bare `iex -S mix` need no tracing configuration.
  """
  @spec put_span_attributes(conn, map()) :: conn when conn: term()
  def put_span_attributes(conn, attributes) do
    put_span_attributes(attributes)
    conn
  end

  @doc "Add attributes to the current OpenTelemetry span."
  @spec put_span_attributes(map()) :: :ok
  def put_span_attributes(attributes) do
    if tracing?() do
      OpenTelemetry.Tracer.set_attributes(attributes)
    end

    :ok
  end

  @doc "Return the current tracing context, or nil when tracing is disabled."
  @spec context() :: Ctx.t() | nil
  def context do
    if tracing?(), do: Ctx.get_current()
  end

  @doc "Run `fun` with a tracing context received from another process."
  @spec with_context(Ctx.t() | nil, (-> result)) :: result when result: term()
  def with_context(nil, fun), do: fun.()

  def with_context(context, fun) do
    if tracing?() do
      token = Ctx.attach(context)

      try do
        fun.()
      after
        Ctx.detach(token)
      end
    else
      fun.()
    end
  end

  @doc "Add a bounded outcome attribute to the active span."
  @spec put_span_outcome(term()) :: term()
  def put_span_outcome(result) do
    outcome = outcome(result)

    if tracing?() do
      OpenTelemetry.Tracer.set_attribute("code.outcome", Atom.to_string(outcome))

      if outcome == :error do
        OpenTelemetry.Tracer.set_status(:error, "operation failed")
      end
    end

    result
  end

  @doc """
  Run `fun` inside a span named `name`.

  Used on the paths where the interesting latency is: catching a replica up,
  and committing a push.
  """
  @spec span(String.t(), map(), (-> result)) :: result when result: term()
  def span(name, attributes, fun) do
    if tracing?() do
      OpenTelemetry.Tracer.with_span name, %{attributes: attributes} do
        log_metadata = Logger.metadata()
        Logger.metadata(Span.hex_span_ctx(OpenTelemetry.Tracer.current_span_ctx()))

        try do
          fun.()
        after
          Logger.reset_metadata(log_metadata)
        end
      end
    else
      fun.()
    end
  end

  defp tracing?, do: Application.get_env(:code, :tracing_enabled, false)

  @doc """
  Configure OpenTelemetry instrumentation.

  Bandit's instrumentation is attached here rather than in configuration so
  that a node with no OTel exporter configured simply does not trace, instead
  of failing to boot.
  """
  @spec setup_opentelemetry() :: :ok
  def setup_opentelemetry do
    if Application.get_env(:code, :tracing_enabled, false) do
      # Public clients can send arbitrary trace headers. Link their context for
      # correlation, but do not let it become the parent of this service's work.
      :ok = OpentelemetryBandit.setup(public_endpoint: true)
      Logger.info("OpenTelemetry tracing enabled")
    end

    :ok
  rescue
    error ->
      Logger.warning("could not start OpenTelemetry instrumentation", reason: error)
      :ok
  end

  defp listener({Code.HTTP.Router, _opts}), do: :public
  defp listener({Code.HTTP.AdminRouter, _opts}), do: :admin
  defp listener({Code.HTTP.HookRouter, _opts}), do: :hook
  defp listener(_plug), do: nil

  defp http_method("GET"), do: :get
  defp http_method("POST"), do: :post
  defp http_method("PUT"), do: :put
  defp http_method("PATCH"), do: :patch
  defp http_method("DELETE"), do: :delete
  defp http_method("HEAD"), do: :head
  defp http_method("OPTIONS"), do: :options
  defp http_method(_method), do: :other

  defp status_class(status) when status in 100..199, do: :"1xx"
  defp status_class(status) when status in 200..299, do: :"2xx"
  defp status_class(status) when status in 300..399, do: :"3xx"
  defp status_class(status) when status in 400..499, do: :"4xx"
  defp status_class(status) when status in 500..599, do: :"5xx"
  defp status_class(_status), do: :unknown

  defp outcome(:ok), do: :ok
  defp outcome({:ok, _}), do: :ok
  defp outcome({:ok, _, _}), do: :ok
  defp outcome({:error, :not_found}), do: :not_found
  defp outcome({:error, :precondition_failed}), do: :precondition_failed
  defp outcome({:error, _}), do: :error
  defp outcome(_), do: :ok
end
