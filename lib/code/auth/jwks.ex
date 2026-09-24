defmodule Code.Auth.JWKS do
  @moduledoc """
  Caches the signing keys used to verify tokens.

  Keys are public, so caching them is a latency and availability concern rather
  than a secrecy one: a node that cannot reach the issuer should keep serving
  with the keys it already has instead of failing every request. The cache
  therefore has a refresh interval, not an expiry — stale keys are preferred to
  no keys, and a key that has genuinely been retired stops appearing in tokens
  anyway.

  An unrecognised key id triggers a refetch, rate-limited by a cooldown so that
  a stream of tokens signed by a key that will never exist cannot be turned
  into a denial-of-service against the issuer.

  ## The request path never waits on the network for a known key

  Keys and the discovery document live in an ETS table that request processes
  read directly. A lookup that finds its key returns immediately, even when the
  cache is due for a refresh; the refresh is started in the background and the
  old keys keep serving until a replacement has been fetched *and validated*.

  Only a lookup that cannot be answered at all, an unknown key id or a cold
  cache, waits for a fetch, and that wait is bounded by `:fetch_timeout_ms`.
  Concurrent waiters share one fetch. The owning process never performs
  network I/O itself, so a slow issuer cannot turn this cache into a
  serialisation point for every authenticated request on the node.

  ## A bad response never replaces good keys

  A `200` whose body is not JSON, has no `keys`, or contains no usable key is
  an error, not an empty key set. Individual keys that cannot be parsed are
  skipped rather than allowed to crash the cache; if nothing usable remains,
  the previous keys stay in place.

  ## Fetching from a Kubernetes API server

  A cluster's own issuer is not a public endpoint, and treating it like one
  fails twice over: its certificate is signed by the cluster CA, which nothing
  else trusts, and its discovery document requires authentication. A plain GET
  gets a TLS failure or a `401`.

  So when Kubernetes discovery is **explicitly selected** (`kubernetes: true`
  and no configured issuer), requests to the API server carry the cluster CA
  for verification and the pod's own service account token as a bearer
  credential. The token is a credential for the cluster, so it is attached
  only to the discovery endpoint and to the key-set address that endpoint
  itself published, never to a configured external issuer, and never over
  plain HTTP. The pod needs `automountServiceAccountToken` and the
  `system:service-account-issuer-discovery` role, which the chart grants when
  it is configured for in-cluster OIDC.

  The issuer is discovered rather than assumed for the same reason. It is
  commonly `https://kubernetes.default.svc.cluster.local` and not the
  `https://kubernetes.default.svc` the endpoint is reached at, and a mismatch
  rejects every token with an issuer error that looks nothing like its cause.
  """

  use GenServer

  require Logger

  @refresh_interval :timer.minutes(15)
  @refetch_cooldown :timer.seconds(30)
  @fetch_timeout :timer.seconds(5)

  @kubernetes_ca "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  @kubernetes_token "/var/run/secrets/kubernetes.io/serviceaccount/token"
  @kubernetes_endpoint "https://kubernetes.default.svc"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Return the JWK for `kid`.

  Served from the cache without contacting the owning process when the key is
  known. A stale cache is refreshed in the background.
  """
  @spec fetch(String.t() | nil, keyword()) :: {:ok, term()} | {:error, term()}
  def fetch(kid, config) do
    server = server(config)

    with {:ok, keys, fetched_at} <- cached_keys(server, config),
         jwk when not is_nil(jwk) <- lookup(keys, kid) do
      if elapsed?(fetched_at, now(), refresh_interval(config)), do: GenServer.cast(server, {:refresh, config})
      {:ok, jwk}
    else
      _ -> call(server, {:fetch, kid, config}, config)
    end
  end

  @doc """
  The issuer this deployment should expect in a token's `iss` claim.

  Returns the configured issuer when there is one. Otherwise it is read from
  the discovery document and cached, because Kubernetes is reached at
  `kubernetes.default.svc` but issues tokens naming
  `kubernetes.default.svc.cluster.local` — configuring the address you connect
  to would reject every token, with an error that looks nothing like its cause.
  """
  @spec issuer(keyword()) :: {:ok, String.t()} | {:error, term()}
  def issuer(config) do
    case Keyword.get(config, :issuer) do
      configured when is_binary(configured) and configured != "" ->
        {:ok, configured}

      _ ->
        server = server(config)

        case cached_document(server, config) do
          {:ok, document} -> issuer_of(document)
          :miss -> call(server, {:issuer, config}, config)
        end
    end
  end

  defp server(config), do: Keyword.get(config, :server, __MODULE__)

  # A cold cache waits for one fetch, bounded: a discovery document and a key
  # set, each under the fetch timeout, plus a margin for the reply.
  defp call(server, message, config) do
    case GenServer.whereis(server) do
      nil ->
        {:error, :jwks_unavailable}

      pid ->
        try do
          GenServer.call(pid, message, 2 * fetch_timeout(config) + 1_000)
        catch
          :exit, _reason -> {:error, :jwks_timeout}
        end
    end
  end

  # ----------------------------------------------------------------------
  # Server
  # ----------------------------------------------------------------------

  @impl true
  # `nil` rather than `0` for "never". Erlang's monotonic clock has an
  # arbitrary origin and on Linux starts at a large *negative* value, so `now -
  # 0` is negative and every "has enough time passed?" test answers no. The
  # effect here was that the cooldown never elapsed, the keys were never
  # fetched, and every token was rejected as signed by an unknown key — on
  # Linux only, which is to say in production only.
  def init(opts) do
    table =
      :ets.new(Keyword.get(opts, :name, __MODULE__), [:named_table, :protected, :set, read_concurrency: true])

    {:ok, %{table: table, last_attempt: nil, last_error: nil, task: nil, waiters: []}}
  end

  @impl true
  def handle_call({:fetch, kid, config} = request, from, state) do
    case cached_keys(state.table, config) do
      {:ok, keys, _at} when is_map_key(keys, kid) or (is_nil(kid) and map_size(keys) == 1) ->
        {:reply, {:ok, lookup(keys, kid)}, state}

      _ ->
        wait_or_reply(request, from, config, state)
    end
  end

  def handle_call({:issuer, config} = request, from, state) do
    case cached_document(state.table, config) do
      {:ok, document} -> {:reply, issuer_of(document), state}
      :miss -> wait_or_reply(request, from, config, state)
    end
  end

  @impl true
  def handle_cast({:refresh, config}, state) do
    {:noreply, maybe_start(state, config)}
  end

  @impl true
  def handle_info({ref, result}, %{task: {ref, config}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, complete(state, config, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: {ref, config}} = state) do
    {:noreply, complete(state, config, %{document: nil, keys: {:error, {:refresh_crashed, reason}}})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Join the fetch in progress, start one if the cooldown allows, or answer
  # from what is cached.
  defp wait_or_reply(request, from, config, state) do
    state = maybe_start(state, config)

    if state.task do
      {:noreply, %{state | waiters: [{from, request} | state.waiters]}}
    else
      {:reply, answer(request, state), state}
    end
  end

  defp maybe_start(%{task: nil} = state, config) do
    now = now()

    if elapsed?(state.last_attempt, now, refetch_cooldown(config)) do
      document =
        case cached_document(state.table, config) do
          {:ok, document} -> document
          :miss -> nil
        end

      task = Task.Supervisor.async_nolink(task_supervisor(), fn -> load(config, document) end)
      %{state | task: {task.ref, config}, last_attempt: now}
    else
      state
    end
  end

  defp maybe_start(state, _config), do: state

  defp task_supervisor do
    if Process.whereis(Code.TaskSupervisor), do: Code.TaskSupervisor, else: start_fallback_supervisor()
  end

  # Only reached on a bare VM without the application's task supervisor.
  defp start_fallback_supervisor do
    {:ok, pid} = Task.Supervisor.start_link()
    pid
  end

  defp complete(state, config, %{document: document, keys: keys}) do
    signature = config_signature(config)
    if document, do: :ets.insert(state.table, {{:document, signature}, document})

    state =
      case keys do
        {:ok, keys} ->
          :ets.insert(state.table, {{:keys, signature}, keys, now()})
          Logger.debug("code: loaded #{map_size(keys)} signing key(s)")
          %{state | last_error: nil}

        {:error, reason} ->
          # Keep serving with what we have. Losing the issuer, or the issuer
          # publishing garbage, should not take the Git server down with it.
          Logger.warning("could not refresh signing keys", reason: inspect(reason), operation: "jwks_refresh")
          %{state | last_error: reason}
      end

    for {from, request} <- Enum.reverse(state.waiters), do: GenServer.reply(from, answer(request, state))

    %{state | task: nil, waiters: []}
  end

  defp answer({:fetch, kid, config}, state) do
    case cached_keys(state.table, config) do
      {:ok, keys, _at} ->
        case lookup(keys, kid) do
          nil -> {:error, {:unknown_key, kid}}
          jwk -> {:ok, jwk}
        end

      :miss ->
        {:error, state.last_error || {:unknown_key, kid}}
    end
  end

  defp answer({:issuer, config}, state) do
    case cached_document(state.table, config) do
      {:ok, document} -> issuer_of(document)
      :miss -> {:error, state.last_error || :no_discovery_document}
    end
  end

  # ----------------------------------------------------------------------
  # Cache
  # ----------------------------------------------------------------------

  defp cached_keys(table, config) do
    case :ets.lookup(table, {:keys, config_signature(config)}) do
      [{_key, keys, at}] -> {:ok, keys, at}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cached_document(table, config) do
    case :ets.lookup(table, {:document, config_signature(config)}) do
      [{_key, document}] -> {:ok, document}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  # Keyed by the configuration it came from: a node pointed at a different
  # issuer must not keep answering from the previous one's keys or document.
  defp config_signature(config) do
    :erlang.phash2(Keyword.take(config, [:issuer, :jwks_uri, :kubernetes, :discovery_endpoint]))
  end

  defp issuer_of(%{"issuer" => issuer}) when is_binary(issuer) and issuer != "", do: {:ok, issuer}
  defp issuer_of(_document), do: {:error, :no_issuer_in_discovery}

  # Never having happened counts as long enough ago.
  defp elapsed?(nil, _now, _interval), do: true
  defp elapsed?(at, now, interval), do: now - at > interval

  defp now, do: System.monotonic_time(:millisecond)

  defp refresh_interval(config), do: Keyword.get(config, :refresh_interval_ms, @refresh_interval)
  defp refetch_cooldown(config), do: Keyword.get(config, :refetch_cooldown_ms, @refetch_cooldown)
  defp fetch_timeout(config), do: Keyword.get(config, :fetch_timeout_ms, @fetch_timeout)

  # A JWKS with exactly one key is allowed to omit `kid`, and some issuers do.
  defp lookup(keys, nil) when map_size(keys) == 1, do: keys |> Map.values() |> List.first()
  defp lookup(keys, kid), do: Map.get(keys, kid)

  # ----------------------------------------------------------------------
  # Fetching. Runs in a task, never in the owning process.
  # ----------------------------------------------------------------------

  defp load(config, document) do
    case ensure_document(config, document) do
      {:ok, document} ->
        %{document: document, keys: load_keys(config, document)}

      {:error, reason} ->
        # Without a document there may still be a configured key-set address.
        %{document: nil, keys: load_keys(config, nil, reason)}
    end
  end

  defp load_keys(config, document, document_error \\ nil) do
    with {:ok, url, trusted?} <- jwks_url(config, document, document_error),
         {:ok, %{status: 200, body: body}} <- get(url, config, trusted?) do
      parse_keys(body)
    else
      {:ok, %{status: status}} -> {:error, {:jwks_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Fetched once and kept: it names both the signing keys and the issuer, and
  # both change far less often than the keys themselves.
  defp ensure_document(config, document) when is_map(document) do
    if needs_document?(config), do: {:ok, document}, else: {:ok, nil}
  end

  defp ensure_document(config, nil) do
    if needs_document?(config), do: fetch_document(config), else: {:ok, nil}
  end

  defp needs_document?(config) do
    blank?(Keyword.get(config, :jwks_uri)) or kubernetes_discovery?(config)
  end

  defp fetch_document(config) do
    with {:ok, url} <- discovery_url(config),
         {:ok, %{status: 200, body: body}} <- get(url, config, kubernetes_discovery?(config)),
         {:ok, document} <- decode_map(body) do
      {:ok, document}
    else
      {:ok, %{status: status}} -> {:error, {:discovery_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp discovery_url(config) do
    issuer = Keyword.get(config, :issuer)

    cond do
      not blank?(issuer) ->
        {:ok, String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"}

      kubernetes_discovery?(config) ->
        {:ok, String.trim_trailing(kubernetes_endpoint(config), "/") <> "/.well-known/openid-configuration"}

      true ->
        {:error, :no_jwks_configured}
    end
  end

  # Either the JWKS URI is configured directly, or it comes from a discovery
  # document — the issuer's, or in a cluster the API server's. The second
  # element says whether cluster credentials may accompany the request.
  defp jwks_url(config, document, document_error) do
    configured = Keyword.get(config, :jwks_uri)

    cond do
      not blank?(configured) ->
        {:ok, configured,
         kubernetes_discovery?(config) and same_host?(configured, kubernetes_endpoint(config))}

      match?(%{"jwks_uri" => uri} when is_binary(uri) and uri != "", document) ->
        # A key-set address the API server published over a verified,
        # authenticated connection is as trustworthy as the server itself.
        {:ok, document["jwks_uri"], kubernetes_discovery?(config)}

      is_map(document) ->
        {:error, :no_jwks_uri_in_discovery}

      true ->
        {:error, document_error || :no_jwks_configured}
    end
  end

  # Kubernetes discovery must be asked for. Inferring it from a mounted token
  # would send the pod's credential wherever the key source points.
  defp kubernetes_discovery?(config) do
    Keyword.get(config, :kubernetes, false) == true and blank?(Keyword.get(config, :issuer))
  end

  defp kubernetes_endpoint(config), do: Keyword.get(config, :discovery_endpoint, @kubernetes_endpoint)

  defp same_host?(a, b), do: URI.parse(a).host == URI.parse(b).host

  # Bounded: the owning process never waits on this, but a waiter does, and an
  # issuer that accepts a connection and never answers must not hold a
  # request for longer than its own timeout.
  defp get(url, config, trusted?) do
    if trusted? and URI.parse(url).scheme != "https" do
      {:error, :insecure_kubernetes_endpoint}
    else
      timeout = fetch_timeout(config)

      options =
        [retry: false, receive_timeout: timeout]
        |> put_transport(timeout, ca_cert_file(config, trusted?))
        |> put_bearer(if(trusted?, do: token_file(config)))

      Req.get(url, options)
    end
  rescue
    error -> {:error, {:request_failed, Exception.message(error)}}
  end

  defp put_transport(options, timeout, nil), do: Keyword.put(options, :connect_options, timeout: timeout)

  defp put_transport(options, timeout, path) do
    Keyword.put(options, :connect_options, timeout: timeout, transport_opts: [cacertfile: path])
  end

  defp put_bearer(options, nil), do: options

  defp put_bearer(options, path) do
    case File.read(path) do
      {:ok, token} -> Keyword.put(options, :headers, [{"authorization", "Bearer " <> String.trim(token)}])
      {:error, _} -> options
    end
  end

  # An explicitly configured CA applies to every request, since it is public
  # material. The cluster CA is only a default for cluster requests.
  defp ca_cert_file(config, trusted?) do
    case Keyword.get(config, :ca_cert_file) do
      nil -> if trusted? and File.exists?(@kubernetes_ca), do: @kubernetes_ca
      path -> path
    end
  end

  defp token_file(config) do
    case Keyword.get(config, :token_file) do
      nil -> if File.exists?(@kubernetes_token), do: @kubernetes_token
      path -> path
    end
  end

  defp decode_map(body) when is_map(body), do: {:ok, body}

  defp decode_map(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_discovery_document}
    end
  end

  defp decode_map(_body), do: {:error, :invalid_discovery_document}

  defp parse_keys(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> parse_keys(decoded)
      _ -> {:error, :invalid_jwks}
    end
  end

  defp parse_keys(%{"keys" => keys}) when is_list(keys) do
    case Enum.flat_map(keys, &to_jwk/1) do
      [] -> {:error, :empty_jwks}
      parsed -> {:ok, Map.new(parsed)}
    end
  end

  defp parse_keys(_body), do: {:error, :invalid_jwks}

  # Only public signing keys of the kinds the verifier accepts. Anything else,
  # including a key JOSE cannot parse, is skipped rather than crashing the
  # cache or displacing the keys that do work.
  @signing_key_types ~w(RSA EC)

  defp to_jwk(%{"kty" => kty} = key) when kty in @signing_key_types do
    kid = key["kid"]

    with true <- is_nil(kid) or is_binary(kid),
         true <- key["use"] in [nil, "sig"],
         true <- Enum.all?(required_members(kty), &is_binary(key[&1])),
         %JOSE.JWK{kty: {_module, _material}} = jwk <- JOSE.JWK.from_map(key) do
      [{kid, jwk}]
    else
      # JOSE builds a key with no material from a map missing its members,
      # rather than raising, so completeness is checked before and after.
      _ -> []
    end
  rescue
    _ -> []
  catch
    _kind, _reason -> []
  end

  defp to_jwk(_key), do: []

  defp required_members("RSA"), do: ["n", "e"]
  defp required_members("EC"), do: ["crv", "x", "y"]

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
