defmodule Code.Auth.JWKSFailureTest do
  @moduledoc """
  What the key cache does when the issuer misbehaves: answers garbage, answers
  slowly, publishes a key nobody can parse, or is somewhere a service account
  token must not be sent.

  Real HTTP throughout, against an issuer whose behaviour each test switches.
  """

  use ExUnit.Case, async: true

  alias Code.Auth.JWKS

  defmodule Issuer do
    @moduledoc false
    import Plug.Conn

    def init(agent), do: agent

    def call(conn, agent) do
      %{mode: mode, keys: keys, test: test} = Agent.get(agent, & &1)
      send(test, {:issuer_request, conn.request_path, get_req_header(conn, "authorization")})
      respond(conn, conn.request_path, mode, keys)
    end

    defp respond(conn, "/.well-known/openid-configuration", _mode, _keys) do
      issuer = "http://127.0.0.1:#{conn.port}"
      json(conn, %{"issuer" => issuer, "jwks_uri" => issuer <> "/keys"})
    end

    defp respond(conn, "/keys", :ok, keys), do: json(conn, %{"keys" => keys})
    defp respond(conn, "/keys", :garbage, _keys), do: send_resp(conn, 200, "<html>maintenance</html>")
    defp respond(conn, "/keys", :no_keys, _keys), do: json(conn, %{"something" => "else"})
    defp respond(conn, "/keys", :empty, _keys), do: json(conn, %{"keys" => []})

    defp respond(conn, "/keys", :slow, keys) do
      Process.sleep(1_500)
      json(conn, %{"keys" => keys})
    end

    defp respond(conn, _path, _mode, _keys), do: send_resp(conn, 404, "")

    defp json(conn, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(body))
    end
  end

  setup do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    public = Map.merge(public, %{"kid" => "test-key", "alg" => "RS256", "use" => "sig"})

    test = self()
    agent = start_supervised!({Agent, fn -> %{mode: :ok, keys: [public], test: test} end})

    listener =
      start_supervised!(
        {Bandit, plug: {Issuer, agent}, scheme: :http, port: 0, startup_log: false},
        id: :issuer
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    name = :"jwks_failure_#{:erlang.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {JWKS, :start_link, [[name: name]]}})

    {:ok,
     agent: agent,
     public: public,
     port: port,
     server: name,
     config: [issuer: "http://127.0.0.1:#{port}", server: name]}
  end

  defp mode(agent, mode), do: Agent.update(agent, &%{&1 | mode: mode})
  defp keys(agent, keys), do: Agent.update(agent, &%{&1 | keys: keys})

  # Every lookup is due a refresh, and nothing rate-limits it.
  defp eager(config), do: config ++ [refresh_interval_ms: -1, refetch_cooldown_ms: -1]

  defp await_keys_request do
    assert_receive {:issuer_request, "/keys", _auth}, 5_000
  end

  # The refresh runs in a task; the server records it until the result lands.
  defp await_idle(server, attempts \\ 200) do
    cond do
      is_nil(:sys.get_state(server).task) -> :ok
      attempts == 0 -> flunk("refresh never completed")
      true -> Process.sleep(10) && await_idle(server, attempts - 1)
    end
  end

  defp flush_requests do
    receive do
      {:issuer_request, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end

  describe "a bad refresh never replaces good keys" do
    for bad <- [:garbage, :no_keys, :empty] do
      test "#{bad}", %{agent: agent, config: config, server: server} do
        config = eager(config)
        assert {:ok, _} = JWKS.fetch("test-key", config)
        flush_requests()

        mode(agent, unquote(bad))
        # Served from cache; the stale entry schedules a refresh that fails.
        assert {:ok, _} = JWKS.fetch("test-key", config)
        await_keys_request()
        # Let the refresh finish before asking again.
        await_idle(server)

        assert {:ok, _} = JWKS.fetch("test-key", config)
        assert Process.alive?(GenServer.whereis(server))
      end
    end
  end

  test "a key that cannot be parsed is skipped, not fatal", %{
    agent: agent,
    public: public,
    config: config,
    server: server
  } do
    keys(agent, [
      %{"kty" => "RSA", "kid" => "broken"},
      %{"kty" => "oct", "kid" => "symmetric", "k" => "c2VjcmV0"},
      public
    ])

    assert {:ok, _} = JWKS.fetch("test-key", config)
    assert {:error, {:unknown_key, "broken"}} = JWKS.fetch("broken", eager(config))
    assert {:error, {:unknown_key, "symmetric"}} = JWKS.fetch("symmetric", eager(config))
    assert Process.alive?(GenServer.whereis(server))
  end

  test "a key set with nothing usable is an error", %{agent: agent, config: config, server: server} do
    keys(agent, [%{"kty" => "RSA", "kid" => "broken"}])

    assert {:error, :empty_jwks} = JWKS.fetch("broken", config)
    assert Process.alive?(GenServer.whereis(server))
  end

  test "a slow issuer does not block lookups of keys already held", %{agent: agent, config: config} do
    config = eager(config)
    assert {:ok, _} = JWKS.fetch("test-key", config)

    mode(agent, :slow)

    # Every one of these is stale and schedules a refresh against an issuer
    # that takes 1.5 s to answer. None of them waits for it.
    {elapsed_us, results} =
      :timer.tc(fn ->
        1..20
        |> Task.async_stream(fn _ -> JWKS.fetch("test-key", config) end, max_concurrency: 20)
        |> Enum.map(fn {:ok, result} -> result end)
      end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert elapsed_us < 500_000, "lookups took #{div(elapsed_us, 1000)} ms"
  end

  test "a cold fetch is bounded by the fetch timeout", %{agent: agent, config: config} do
    mode(agent, :slow)

    {elapsed_us, result} = :timer.tc(fn -> JWKS.fetch("test-key", config ++ [fetch_timeout_ms: 200]) end)

    assert {:error, _reason} = result
    assert elapsed_us < 1_400_000, "fetch took #{div(elapsed_us, 1000)} ms"
  end

  describe "cluster credentials" do
    setup do
      path = Path.join(System.tmp_dir!(), "code-sa-token-#{:erlang.unique_integer([:positive])}")
      File.write!(path, "service-account-token\n")
      on_exit(fn -> File.rm(path) end)
      {:ok, token_file: path}
    end

    test "are never sent to a configured issuer", %{config: config, token_file: token_file} do
      # Even with a token file configured and Kubernetes enabled: a configured
      # issuer is somebody else's server.
      config = config ++ [token_file: token_file, kubernetes: true]

      assert {:ok, _} = JWKS.fetch("test-key", config)

      assert_received {:issuer_request, "/.well-known/openid-configuration", []}
      assert_received {:issuer_request, "/keys", []}
    end

    test "are not sent unless Kubernetes discovery is selected", %{
      port: port,
      server: server,
      token_file: token_file
    } do
      # A key-set address with no issuer and no Kubernetes selection: the
      # token file exists, but nothing asked for it to be used.
      config = [server: server, jwks_uri: "http://127.0.0.1:#{port}/keys", token_file: token_file]

      assert {:ok, _} = JWKS.fetch("test-key", config)
      assert_received {:issuer_request, "/keys", []}
    end

    test "are never sent over plain HTTP", %{port: port, server: server, token_file: token_file} do
      config = [
        server: server,
        kubernetes: true,
        discovery_endpoint: "http://127.0.0.1:#{port}",
        token_file: token_file
      ]

      assert {:error, :insecure_kubernetes_endpoint} = JWKS.issuer(config)
      refute_received {:issuer_request, _, _}
    end
  end
end
