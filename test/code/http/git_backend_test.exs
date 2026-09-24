defmodule Code.HTTP.GitBackendTest do
  @moduledoc """
  The request pump, driven with a real `git` process.

  The case that matters is a process that produces a lot of output *before*
  the request body has been fully sent. The pump caps what it buffers, starts
  the response once the cap is reached, and used to stop reading the body at
  that point: the rest of the request never reached `git`, which then waited
  for input forever while the client waited for a response that never ended.

  `git fast-import` makes this reproducible. `cat-blob` writes a blob to
  standard output as soon as the command is read, comment lines are consumed
  and ignored, and `done` makes it exit, so the process only finishes if the
  whole body, including its last line, is delivered.
  """

  use Code.Case, async: true

  import Plug.Test

  alias Code.HTTP.GitBackend

  # Comfortably past the 4 MiB output cap.
  @blob_bytes 8 * 1024 * 1024

  setup do
    path = fixture_repository("backend")
    blob_path = Path.join(path, "large.bin")
    File.write!(blob_path, :crypto.strong_rand_bytes(@blob_bytes))
    {oid, 0} = git(["hash-object", "-w", "large.bin"], path)

    {:ok, git_dir: Path.join(path, ".git"), oid: String.trim(oid)}
  end

  test "keeps feeding the request after early output reaches the buffer cap", %{git_dir: git_dir, oid: oid} do
    # The body outlives the cap by a wide margin: 32 MiB of comments after the
    # command that produces the output, and `done` at the very end.
    padding = String.duplicate("# " <> String.duplicate("x", 1_021) <> "\n", 32 * 1024)
    body = "cat-blob #{oid}\n" <> padding <> "done\n"

    task =
      Task.async(fn ->
        conn(:post, "/", body)
        |> GitBackend.run(git_dir, ["fast-import", "--quiet", "--done"],
          content_type: "application/octet-stream",
          service: "test",
          repo_id: "test/backend"
        )
      end)

    conn =
      case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, conn} -> conn
        nil -> flunk("the process never saw the end of the request body")
      end

    assert conn.status == 200
    # `cat-blob` answers `<oid> blob <size>\n<content>\n`.
    assert byte_size(conn.resp_body) > @blob_bytes
    assert String.starts_with?(conn.resp_body, "#{oid} blob #{@blob_bytes}\n")
  end

  test "a small request is answered after the body is consumed", %{git_dir: git_dir, oid: oid} do
    conn =
      conn(:post, "/", "cat-blob #{oid}\ndone\n")
      |> GitBackend.run(git_dir, ["fast-import", "--quiet", "--done"],
        content_type: "application/octet-stream"
      )

    assert conn.status == 200
    assert String.starts_with?(conn.resp_body, "#{oid} blob #{@blob_bytes}\n")
  end
end
