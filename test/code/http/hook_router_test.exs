defmodule Code.HTTP.HookRouterTest do
  use Code.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Code.Git.Hooks
  alias Code.HTTP.HookRouter
  alias Code.WAL
  alias Code.WAL.Entry

  setup %{repo: repo} do
    start_replica_runtime()
    assert {:ok, _} = WAL.create(repo)
    :ok
  end

  test "records the authenticated Git actor in the write-ahead log", %{repo: repo} do
    token = Code.Config.hook_token()
    zero = Entry.zero_oid()

    conn =
      conn(:post, "/pre-receive", "#{zero} #{zero} refs/heads/main\n")
      |> put_req_header("x-code-token", token)
      |> put_req_header("x-code-repository", repo)
      |> put_req_header("x-code-actor", "alice")

    response = HookRouter.call(conn, [])
    assert response.status == 200

    assert {:ok, index, _} = WAL.fetch(repo)
    [pointer] = index.entries
    assert {:ok, entry} = WAL.read_entry(repo, pointer)
    assert entry.actor.subject == "alice"
  end

  test "forwards the receive-pack actor to the hook callback", %{root: root, repo: repo} do
    repository = Path.join(root, "hook.git")
    assert :ok = Code.Git.init_bare(repository)

    assert :ok = Hooks.install(repository, repo)
    script = File.read!(Path.join(repository, "hooks/pre-receive"))

    assert script =~ ~s(X-Code-Actor: ${CODE_ACTOR:-})
  end
end
