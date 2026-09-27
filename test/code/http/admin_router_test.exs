defmodule Code.HTTP.AdminRouterTest do
  @moduledoc """
  The admin API can create and delete repositories and rewrite authorization
  policy, so these tests are about who gets in: a missing, empty or
  whitespace token must never be the thing that opens it.
  """

  use Code.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Code.Config
  alias Code.HTTP.AdminRouter

  @token "admin-secret-token"

  setup %{namespace: namespace} do
    configure(admin_token: @token)
    on_exit(fn -> Code.Policy.invalidate(namespace) end)
    {:ok, account: namespace}
  end

  defp configure(overrides) do
    Config.put_overrides(Map.merge(Config.overrides(), Map.new(overrides)))
  end

  defp request(method, path, opts \\ []) do
    body = Keyword.get(opts, :json)

    conn =
      if body do
        conn(method, path, JSON.encode!(body)) |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn =
      case Keyword.get(opts, :authorization) do
        nil -> conn
        value -> put_req_header(conn, "authorization", value)
      end

    AdminRouter.call(conn, AdminRouter.init([]))
  end

  describe "retention" do
    test "settings and storage reports require an administrator", %{repo: repo} do
      {:ok, _} = Code.WAL.create(repo)

      assert request(:get, "/retention/#{repo}").status == 401
      assert request(:put, "/retention/#{repo}", json: %{days: 30}).status == 401

      changed = request(:put, "/retention/#{repo}", json: %{days: 30}, authorization: "Bearer #{@token}")
      assert changed.status == 200
      assert JSON.decode!(changed.resp_body)["effective"] == 30

      report = request(:get, "/retention/#{repo}", authorization: "Bearer #{@token}")
      assert report.status == 200
      body = JSON.decode!(report.resp_body)
      assert body["policy"]["dry_run_only"]
      assert body["policy"]["effective"] == 30
      assert body["eligible"] == %{"objects" => 0, "bytes" => 0}
    end

    test "damaged history and invalid deployment defaults return stable server errors", %{repo: repo} do
      {:ok, index} = Code.WAL.create(repo)

      broken = %{
        index
        | base: %{index.base | history_key: Code.WAL.history_key(repo, 1, String.duplicate("a", 64))}
      }

      {:ok, _} = Code.ObjectStore.put(Code.WAL.index_key(repo), Code.WAL.Index.encode(broken))
      response = request(:get, "/retention/#{repo}", authorization: "Bearer #{@token}")
      assert response.status == 500
      assert JSON.decode!(response.resp_body)["error"] == "history_incomplete"
      {:ok, _} = Code.ObjectStore.put(Code.WAL.index_key(repo), Code.WAL.Index.encode(index))
      configure(history_retention_days: 0)
      response = request(:get, "/retention/#{repo}", authorization: "Bearer #{@token}")
      assert response.status == 500
      assert JSON.decode!(response.resp_body)["error"] == "retention_configuration_invalid"
    end

    test "invalid settings and missing repositories have distinct statuses", %{repo: repo} do
      {:ok, _} = Code.WAL.create(repo)

      assert request(:put, "/retention/#{repo}", json: %{days: 0}, authorization: "Bearer #{@token}").status ==
               422

      assert request(:put, "/retention/#{repo}", json: %{}, authorization: "Bearer #{@token}").status == 422
      assert request(:get, "/retention/#{repo}/missing", authorization: "Bearer #{@token}").status == 404

      assert request(:put, "/retention/#{repo}/missing", json: %{days: 30}, authorization: "Bearer #{@token}").status ==
               404
    end
  end

  describe "authentication" do
    test "accepts the configured bearer token", %{account: account} do
      conn = request(:get, "/policy/#{account}", authorization: "Bearer #{@token}")
      assert conn.status == 200
    end

    test "rejects a request without a token", %{account: account} do
      conn = request(:get, "/policy/#{account}")
      assert conn.status == 401
    end

    test "rejects the wrong token", %{account: account} do
      conn = request(:get, "/policy/#{account}", authorization: "Bearer not-the-token")
      assert conn.status == 401
    end

    test "rejects blank and whitespace bearer tokens", %{account: account} do
      for header <- ["Bearer ", "Bearer    ", "Bearer  ", "Basic " <> Base.encode64(":")] do
        conn = request(:get, "/policy/#{account}", authorization: header)
        assert conn.status == 401, inspect(header)
      end
    end

    test "fails closed when no admin token is configured", %{account: account} do
      # The listener binds every interface by default. An unset token used to
      # mean an open admin API; it now means a closed one.
      configure(admin_token: nil)

      for header <- [nil, "Bearer ", "Bearer anything"] do
        conn = request(:get, "/policy/#{account}", authorization: header)
        assert conn.status == 401
        assert JSON.decode!(conn.resp_body)["error"] =~ "no admin token is configured"
      end
    end

    test "fails closed when the configured token is blank", %{account: account} do
      # `Bearer <U+2003>` trims to "", and "" == "" in constant time too.
      for blank <- ["", "   ", " "] do
        configure(admin_token: blank)

        for header <- ["Bearer ", "Bearer  ", "Bearer #{blank}"] do
          conn = request(:get, "/policy/#{account}", authorization: header)
          assert conn.status == 401, "token #{inspect(blank)}, header #{inspect(header)}"
        end
      end
    end

    test "health stays unauthenticated even without a token" do
      configure(admin_token: nil)
      conn = request(:get, "/health")
      assert conn.status == 200
    end
  end

  describe "policy routes" do
    test "a binding round-trips", %{account: account} do
      auth = "Bearer #{@token}"

      conn =
        request(:put, "/policy/#{account}",
          authorization: auth,
          json: %{"subject" => "alice", "repositories" => ["#{account}/**"], "permissions" => ["read"]}
        )

      assert conn.status == 200
      assert [%{"subject" => "alice"}] = JSON.decode!(conn.resp_body)["bindings"]

      conn = request(:delete, "/policy/#{account}?subject=alice", authorization: auth)
      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["bindings"] == []
    end

    test "an account that is not one valid segment is not found", %{account: account, store: store} do
      auth = "Bearer #{@token}"
      binding = %{"subject" => "mallory", "repositories" => ["**"], "permissions" => ["admin"]}

      for path <- ["/policy/#{account}/nested", "/policy/..", "/policy/.hidden", "/policy/-dash"] do
        assert request(:get, path, authorization: auth).status == 404, path
        assert request(:put, path, authorization: auth, json: binding).status == 404, path
        assert request(:delete, path <> "?subject=mallory", authorization: auth).status == 404, path
      end

      # Nothing reached the store under a derived key.
      refute File.exists?(Path.join(store, "accounts"))
    end

    test "a binding with malformed fields is refused", %{account: account} do
      auth = "Bearer #{@token}"

      for body <- [
            %{"subject" => "a", "repositories" => ["#{account}/**"], "permissions" => [1]},
            %{"subject" => "a", "repositories" => [%{}], "permissions" => ["read"]},
            %{"subject" => 1, "repositories" => ["#{account}/**"], "permissions" => ["read"]},
            %{
              "subject" => "a",
              "repositories" => ["#{account}/**"],
              "permissions" => ["read"],
              "expires_at_ms" => "tomorrow"
            }
          ] do
        conn = request(:put, "/policy/#{account}", authorization: auth, json: body)
        assert conn.status == 422, inspect(body)
      end
    end
  end
end
