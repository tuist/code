defmodule Code.GitTest do
  use Code.Case, async: true

  alias Code.Git

  test "records the Git subcommand rather than the repository path", %{root: root} do
    repository = Path.join(root, "observed.git")
    assert :ok = Git.init_bare(repository)

    handler = {__MODULE__, :git_command, self()}

    :ok =
      :telemetry.attach(
        handler,
        [:code, :git, :command],
        fn _event, _measurements, metadata, pid ->
          if self() == pid, do: send(pid, {:git_command, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _} = Git.run(repository, ["rev-parse", "--git-dir"])
    assert_receive {:git_command, %{subcommand: "rev-parse", status: 0}}
  end

  defp observe(event) do
    handler = {__MODULE__, event, make_ref()}
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _event, measurements, metadata, pid ->
          if self() == pid, do: send(pid, {:observed, event, measurements, metadata})
        end,
        test
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # A marker in the command line, so the OS process can be found without
  # confusing it with any other test's.
  defp marker, do: "code.test=#{:erlang.unique_integer([:positive])}"

  defp os_process?(marker) do
    {out, _} = System.cmd("ps", ["-eo", "args"])
    out |> String.split("\n") |> Enum.any?(&String.contains?(&1, marker))
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  describe "command lifetimes" do
    test "a command that outlives its timeout is stopped and reported" do
      marker = marker()

      # `cat-file --batch` waits on stdin forever, which nothing here closes.
      started = System.monotonic_time(:millisecond)
      assert {:error, {:git, :timeout, _}} = Git.run(nil, ["-c", marker, "cat-file", "--batch"], timeout: 200)
      assert System.monotonic_time(:millisecond) - started < 5_000

      assert eventually(fn -> not os_process?(marker) end), "the timed-out git process is still running"
    end

    test "a command dies with the process that asked for it" do
      marker = marker()
      test = self()

      caller =
        spawn(fn ->
          send(test, :started)
          Git.run(nil, ["-c", marker, "cat-file", "--batch"], timeout: :timer.minutes(5))
        end)

      assert_receive :started
      assert eventually(fn -> os_process?(marker) end)

      Process.exit(caller, :kill)

      assert eventually(fn -> not os_process?(marker) end), "git outlived the request that started it"
    end

    test "a failing supervised command is diagnosed from its first run, not re-run", %{root: root} do
      repository = Path.join(root, "supervised.git")
      assert :ok = Git.init_bare(repository)
      observe([:code, :git, :command])

      assert {:error, {:git, status, diagnostic}} =
               Git.run_supervised(repository, ["repack", "--no-such-option"])

      assert status != 0
      assert diagnostic =~ "no-such-option"

      assert_receive {:observed, _, _, %{subcommand: "repack"}}
      refute_receive {:observed, _, _, %{subcommand: "repack"}}, 200
    end
  end

  describe "standard error" do
    test "can be kept out of output that is protocol data", %{root: root} do
      repository = Path.join(root, "advertise.git")
      assert :ok = Git.init_bare(repository)

      # GIT_TRACE writes to standard error, as any warning would.
      args = ["upload-pack", "--stateless-rpc", "--advertise-refs", repository]
      env = [{"GIT_TRACE", "1"}]

      assert {:ok, merged} = Git.run(repository, args, env: env)
      assert merged =~ "trace"

      assert {:ok, separate} = Git.run(repository, args, env: env, stderr: :separate)
      refute separate =~ "trace"
      assert {:ok, _lines} = parse_pkt_lines(separate)
    end
  end

  defp parse_pkt_lines(""), do: {:ok, []}
  defp parse_pkt_lines("0000" <> rest), do: parse_pkt_lines(rest)

  defp parse_pkt_lines(<<length::binary-size(4), rest::binary>>) do
    case Integer.parse(length, 16) do
      {size, ""} when size >= 4 and byte_size(rest) >= size - 4 ->
        line = binary_part(rest, 0, size - 4)
        tail = binary_part(rest, size - 4, byte_size(rest) - size + 4)

        with {:ok, lines} <- parse_pkt_lines(tail), do: {:ok, [line | lines]}

      _ ->
        {:error, {:malformed, length}}
    end
  end

  defp parse_pkt_lines(other), do: {:error, {:malformed, other}}

  # Git writes packs and their indexes read-only.
  defp overwrite(path, bytes) do
    File.chmod!(path, 0o644)
    File.write!(path, bytes)
  end

  describe "installing a pack" do
    setup %{root: root} do
      source = fixture_repository()
      {_, 0} = git(["repack", "-a", "-d", "-q"], source)
      [pack] = Path.wildcard(Path.join(source, ".git/objects/pack/*.pack"))

      # A downloaded pack: the pack and its index side by side in a scratch
      # directory, the way `Code.WAL.get_pack/3` leaves them.
      download = Path.join(root, "download")
      File.mkdir_p!(download)
      File.cp!(pack, Path.join(download, Path.basename(pack)))

      File.cp!(
        Path.rootname(pack) <> ".idx",
        Path.join(download, Path.basename(Path.rootname(pack)) <> ".idx")
      )

      repository = Path.join(root, "install.git")
      :ok = Git.init_bare(repository)

      {:ok, pack: Path.join(download, Path.basename(pack)), repository: repository, commit: oid(source)}
    end

    test "reuses a downloaded index that matches its pack", %{
      pack: pack,
      repository: repository,
      commit: commit
    } do
      observe([:code, :git, :pack_index])
      observe([:code, :git, :command])

      assert {:ok, installed} = Git.install_pack(repository, pack)
      assert File.exists?(Path.rootname(installed) <> ".idx")
      assert Git.object?(repository, commit)

      assert_receive {:observed, [:code, :git, :pack_index], _, %{outcome: :reused}}
      refute_received {:observed, [:code, :git, :command], _, %{subcommand: "index-pack"}}
    end

    test "rebuilds an index that does not match its pack", %{
      pack: pack,
      repository: repository,
      commit: commit
    } do
      idx = Path.rootname(pack) <> ".idx"
      bytes = File.read!(idx)
      overwrite(idx, binary_part(bytes, 0, byte_size(bytes) - 1) <> <<0>>)
      observe([:code, :git, :pack_index])

      assert {:ok, _installed} = Git.install_pack(repository, pack)
      assert Git.object?(repository, commit)
      assert_receive {:observed, [:code, :git, :pack_index], _, %{outcome: :rebuilt_invalid}}
    end

    test "a pack that fails verification leaves nothing installed", %{pack: pack, repository: repository} do
      File.rm!(Path.rootname(pack) <> ".idx")
      overwrite(pack, binary_part(File.read!(pack), 0, 40))

      assert {:error, _} = Git.install_pack(repository, pack)
      assert Git.packs(repository) == []
      assert Path.wildcard(Path.join(repository, "objects/pack/*"), match_dot: true) == []
    end
  end
end
