defmodule Code.HTTP.AccountConfigurationAuthTest do
  @moduledoc """
  Account configuration (secret backends and inference profiles) needs an
  administrator grant spanning the whole account. An administrator of one
  repository in the account is refused on every surface, even though the
  request names that very repository.
  """

  use Code.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Code.Auth.Principal
  alias Code.Config
  alias Code.Control
  alias Code.HTTP.Router
  alias Code.MCP.Server

  setup %{repo: repo, namespace: namespace} do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(repo)

    Config.put_overrides(
      Map.put(
        Config.overrides(),
        :auth,
        {Code.Auth.Static,
         tokens: %{
           "repo-admin" => %{account: namespace, grants: [{repo, [:read, :write, :admin]}]},
           "account-admin" => %{account: namespace, scopes: [:admin]}
         }}
      )
    )

    :ok
  end

  test "HTTP refuses a repository-only administrator on every account endpoint", %{repo: repo} do
    requests = [
      {:get, "/api/secret-backends?repository=#{repo}", nil},
      {:get, "/api/secret-backends/production?repository=#{repo}", nil},
      {:put, "/api/secret-backends/production?repository=#{repo}",
       %{driver: "managed_infisical", project: "acme"}},
      {:get, "/api/inference-profiles?repository=#{repo}", nil},
      {:get, "/api/inference-profiles/coding?repository=#{repo}", nil},
      {:put, "/api/inference-profiles/coding?repository=#{repo}",
       %{endpoint: "https://x.example/v1", model: "m"}}
    ]

    for {method, path, payload} <- requests do
      response = request(method, path, payload, "repo-admin")
      assert response.status == 403, "#{method} #{path}: #{response.status}"

      assert %{"error" => "code: not permitted to administer account " <> _} =
               JSON.decode!(response.resp_body)
    end

    # The same request succeeds for an account-wide administrator, so the 403
    # above is about the grant's scope, not a broken route.
    assert request(:get, "/api/secret-backends?repository=#{repo}", nil, "account-admin").status == 200
  end

  test "MCP refuses a repository-only administrator on every account tool", %{
    repo: repo,
    namespace: namespace
  } do
    repository_admin = %Principal{
      subject: "repo-admin",
      account: namespace,
      grants: [Principal.grant(repo, [:read, :write, :admin])],
      source: :test
    }

    calls = [
      {"configure_secret_backend", %{"backend" => "production", "project" => "acme"}},
      {"list_secret_backends", %{}},
      {"get_secret_backend", %{"backend" => "production"}},
      {"configure_inference_profile",
       %{
         "profile" => "coding",
         "endpoint" => "https://x.example/v1",
         "model" => "m",
         "credential_binding" => %{}
       }},
      {"list_inference_profiles", %{}},
      {"get_inference_profile", %{"profile" => "coding"}}
    ]

    for {tool, args} <- calls do
      result = call_tool(tool, Map.put(args, "repository", repo), repository_admin)
      assert result.isError, tool
      assert hd(result.content).text == "not permitted to administer account #{namespace}", tool
    end
  end

  defp call_tool(name, args, principal) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }

    {:reply, %{result: result}} = Server.handle(message, principal: principal, public_url: "http://code.test")
    result
  end

  defp request(method, path, payload, token) do
    conn = conn(method, path, if(payload, do: JSON.encode!(payload), else: ""))
    conn = if payload, do: put_req_header(conn, "content-type", "application/json"), else: conn
    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    Router.call(conn, Router.init([]))
  end
end
