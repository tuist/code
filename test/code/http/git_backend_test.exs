defmodule Code.HTTP.GitBackendTest do
  use Code.Case, async: true

  import Plug.Test

  alias Code.Git
  alias Code.HTTP.GitBackend

  test "the advertisement carries only protocol data, whatever git writes to stderr", %{root: root} do
    repository = Path.join(root, "advertised.git")
    :ok = Git.init_bare(repository)

    # GIT_TRACE makes git write to standard error on every run, standing in
    # for any warning it might print. Interleaved into the body, such a line
    # breaks the pkt-line framing a client parses.
    conn =
      conn(:get, "/info/refs?service=git-upload-pack")
      |> GitBackend.advertise(repository, "git-upload-pack", env: [{"GIT_TRACE", "1"}])

    assert conn.status == 200
    refute conn.resp_body =~ "trace"
    assert "001e# service=git-upload-pack\n0000" <> _ = conn.resp_body
  end
end
