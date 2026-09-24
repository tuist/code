defmodule Code.HTTP.GitRouterTest do
  use Code.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Code.Config
  alias Code.Control
  alias Code.HTTP.Router

  setup %{repo: repo, namespace: namespace} do
    start_replica_runtime()
    assert {:ok, _} = Control.create_repository(repo)

    Config.put_overrides(
      Map.put(
        Config.overrides(),
        :auth,
        {Code.Auth.Static,
         tokens: %{
           "writer" => %{account: namespace, scopes: [:read, :write]}
         }}
      )
    )

    {:ok, token: "writer"}
  end

  test "rejects a Git service request with the wrong content type", %{repo: repo, token: token} do
    conn =
      conn(:post, "/#{repo}.git/git-receive-pack", "")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "text/plain")
      |> Router.call(Router.init([]))

    assert conn.status == 415

    assert conn.resp_body ==
             "code: expected application/x-git-receive-pack-request, got text/plain\n"
  end

  test "an invalid repository id is not found, before authentication or policy", %{namespace: namespace} do
    # Validated ahead of authorization, so a malformed id never reaches the
    # policy lookup (which derives an object key from its account) and is
    # never answered with a challenge that implies it might exist.
    for path <- [
          "/.hidden/app.git/info/refs?service=git-upload-pack",
          "/#{namespace}/-dash.git/info/refs?service=git-upload-pack",
          "/#{namespace}/a..b.git/info/refs?service=git-upload-pack"
        ] do
      conn = conn(:get, path) |> Router.call(Router.init([]))
      assert conn.status == 404, path
      assert conn.resp_body == "code: repository not found\n"
    end

    conn =
      conn(:post, "/.hidden/app.git/git-upload-pack", "")
      |> put_req_header("content-type", "application/x-git-upload-pack-request")
      |> Router.call(Router.init([]))

    assert conn.status == 404
  end
end
