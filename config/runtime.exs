import Config

# Everything a Code node needs is read from the environment, so a single
# container image can be rolled out unchanged to every replica in a cluster.
# The only genuinely per-node value is CODE_NODE_ID.
#
# This applies in any environment where CODE_S3_BUCKET is set, not only in
# production. That lets the end-to-end suite drive a node from source against
# real object storage, and lets a developer point `iex -S mix` at a real bucket
# without a separate configuration path that could drift from the real one.
if config_env() == :prod or System.get_env("CODE_S3_BUCKET") do
  get = fn key, default -> System.get_env(key, default) end

  # Kubernetes injects `<SERVICE>_PORT=tcp://host:port` for every Service in the
  # namespace, which collides with variables like CODE_ADMIN_PORT. The chart
  # disables that, but a hand-written manifest may not, and the failure is
  # otherwise a crash dump from binary_to_integer with no hint of the cause.
  port = fn key, default ->
    value = System.get_env(key, default)

    case Integer.parse(value) do
      {port, ""} ->
        port

      _ ->
        raise """
        #{key} is #{inspect(value)}, which is not a port number.

        If that looks like a URL, Kubernetes injected it: a Service whose name
        matches this variable produces `tcp://host:port`. Set
        `enableServiceLinks: false` on the pod, or set #{key} explicitly.
        """
    end
  end

  require_env = fn key ->
    System.get_env(key) ||
      raise """
      environment variable #{key} is missing.

      Code needs an S3-compatible object store to hold the write-ahead log; it
      is the source of truth for every repository this node serves.
      """
  end

  object_store =
    {
      Code.ObjectStore.S3,
      # Path style is what MinIO, Tigris and Ceph expect. Set to "false" for
      # virtual-hosted-style buckets on AWS proper.
      bucket: require_env.("CODE_S3_BUCKET"),
      endpoint: require_env.("CODE_S3_ENDPOINT"),
      region: get.("CODE_S3_REGION", "auto"),
      access_key_id: require_env.("CODE_S3_ACCESS_KEY_ID"),
      secret_access_key: require_env.("CODE_S3_SECRET_ACCESS_KEY"),
      prefix: get.("CODE_S3_PREFIX", ""),
      path_style: get.("CODE_S3_PATH_STYLE", "true") == "true"
    }

  auth_backend = get.("CODE_AUTH_BACKEND", "webhook")
  # Refuses `none` in production and names the valid choices for a typo,
  # rather than failing later with a CaseClauseError.
  Code.Config.Runtime.auth_backend!(auth_backend, config_env())
  oidc_kubernetes = get.("CODE_OIDC_KUBERNETES", "false") == "true"

  # This is deliberately public configuration for Git Credential Manager, not
  # another authentication backend. The client id identifies a public OAuth
  # client and is safe to publish; a client secret must never be configured
  # here. Keep browser login opt-in because projected Kubernetes tokens do not
  # have an interactive authorization endpoint.
  git_auth =
    Code.Auth.GitAuth.build(System.get_env("CODE_GIT_AUTH_CLIENT_ID"),
      backend: auth_backend,
      kubernetes: oidc_kubernetes,
      issuer: System.get_env("CODE_OIDC_ISSUER"),
      authorization_endpoint: System.get_env("CODE_GIT_AUTH_AUTHORIZATION_ENDPOINT"),
      token_endpoint: System.get_env("CODE_GIT_AUTH_TOKEN_ENDPOINT"),
      registration_endpoint: System.get_env("CODE_GIT_AUTH_REGISTRATION_ENDPOINT"),
      redirect_uri: get.("CODE_GIT_AUTH_REDIRECT_URI", "http://127.0.0.1"),
      scopes: System.get_env("CODE_GIT_AUTH_SCOPES"),
      username: get.("CODE_GIT_AUTH_USERNAME", "oauth2")
    )

  auth =
    case auth_backend do
      "oidc" ->
        {Code.Auth.OIDC,
         issuer: if(git_auth, do: git_auth.issuer, else: System.get_env("CODE_OIDC_ISSUER")),
         audience: require_env.("CODE_OIDC_AUDIENCE"),
         jwks_uri: System.get_env("CODE_OIDC_JWKS_URI"),
         kubernetes: oidc_kubernetes,
         namespace_grants: get.("CODE_OIDC_NAMESPACE_GRANTS", "true") == "true",
         grants_claim: get.("CODE_OIDC_GRANTS_CLAIM", "code_grants")}

      "webhook" ->
        {Code.Auth.Webhook,
         endpoint: require_env.("CODE_AUTH_ENDPOINT"),
         token: Code.Config.Runtime.secret!("CODE_AUTH_TOKEN", require_env.("CODE_AUTH_TOKEN")),
         cache_ttl_ms: String.to_integer(get.("CODE_AUTH_CACHE_TTL_MS", "30000"))}

      "static" ->
        # Raises a redacted error naming the entry's position, never its
        # contents: the value is made of secrets.
        {Code.Auth.Static, tokens: Code.Auth.Static.parse_tokens!(get.("CODE_AUTH_TOKENS", ""))}

      "none" ->
        {Code.Auth.Allow, []}
    end

  config :code,
    node_id: get.("CODE_NODE_ID", nil) || :inet.gethostname() |> elem(1) |> to_string(),
    advertise_host: get.("CODE_ADVERTISE_HOST", "127.0.0.1"),
    data_dir: get.("CODE_DATA_DIR", "/var/lib/code/repositories"),
    object_store: object_store,
    auth: auth,
    git_port: port.("CODE_GIT_PORT", "4000"),
    hook_port: port.("CODE_HOOK_PORT", "4001"),
    admin_port: port.("CODE_ADMIN_PORT", "4002"),
    gossip_port: port.("CODE_GOSSIP_PORT", "4010"),
    # Blank is refused outright: an empty admin token is not a weaker token,
    # it is no token, and the admin API can create and delete repositories.
    admin_token: Code.Config.Runtime.secret!("CODE_ADMIN_TOKEN", require_env.("CODE_ADMIN_TOKEN")),
    # All interfaces unless set. Kubernetes reaches the probes on the pod IP,
    # so binding loopback there would fail every health check; outside a
    # cluster, set this to keep the admin API off public interfaces.
    admin_ip: Code.Config.Runtime.ip!("CODE_ADMIN_IP", System.get_env("CODE_ADMIN_IP")),
    # How long listeners wait for in-flight requests on shutdown. Keep it
    # below the pod's termination grace period, minus any preStop delay.
    shutdown_timeout_ms:
      Code.Config.Runtime.non_neg_integer!(
        "CODE_SHUTDOWN_TIMEOUT_MS",
        get.("CODE_SHUTDOWN_TIMEOUT_MS", "100000")
      ),
    peers: get.("CODE_PEERS", "") |> String.split(",", trim: true),
    default_replicas: String.to_integer(get.("CODE_DEFAULT_REPLICAS", "3")),
    # How long a replica may serve a read without re-verifying the WAL index
    # against the object store. 0 means "verify every read", which is the
    # guarantee the design is built on; raise it only knowingly.
    staleness_budget_ms: String.to_integer(get.("CODE_STALENESS_BUDGET_MS", "0")),
    # Authorization is checked on every request, so unlike a repository read
    # this is not zero by default; see docs/multi-tenancy.md.
    policy_staleness_budget_ms: String.to_integer(get.("CODE_POLICY_STALENESS_BUDGET_MS", "5000")),
    # How long a cached policy may keep authorizing while object storage
    # cannot confirm it. Past this, policy grants fail closed.
    policy_max_stale_ms:
      Code.Config.Runtime.non_neg_integer!(
        "CODE_POLICY_MAX_STALE_MS",
        get.("CODE_POLICY_MAX_STALE_MS", "900000")
      ),
    compaction_entry_threshold: String.to_integer(get.("CODE_COMPACTION_ENTRY_THRESHOLD", "250")),
    compaction_bytes_threshold: String.to_integer(get.("CODE_COMPACTION_BYTES_THRESHOLD", "268435456")),
    # A node may serve, perform cache maintenance, reserve event-consumer
    # placement, or combine those capabilities. Placement uses only nodes that
    # advertise the relevant capability; the log remains authoritative
    # whichever node runs a job.
    roles: get.("CODE_ROLES", "serve,maintain,events"),
    maintenance_compaction_concurrency:
      String.to_integer(get.("CODE_MAINTENANCE_COMPACTION_CONCURRENCY", "1")),
    maintenance_lookup_concurrency: String.to_integer(get.("CODE_MAINTENANCE_LOOKUP_CONCURRENCY", "1")),
    maintenance_bundle_concurrency: String.to_integer(get.("CODE_MAINTENANCE_BUNDLE_CONCURRENCY", "1")),
    maintenance_events_concurrency: String.to_integer(get.("CODE_MAINTENANCE_EVENTS_CONCURRENCY", "4")),
    maintenance_sweep_ms: String.to_integer(get.("CODE_MAINTENANCE_SWEEP_MS", "300000")),
    idle_eviction_ms: String.to_integer(get.("CODE_IDLE_EVICTION_MS", "3600000")),
    public_url: System.get_env("CODE_PUBLIC_URL"),
    resource_identifier: System.get_env("CODE_RESOURCE_IDENTIFIER"),
    authorization_servers: get.("CODE_AUTHORIZATION_SERVERS", "") |> String.split(",", trim: true),
    git_auth: git_auth,
    tracing_enabled: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") != nil

  # Node discovery. libcluster's only job is to make nodes visible to each
  # other; from there distributed Erlang handles membership, failure detection
  # and message delivery, and rendezvous hashing handles placement. In
  # Kubernetes this reads the Endpoints of a headless Service, so scaling the
  # Deployment is the whole of "adding capacity".
  topologies =
    case get.("CODE_CLUSTER_STRATEGY", "none") do
      "kubernetes" ->
        # The headless-service DNS strategy rather than the API-based one: it
        # resolves pod addresses straight from DNS, so Code needs no
        # ServiceAccount permissions and no API access at all. One less thing
        # to grant, and one less thing that can break a deploy.
        [
          code: [
            strategy: Elixir.Cluster.Strategy.Kubernetes.DNS,
            config: [
              service: get.("CODE_HEADLESS_SERVICE", "code-headless"),
              application_name: get.("CODE_RELEASE_NAME", "code"),
              polling_interval: 5_000
            ]
          ]
        ]

      "dns" ->
        [
          code: [
            strategy: Elixir.Cluster.Strategy.DNSPoll,
            config: [
              query: require_env.("CODE_DNS_QUERY"),
              node_basename: get.("CODE_RELEASE_NAME", "code"),
              polling_interval: 5_000
            ]
          ]
        ]

      "epmd" ->
        [
          code: [
            strategy: Elixir.Cluster.Strategy.Epmd,
            config: [
              hosts: get.("CODE_PEERS", "") |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1)
            ]
          ]
        ]

      _ ->
        nil
    end

  if topologies, do: config(:libcluster, topologies: topologies)

  config :code, Code.PromEx,
    disabled: false,
    manual_metrics_start_delay: :no_delay,
    drop_metrics_groups: [],
    grafana: :disabled,
    metrics_server: :disabled

  if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
    config :opentelemetry,
      resource: [service: %{name: "code", version: Code.Application.version()}],
      span_processor: :batch,
      traces_exporter: :otlp

    config :opentelemetry_exporter,
      otlp_protocol: get.("OTEL_EXPORTER_OTLP_PROTOCOL", "http_protobuf") |> String.to_atom(),
      otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
  end
end
