defmodule Code.Replica.ScratchTest do
  use Code.Case, async: true

  test "startup sweep removes only reserved scratch directories in this node's data directory" do
    root = Code.Config.data_dir()
    File.mkdir_p!(root)

    leftovers =
      for {prefix, bytes} <- [{"code-packs-", 9}, {".code-init-", 12}] do
        suffix = :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
        path = Path.join(root, prefix <> suffix)
        File.mkdir_p!(path)
        File.write!(Path.join(path, "partial.pack"), "disposable")
        path
      end

    foreign = Path.join(root, "real-repository")
    File.mkdir_p!(foreign)
    File.write!(Path.join(foreign, "keep"), "repository")
    link = Path.join(root, "code-packs-zyxwvuts9876")
    File.ln_s!(foreign, link)
    ordinary = Path.join(root, "code-packs-unrelated-directory")
    File.mkdir_p!(ordinary)
    short_init = Path.join(root, ".code-init-AbCdEfGh1234")
    File.mkdir_p!(short_init)
    assert :ok = Code.Replica.Scratch.sweep()
    for path <- leftovers, do: refute(File.exists?(path))
    assert File.read!(Path.join(foreign, "keep")) == "repository"
    assert File.dir?(ordinary)
    assert File.dir?(short_init)
    assert {:ok, _} = File.read_link(link)
  end
end
