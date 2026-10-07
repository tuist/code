defmodule Code.GitTest do
  use Code.Case, async: true

  alias Code.Git
  alias Code.Native
  alias Code.WAL.Entry

  test "native private-stage copy cleans up after its actual BEAM owner dies", %{root: root} do
    source = Path.join(root, "sparse-copy-source")
    destination = Path.join(root, "private-copy-output")
    # Sparse input makes the copy long-lived without buffering or storing a
    # repository-sized fixture. We kill it as soon as its owned inode exists.
    size = 16 * 1024 * 1024 * 1024
    {:ok, file} = :file.open(source, [:raw, :binary, :write])
    assert {:ok, _} = :file.position(file, size - 1)
    assert :ok = :file.write(file, <<0>>)
    assert :ok = :file.close(file)
    %{major_device: device, inode: inode} = File.stat!(root)
    {pid, monitor} = spawn_monitor(fn -> Native.file_copy_regular(source, destination, device, inode) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert eventually(fn -> File.exists?(destination) end)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert eventually(fn -> not File.exists?(destination) end)
    assert File.stat!(source).size == size
  end

  test "native private-stage copy defers source symlinks without creating output", %{root: root} do
    source = Path.join(root, "plain-copy-source")
    link = Path.join(root, "copy-source-link")
    destination = Path.join(root, "private-copy-output")
    File.write!(source, "independent")
    File.ln_s!(source, link)
    %{major_device: device, inode: inode} = File.stat!(root)
    assert :fallback_git = Native.file_copy_regular(link, destination, device, inode)
    refute File.exists?(destination)
    assert :ok = File.cp(link, destination)
    File.write!(source, "changed")
    assert File.read!(destination) == "independent"
  end

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

  defp await_replay_gate(repository, attempts) do
    case Code.Native.replay_gate(repository, 10_000) do
      :busy when attempts > 0 -> Process.sleep(20) && await_replay_gate(repository, attempts - 1)
      result -> result
    end
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

  describe "initial branch replay" do
    test "branch and HEAD reflogs agree byte-for-byte with Git for explicit identities and offset dates", %{
      root: root
    } do
      {source, tip} = refs_repository(root)

      for {index, name, email, zone} <- [
            {1, "First Writer", "first@example.com", "+0530"},
            {2, "Second Writer", "second@example.com", "-0700"}
          ] do
        native = Path.join(root, "native-#{index}.git")
        reference = Path.join(root, "reference-#{index}.git")

        for repository <- [native, reference] do
          assert :ok = Git.init_bare(repository)
          for pack <- Git.packs(source), do: assert({:ok, _} = Git.install_pack(repository, pack))
        end

        assert {:ok, gate} = Code.Native.replay_gate(native, 10_000)

        try do
          assert :ok =
                   Code.Native.replay_branch(
                     gate,
                     [{"refs/heads/main", Entry.zero_oid(), tip}],
                     name,
                     email,
                     946_684_800,
                     zone,
                     ".code-reflog-holdout",
                     10_000
                   )
        after
          Code.Native.replay_release(gate)
        end

        assert {:ok, _} =
                 Git.run(reference, ["update-ref", "--stdin"],
                   stdin: "update refs/heads/main #{tip}\n",
                   env: [
                     {"GIT_COMMITTER_NAME", name},
                     {"GIT_COMMITTER_EMAIL", email},
                     {"GIT_COMMITTER_DATE", "@946684800 #{zone}"}
                   ]
                 )

        for path <- ["logs/refs/heads/main", "logs/HEAD"] do
          assert File.read!(Path.join(native, path)) == File.read!(Path.join(reference, path))
        end

        assert {:ok, %{"refs/heads/main" => ^tip}} = Git.refs(native)
        assert Path.wildcard(Path.join(native, ".code-reflog-*")) == []
        assert Path.wildcard(Path.join(native, "*.lock")) == []
      end
    end

    test "service committer configuration is process-local; initial replay avoids Git and existing logs retain it",
         %{root: root} do
      {repository, tip} = refs_repository(root)

      Code.Config.put_overrides(
        Map.merge(Code.Config.overrides(), %{
          git_committer_name: "Cache Writer",
          git_committer_email: "cache@example.com"
        })
      )

      observe([:code, :git, :replay_refs])
      observe([:code, :git, :command])
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip}, native_replay: true)
      assert_receive {:observed, [:code, :git, :replay_refs], _, %{source: :native, outcome: :ok}}
      refute_received {:observed, [:code, :git, :command], _, %{subcommand: "update-ref"}}
      assert File.read!(Path.join(repository, "logs/HEAD")) =~ "Cache Writer <cache@example.com>"
      assert {:ok, identity} = Git.run(repository, ["var", "GIT_COMMITTER_IDENT"])
      assert identity =~ "Cache Writer <cache@example.com>"
      assert :ok = Git.reset_refs(repository, %{})
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip}, native_replay: true)
      assert_receive {:observed, [:code, :git, :replay_refs], _, %{source: :git, outcome: :ok}}
      assert_receive {:observed, [:code, :git, :command], _, %{subcommand: "update-ref"}}
    end
  end

  test "a gate for a replaced root fails closed before eligibility can trigger a Git fallback", %{root: root} do
    {repository, tip} = refs_repository(root)
    assert {:ok, gate} = Code.Native.replay_gate(repository, 10_000)

    try do
      assert :ok = File.rename(repository, repository <> ".old")
      assert :ok = Git.init_bare(repository)
      assert :error = Code.Native.replay_tags(gate, [{"refs/tags/release", Entry.zero_oid(), tip}], 10_000)

      assert :error =
               Code.Native.replay_branch(
                 gate,
                 [{"refs/heads/main", Entry.zero_oid(), tip}],
                 "Code",
                 "code@localhost",
                 946_684_800,
                 "+0000",
                 ".code-reflog-replaced",
                 10_000
               )

      assert {:ok, %{}} = Git.refs(repository)
      refute File.exists?(Path.join(repository, "logs"))
    after
      Code.Native.replay_release(gate)
    end
  end

  describe "gated tag replay" do
    test "replica replay creates and replaces flat tags without Git, while direct updates stay Git", %{
      root: root
    } do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})
      observe([:code, :git, :command])
      observe([:code, :git, :replay_refs])

      for tag <- ["first", "second", "third"] do
        refs = %{"refs/heads/main" => tip, "refs/tags/#{tag}" => tip}
        assert :ok = Git.reset_refs(repository, refs, native_replay: true)
        assert_receive {:observed, [:code, :git, :replay_refs], _, %{source: :native, outcome: :ok}}
        assert {:ok, ^refs} = Git.refs(repository)
        refute_received {:observed, [:code, :git, :command], _, %{subcommand: "update-ref"}}
        assert Path.wildcard(Path.join(repository, "refs/tags/*.lock")) == []
        refute File.exists?(Path.join(repository, "logs/refs/tags/#{tag}"))
      end

      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})
      assert_receive {:observed, [:code, :git, :command], _, %{subcommand: "update-ref", status: 0}}
    end

    test "a callback lease fences successor convergence after the owner dies", %{root: root} do
      {repository, _tip} = refs_repository(root)
      parent = self()

      owner =
        spawn(fn ->
          {:ok, gate} = Code.Native.replay_gate(repository, 10_000)
          {:ok, lease} = Code.Native.replay_lease(gate)
          send(parent, {:lease, lease})

          receive do
            :finish -> Code.Native.replay_release(gate)
          end
        end)

      assert_receive {:lease, lease}
      monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
      assert :busy = Code.Native.replay_gate(repository, 10_000)
      assert :ok = Code.Native.replay_lease_release(lease)
      # The dead owner's gate is released when the VM frees its heap, which
      # can trail the :DOWN message, so the successor may briefly see :busy.
      assert {:ok, successor} = await_replay_gate(repository, 100)
      assert :ok = Code.Native.replay_release(successor)
    end

    test "release cannot unlock a gate until outstanding work finishes; inode aliases share it", %{root: root} do
      {repository, _tip} = refs_repository(root)
      alias_path = Path.join(root, "alias.git")
      File.ln_s!(repository, alias_path)
      assert {:ok, gate} = Code.Native.replay_gate(repository, 10_000)
      assert {:ok, lease} = Code.Native.replay_lease(gate)
      assert :ok = Code.Native.replay_release(gate)
      assert :busy = Code.Native.replay_gate(alias_path, 10_000)
      assert :ok = Code.Native.replay_lease_release(lease)
      assert {:ok, successor} = Code.Native.replay_gate(alias_path, 10_000)
      assert :ok = Code.Native.replay_release(successor)
    end

    test "tag reflogs and reference-transaction hooks retain Git", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})
      hooks = Path.join(repository, "hooks")
      File.mkdir!(hooks)
      marker = Path.join(root, "hook-calls")
      hook = Path.join(hooks, "reference-transaction")
      File.write!(hook, "#!/bin/sh\necho \"$1\" >> '#{marker}'\ncat >/dev/null\n")
      File.chmod!(hook, 0o755)
      observe([:code, :git, :replay_refs])

      assert :ok =
               Git.reset_refs(repository, %{"refs/heads/main" => tip, "refs/tags/hooked" => tip},
                 native_replay: true
               )

      assert_receive {:observed, [:code, :git, :replay_refs], _, %{source: :git, outcome: :ok}}
      assert File.read!(marker) =~ "prepared"
      assert File.read!(marker) =~ "committed"
      File.rm!(hook)
      assert {:ok, _} = Git.run(repository, ["update-ref", "--create-reflog", "refs/tags/logged", tip])
      assert File.exists?(Path.join(repository, "logs/refs/tags/logged"))
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip}, native_replay: true)
      assert_receive {:observed, [:code, :git, :replay_refs], _, %{source: :git, outcome: :ok}}
      refute File.exists?(Path.join(repository, "logs/refs/tags/logged"))
    end
  end

  describe "bounded native tree search" do
    test "plain fixed searches agree with Git including global limits and unterminated lines", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert {:ok, blob} = Git.write_blob(repository, "match one\r\nno\nmatch two\nmatch end")

      assert {:ok, tree} =
               Git.write_tree(repository, tip, [%{path: "a.txt", oid: blob}, %{path: "z.txt", oid: blob}])

      assert {:ok, commit} =
               Git.commit_tree(repository, tree, [tip], "grep holdout", %{
                 name: "Test",
                 email: "test@example.com"
               })

      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => commit})
      observe([:code, :git, :grep])

      for limit <- [1, 2, 10] do
        assert {:ok, matches} = Git.grep(repository, "HEAD", "match", limit: limit)

        assert_receive {:observed, [:code, :git, :grep], _,
                        %{source: :native, outcome: :ok, hash_backend: :sha1dc}}

        assert {:ok, output} =
                 Git.run(repository, [
                   "grep",
                   "--line-number",
                   "--no-color",
                   "-I",
                   "--max-count=#{limit}",
                   "--fixed-strings",
                   "-e",
                   "match",
                   "HEAD"
                 ])

        expected =
          output
          |> String.split("\n", trim: true)
          |> Enum.take(limit)
          |> Enum.map(fn line ->
            [_, path, number, text] = String.split(line, ":", parts: 4)
            %{path: path, line: String.to_integer(number), text: text}
          end)

        assert matches == expected
      end

      assert {:ok, []} = Git.grep(repository, "HEAD", "absent")
      assert {:ok, _} = Git.grep(repository, "HEAD", "MATCH", ignore_case: true)
      assert_receive {:observed, [:code, :git, :grep], _, %{source: :git, outcome: :ok, hash_backend: :git}}
      File.mkdir_p!(Path.join(repository, "info"))
      File.write!(Path.join(repository, "info/attributes"), "a.txt -diff\n")
      assert {:ok, matches} = Git.grep(repository, "HEAD", "match")
      assert Enum.all?(matches, &(&1.path == "z.txt"))
      assert_receive {:observed, [:code, :git, :grep], _, %{source: :git, outcome: :ok, hash_backend: :git}}
    end

    test "large binary blobs are streamed and verified even though their prefix suppresses matches", %{
      root: root
    } do
      {repository, tip} = refs_repository(root)
      content = <<0>> <> "match" <> String.duplicate("x", 2 * 1024 * 1024)
      assert {:ok, blob} = Git.write_blob(repository, content)
      assert {:ok, tree} = Git.write_tree(repository, nil, [%{path: "asset.bin", oid: blob}])

      assert {:ok, commit} =
               Git.commit_tree(repository, tree, [tip], "binary holdout", %{
                 name: "Test",
                 email: "test@example.com"
               })

      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => commit})
      observe([:code, :git, :grep])
      assert {:ok, []} = Git.grep(repository, "HEAD", "match")

      assert_receive {:observed, [:code, :git, :grep], _,
                      %{source: :native, outcome: :ok, hash_backend: :sha1dc}}

      corrupted = binary_part(content, 0, byte_size(content) - 1) <> "y"
      path = Path.join([repository, "objects", String.slice(blob, 0, 2), String.slice(blob, 2, 38)])
      overwrite(path, :zlib.compress("blob #{byte_size(corrupted)}\0" <> corrupted))

      assert :fallback_git =
               Code.Native.fixed_grep(
                 repository,
                 "HEAD",
                 "match",
                 10,
                 Code.Git.AttributePaths.cached(),
                 10_000
               )

      assert :timeout = Code.Native.fixed_grep(repository, "HEAD", "match", 10, [], 0)
    end
  end

  describe "bare configuration" do
    test "fresh initialization imports all settings and branch target without Git commands", %{root: root} do
      repository = Path.join(root, "templated.git")
      observe([:code, :git, :command])
      assert :ok = Git.init_bare(repository, head: "refs/heads/develop")

      refute_received {:observed, [:code, :git, :command], _, _}

      assert {:ok, "refs/heads/develop"} = Git.head(repository)
      assert {:ok, "true\n"} = Git.run(repository, ["config", "core.bare"])
      assert {:ok, "1\n"} = Git.run(repository, ["config", "receive.unpackLimit"])
      assert {:ok, "refs/code\n"} = Git.run(repository, ["config", "transfer.hideRefs"])
    end

    test "existing directories keep Git initialization and unrelated contents", %{root: root} do
      repository = Path.join(root, "existing-empty.git")
      File.mkdir!(repository)
      File.write!(Path.join(repository, "sentinel"), "preserved")
      observe([:code, :git, :command])
      observe([:code, :git, :init_bare])
      assert :ok = Git.init_bare(repository)
      assert_receive {:observed, [:code, :git, :init_bare], _, %{source: :git, outcome: :ok}}
      assert_receive {:observed, [:code, :git, :command], _, %{subcommand: "init", status: 0}}
      assert File.read!(Path.join(repository, "sentinel")) == "preserved"
      # Git still performs its own filesystem probe in the fallback path.
      plain = Path.join(root, "plain-probe.git")
      assert {:ok, _} = Git.run(root, ["init", "--bare", "--quiet", plain])

      for setting <- ["core.ignorecase", "core.precomposeunicode", "core.filemode"] do
        assert Git.run(repository, ["config", "--bool", setting]) ==
                 Git.run(plain, ["config", "--bool", setting])
      end

      assert Path.wildcard(Path.join(root, ".code-init-*")) == []
    end

    test "invalid branch and non-branch targets still use Git's validating HEAD write", %{root: root} do
      repository = Path.join(root, "invalid-initial-head.git")
      observe([:code, :git, :command])
      assert {:error, _} = Git.init_bare(repository, head: "refs/heads/bad..name")
      assert_receive {:observed, _, _, %{subcommand: "symbolic-ref", status: status}}
      assert status != 0

      repository = Path.join(root, "non-branch-head.git")
      assert :ok = Git.init_bare(repository, head: "refs/tags/target")
      assert_receive {:observed, _, _, %{subcommand: "symbolic-ref", status: 0}}
      assert {:ok, "refs/tags/target"} = Git.head(repository)
    end

    test "reinitialization repairs settings and preserves unrelated config", %{root: root} do
      repository = Path.join(root, "reinit.git")
      assert :ok = Git.init_bare(repository)
      assert :ok = Git.config(repository, "receive.unpackLimit", "100")
      assert :ok = Git.config(repository, "custom.value", "preserved")

      assert :ok = Git.init_bare(repository, head: "refs/heads/next")
      assert {:ok, "refs/heads/next"} = Git.head(repository)
      assert {:ok, "1\n"} = Git.run(repository, ["config", "receive.unpackLimit"])
      assert {:ok, "preserved\n"} = Git.run(repository, ["config", "custom.value"])
    end

    test "an already configured plain cache needs no Git process", %{root: root} do
      repository = Path.join(root, "configured.git")
      assert :ok = Git.init_bare(repository)
      observe([:code, :git, :command])
      observe([:code, :git, :configuration])

      assert :ok = Git.configure_bare(repository)

      assert_receive {:observed, [:code, :git, :configuration], %{duration_us: duration},
                      %{source: :native, outcome: :ok}}

      assert duration >= 0
      refute_received {:observed, [:code, :git, :command], _, _}
    end

    test "changed settings are repaired without rewriting unrelated configuration", %{root: root} do
      repository = Path.join(root, "repair.git")
      assert :ok = Git.init_bare(repository)
      assert :ok = Git.config(repository, "receive.unpackLimit", "100")
      assert :ok = Git.config(repository, "uploadpack.allowAnySHA1InWant", "true")
      assert :ok = Git.config(repository, "custom.setting", "keep me")

      assert :ok = Git.configure_bare(repository)
      assert {:ok, "1\n"} = Git.run(repository, ["config", "receive.unpackLimit"])
      assert {:ok, "false\n"} = Git.run(repository, ["config", "uploadpack.allowAnySHA1InWant"])
      assert {:ok, "keep me\n"} = Git.run(repository, ["config", "custom.setting"])
    end

    test "includes always use Git's effective configuration and cannot unhide private refs", %{root: root} do
      {physical_root, 0} = System.cmd("pwd", ["-P"], cd: root)

      for section <- ["include", ~s(includeIf "gitdir:#{String.trim(physical_root)}/")] do
        repository = Path.join(root, "included-#{System.unique_integer([:positive])}.git")
        included = Path.join(root, "extra-#{System.unique_integer([:positive])}.config")
        assert :ok = Git.init_bare(repository)
        File.write!(included, "[transfer]\n hideRefs = !refs/code\n")
        File.write!(Path.join(repository, "config"), "\n[#{section}]\n path = #{included}\n", [:append])
        observe([:code, :git, :configuration])
        assert {:ok, effective} = Git.run(repository, ["config", "--null", "--list"])
        assert effective =~ "transfer.hiderefs\n!refs/code"
        assert {:error, :unsafe_git_configuration} = Git.configure_bare(repository)
        assert_receive {:observed, [:code, :git, :configuration], _, %{source: :git, outcome: :error}}
      end
    end

    test "benign includes preserve unrelated configuration and use the Git path", %{root: root} do
      repository = Path.join(root, "benign-include.git")
      included = Path.join(root, "benign.config")
      assert :ok = Git.init_bare(repository)
      File.write!(included, "[custom]\n value = retained\n")
      assert :ok = Git.config(repository, "include.path", included)
      observe([:code, :git, :configuration])
      assert :ok = Git.configure_bare(repository)
      assert_receive {:observed, [:code, :git, :configuration], _, %{source: :git, outcome: :ok}}
      assert {:ok, "retained\n"} = Git.run(repository, ["config", "custom.value"])
    end

    test "oversized configurations take the ordinary Git path", %{root: root} do
      repository = Path.join(root, "large-config.git")
      assert :ok = Git.init_bare(repository)
      File.write!(Path.join(repository, "config"), "\n#" <> String.duplicate("x", 65_536) <> "\n", [:append])
      observe([:code, :git, :configuration])
      assert :ok = Git.configure_bare(repository)
      assert_receive {:observed, [:code, :git, :configuration], _, %{source: :git, outcome: :ok}}
    end

    test "native matches imply the real Git parser accepts the file and exact values", %{root: root} do
      repository = Path.join(root, "parser-holdout.git")
      assert :ok = Git.init_bare(repository)
      config = Path.join(repository, "config")
      base = File.read!(config)
      expected = [{"transfer.hiderefs", "refs/code"}, {"uploadpack.allowanysha1inwant", "false"}]

      for extra <- [
            "# comment\n",
            "[custom]\n value = \"literal # text\"\n",
            "[custom]\n implicit\n",
            "[custom]\r\n value = fine\r\n",
            "[custom]\n value = \\r\n",
            "[broken",
            <<0>>
          ] do
        File.write!(config, base <> "\n" <> extra)

        if Code.Native.file_config_matches(config, expected) do
          assert {:ok, out} = Git.run(repository, ["config", "--null", "--list"])
          values = out |> String.split(<<0>>, trim: true) |> Enum.map(&String.split(&1, "\n", parts: 2))

          for {key, value} <- expected do
            assert Enum.filter(values, &(hd(&1) == key)) == [[key, value]]
          end
        end
      end
    end

    test "duplicate hideRefs values are not mistaken for a secure configuration", %{root: root} do
      repository = Path.join(root, "duplicates.git")
      assert :ok = Git.init_bare(repository)
      assert {:ok, _} = Git.run(repository, ["config", "--add", "transfer.hideRefs", "!refs/code"])
      assert {:ok, _} = Git.run(repository, ["config", "--add", "transfer.hideRefs", "refs/code"])

      # Like the original configurator, refuse an ambiguous multi-valued
      # setting rather than silently accepting only the final value.
      assert {:error, _} = Git.configure_bare(repository)
    end
  end

  defp reference_refs(repository) do
    with {:ok, out} <- Git.run(repository, ["for-each-ref", "--format=%(refname) %(objectname)"]) do
      {:ok,
       Map.new(String.split(out, "\n", trim: true), fn line ->
         [ref, oid] = String.split(line, " ", parts: 2)
         {ref, oid}
       end)}
    end
  end

  defp real_log_tuples(repository, revision, limit) do
    format = Enum.join(["%H", "%an", "%ae", "%aI", "%cI", "%s", "%b"], <<31>>) <> <<30>>

    assert {:ok, output} =
             Git.run(repository, ["log", "--max-count=#{limit}", "--format=#{format}", revision])

    output
    |> String.split(<<30>>, trim: true)
    |> Enum.flat_map(fn chunk ->
      case String.split(String.trim_leading(chunk, "\n"), <<31>>, parts: 7) do
        [oid, name, email, authored, committed, subject, body] ->
          [{oid, name, email, canonical_log_date(authored), canonical_log_date(committed), subject, body}]

        _ ->
          []
      end
    end)
  end

  # Git 2.55 renders strict ISO 8601 UTC as Z; older Git and the native
  # formatter use +00:00. Normalize only this equivalent UTC spelling so
  # the oracle still compares every date component and nonzero offset exactly.
  defp canonical_log_date(date), do: String.replace_suffix(date, "Z", "+00:00")

  defp refs_repository(root) do
    source = fixture_repository()
    {_, 0} = git(["repack", "-a", "-d", "-q"], source)
    [pack] = Path.wildcard(Path.join(source, ".git/objects/pack/*.pack"))
    repository = Path.join(root, "refs.git")
    assert :ok = Git.init_bare(repository)
    assert {:ok, _} = Git.install_pack(repository, pack)
    {repository, oid(source)}
  end

  describe "bounded native ref listings" do
    test "plain loose listings match Git, include private refs and launch no command", %{root: root} do
      {repository, tip} = refs_repository(root)

      expected =
        Map.new(
          ["refs/heads/main", "refs/heads/feature/deep", "refs/tags/release", "refs/code/state"],
          &{&1, tip}
        )

      commands = Enum.map(expected, fn {ref, oid} -> Entry.command(ref, Entry.zero_oid(), oid) end)
      assert :ok = Git.update_refs(repository, commands)
      assert {:ok, ^expected} = reference_refs(repository)
      observe([:code, :git, :command])
      observe([:code, :git, :refs])
      assert {:ok, ^expected} = Git.refs(repository)
      assert_receive {:observed, [:code, :git, :refs], %{refs: 4}, %{source: :native, outcome: :ok}}
      refute_received {:observed, [:code, :git, :command], _, _}
    end

    test "missing objects and lock files match the real Git metadata-only format", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.update_refs(repository, [Entry.command("refs/heads/main", Entry.zero_oid(), tip)])
      File.write!(Path.join(repository, "refs/heads/missing-object"), String.duplicate("1", 40) <> "\n")
      File.write!(Path.join(repository, "refs/heads/ignored.lock"), "not a ref")
      assert Git.refs(repository) == reference_refs(repository)
    end

    test "symbolic, non-ASCII and packed refs fall back without losing any refs", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.update_refs(repository, [Entry.command("refs/heads/main", Entry.zero_oid(), tip)])
      assert {:ok, _} = Git.run(repository, ["symbolic-ref", "refs/heads/alias", "refs/heads/main"])
      assert :fallback_git = Code.Native.loose_refs(repository)
      assert Git.refs(repository) == reference_refs(repository)
      File.rm!(Path.join(repository, "refs/heads/alias"))
      assert :ok = Git.update_refs(repository, [Entry.command("refs/heads/café", Entry.zero_oid(), tip)])
      assert :fallback_git = Code.Native.loose_refs(repository)
      assert Git.refs(repository) == reference_refs(repository)
      assert :ok = Git.update_refs(repository, [Entry.command("refs/heads/café", tip, Entry.zero_oid())])
      assert {:ok, _} = Git.run(repository, ["pack-refs", "--all"])
      assert :fallback_git = Code.Native.loose_refs(repository)
      assert Git.refs(repository) == reference_refs(repository)
    end

    test "oversized and symlinked leaves are never buffered by the native path", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.update_refs(repository, [Entry.command("refs/heads/main", Entry.zero_oid(), tip)])
      leaf = Path.join(repository, "refs/heads/unsupported")
      File.write!(leaf, String.duplicate("1", 4096))
      assert :fallback_git = Code.Native.loose_refs(repository)
      File.rm!(leaf)
      File.ln_s!(Path.join(repository, "config"), leaf)
      assert :fallback_git = Code.Native.loose_refs(repository)
    end

    test "SHA256 and malformed configurations preserve the Git path", %{root: root} do
      repository = Path.join(root, "sha256.git")
      assert {:ok, _} = Git.run(nil, ["init", "--bare", "--object-format=sha256", repository])
      assert :fallback_git = Code.Native.loose_refs(repository)
      assert Git.refs(repository) == reference_refs(repository)
      File.write!(Path.join(repository, "config"), "[broken")
      assert :fallback_git = Code.Native.loose_refs(repository)
      assert {:error, _} = Git.refs(repository)
    end
  end

  describe "bounded linear history" do
    test "the log oracle normalizes only the equivalent UTC spelling" do
      assert canonical_log_date("2000-01-01T00:00:00Z") == "2000-01-01T00:00:00+00:00"
      assert canonical_log_date("2000-01-01T00:00:00+00:00") == "2000-01-01T00:00:00+00:00"
      assert canonical_log_date("2000-01-01T05:30:00+05:30") == "2000-01-01T05:30:00+05:30"
      assert canonical_log_date("1999-12-31T19:00:00-05:00") == "1999-12-31T19:00:00-05:00"
    end

    test "canonical fields and count limits match real Git", %{root: root} do
      source = fixture_repository()

      for message <- ["subject one\n\nbody one\n", "subject two"] do
        {_, 0} = git(["commit", "--allow-empty", "-qm", message], source)
      end

      {_, 0} = git(["repack", "-a", "-d", "-q"], source)
      [pack] = Path.wildcard(Path.join(source, ".git/objects/pack/*.pack"))
      repository = Path.join(root, "history.git")
      assert :ok = Git.init_bare(repository)
      assert {:ok, _} = Git.install_pack(repository, pack)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => oid(source)})

      for limit <- [0, 1, 2, 50] do
        assert {:ok, native} = Code.Native.linear_log(repository, "HEAD", limit, 10_000)
        assert native == real_log_tuples(repository, "HEAD", limit)
      end

      observe([:code, :git, :command])
      observe([:code, :git, :log])
      assert {:ok, [_, _, _]} = Git.log(repository, "HEAD")
      assert_receive {:observed, [:code, :git, :log], _, %{source: :native, outcome: :ok}}
      refute_received {:observed, [:code, :git, :command], _, _}
      assert :timeout = Code.Native.linear_log(repository, "HEAD", 50, 0)
      assert :fallback_git = Code.Native.linear_log(repository, "HEAD", 257, 10_000)
      File.write!(Path.join(repository, "shallow"), oid(source) <> "\n")
      assert :fallback_git = Code.Native.linear_log(repository, "HEAD", 50, 10_000)
    end

    test "offset dates agree with Git; merges and missing parents fall back completely", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})
      assert {:ok, tree} = Git.run(repository, ["rev-parse", "HEAD^{tree}"])
      tree = String.trim(tree)

      make = fn parents, message ->
        args =
          [
            "-c",
            "user.name=Offset Name",
            "-c",
            "user.email=offset@example.com",
            "commit-tree",
            tree,
            "-m",
            message
          ] ++ Enum.flat_map(parents, &["-p", &1])

        assert {:ok, commit} =
                 Git.run(repository, args,
                   env: [{"GIT_AUTHOR_DATE", "946684800 +0530"}, {"GIT_COMMITTER_DATE", "946684801 -0500"}]
                 )

        String.trim(commit)
      end

      first = make.([tip], "offset dates")
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => first})
      assert {:ok, native} = Code.Native.linear_log(repository, "HEAD", 50, 10_000)
      assert native == real_log_tuples(repository, "HEAD", 50)
      merge = make.([first, tip], "merge")
      assert :fallback_git = Code.Native.linear_log(repository, merge, 50, 10_000)
      multiline = make.([first], "multi-line\nsubject\n\nbody")
      assert :fallback_git = Code.Native.linear_log(repository, multiline, 50, 10_000)

      raw =
        "tree #{tree}\nparent #{String.duplicate("1", 40)}\nauthor Test <test@example.com> 946684800 +0000\ncommitter Test <test@example.com> 946684800 +0000\n\nmissing parent\n"

      assert {:ok, missing} =
               Git.run(repository, ["hash-object", "-t", "commit", "-w", "--stdin"], stdin: raw)

      assert :fallback_git = Code.Native.linear_log(repository, String.trim(missing), 1, 10_000)
    end

    test "path filtering and encoding configuration retain Git", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})
      observe([:code, :git, :log])
      assert {:ok, [_]} = Git.log(repository, "HEAD", path: "README.md")
      assert_receive {:observed, [:code, :git, :log], _, %{source: :git, outcome: :ok}}
      assert {:ok, _} = Git.run(repository, ["config", "i18n.logOutputEncoding", "UTF-16"])
      assert :fallback_git = Code.Native.linear_log(repository, "HEAD", 50, 10_000)
    end
  end

  describe "bounded native blob reads" do
    test "small packed blobs match Git and omit cat-file subprocess", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})
      assert {:ok, expected} = Git.run(repository, ["cat-file", "blob", "HEAD:README.md"])
      assert {:ok, ^expected} = Code.Native.read_blob(repository, "HEAD", "README.md", 10_000)
      observe([:code, :git, :command])
      observe([:code, :git, :read_file])
      assert {:ok, ^expected} = Git.read_file(repository, "HEAD", "README.md")
      assert_receive {:observed, [:code, :git, :read_file], _, %{source: :native, outcome: :ok}}
      refute_received {:observed, [:code, :git, :command], _, _}
      assert :timeout = Code.Native.read_blob(repository, "HEAD", "README.md", 0)

      for path <- ["../README.md", "./README.md", "/README.md", "missing", ""] do
        assert :fallback_git = Code.Native.read_blob(repository, "HEAD", path, 10_000)
      end
    end

    test "real Git packed deltas match blob reads without loading large bases", %{root: root} do
      source = fixture_repository()

      for n <- 1..12 do
        File.write!(
          Path.join(source, "README.md"),
          String.duplicate("common source line\n", 5000) <> "revision #{n}\n"
        )

        {_, 0} = git(["add", "."], source)
        {_, 0} = git(["commit", "-qm", "change #{n}"], source)
      end

      {_, 0} = git(["repack", "-a", "-d", "-q"], source)
      [pack] = Path.wildcard(Path.join(source, ".git/objects/pack/*.pack"))
      {report, 0} = git(["verify-pack", "-v", Path.rootname(pack) <> ".idx"], source)

      delta =
        report
        |> String.split("\n")
        |> Enum.find_value(fn row ->
          case String.split(row) do
            [oid, "blob", _size, _compressed, _offset, _depth, _base] -> oid
            _ -> nil
          end
        end)

      assert is_binary(delta)
      {expected, 0} = git(["cat-file", "blob", delta], source)
      repository = Path.join(root, "delta.git")
      assert :ok = Git.init_bare(repository)
      assert {:ok, _} = Git.install_pack(repository, pack)
      assert {:ok, tree} = Git.run(repository, ["mktree"], stdin: "100644 blob #{delta}\tdelta.txt\n")
      {commit, 0} = git(["commit-tree", String.trim(tree), "-m", "delta reader holdout"], repository)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => String.trim(commit)})
      assert {:ok, ^expected} = Code.Native.read_blob(repository, "HEAD", "delta.txt", 10_000)

      assert {:ok, [{"100644", "blob", ^delta, size, "delta.txt"}]} =
               Code.Native.root_tree(repository, "HEAD", true, 10_000)

      assert size == byte_size(expected)
    end

    test "nested trees preserve executable symlink and gitlink modes", %{root: root} do
      source = fixture_repository()
      File.mkdir_p!(Path.join(source, "nested"))
      File.write!(Path.join(source, "nested/data.bin"), <<0, 255, 1, 128>>)
      File.write!(Path.join(source, "run.sh"), "#!/bin/sh\n")
      File.chmod!(Path.join(source, "run.sh"), 0o755)
      File.ln_s!("README.md", Path.join(source, "link"))
      {_, 0} = git(["add", "."], source)
      {_, 0} = git(["update-index", "--add", "--cacheinfo", "160000,#{oid(source)},submodule"], source)
      {_, 0} = git(["commit", "-qm", "nested modes"], source)
      {_, 0} = git(["repack", "-a", "-d", "-q"], source)
      [pack] = Path.wildcard(Path.join(source, ".git/objects/pack/*.pack"))
      repository = Path.join(root, "nested.git")
      assert :ok = Git.init_bare(repository)
      assert {:ok, _} = Git.install_pack(repository, pack)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => oid(source)})
      assert {:ok, entries} = Code.Native.root_tree(repository, "HEAD", true, 10_000)
      assert Enum.any?(entries, &match?({"100755", "blob", _, _, "run.sh"}, &1))
      assert Enum.any?(entries, &match?({"120000", "blob", _, 9, "link"}, &1))
      assert Enum.any?(entries, &match?({"160000", "commit", _, nil, "submodule"}, &1))

      for path <- ["nested/data.bin", "run.sh", "link"] do
        assert {:ok, expected} = Git.run(repository, ["cat-file", "blob", "HEAD:#{path}"])
        assert {:ok, ^expected} = Code.Native.read_blob(repository, "HEAD", path, 10_000)
      end

      assert :fallback_git = Code.Native.read_blob(repository, "HEAD", "submodule", 10_000)
      walk = Path.join(root, "nested-walk")
      assert {:ok, _} = Code.Native.plain_walk(repository, [oid(source)], walk, 10_000)
      assert {:ok, expected} = Git.run(repository, ["rev-list", "--objects", "--no-object-names", "HEAD"])

      assert MapSet.new(String.split(File.read!(walk), "\n", trim: true)) ==
               MapSet.new(String.split(expected, "\n", trim: true))
    end
  end

  describe "bounded root tree listings" do
    test "recursive and shallow listing match real Git's modes IDs sizes and paths", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})

      for recursive <- [false, true] do
        assert {:ok, native} = Code.Native.root_tree(repository, "HEAD", recursive, 10_000)
        args = ["ls-tree", "--long", "-z"] ++ if(recursive, do: ["-r"], else: []) ++ ["HEAD"]
        assert {:ok, output} = Git.run(repository, args)

        expected =
          output
          |> String.split(<<0>>, trim: true)
          |> Enum.map(fn line ->
            [_, mode, type, oid, size, path] = Regex.run(~r/^(\d+)\s+(\w+)\s+(\S+)\s+(\S+)\t(.*)$/s, line)
            {mode, type, oid, if(size == "-", do: nil, else: String.to_integer(size)), path}
          end)

        assert native == expected
      end

      observe([:code, :git, :tree])
      observe([:code, :git, :command])
      assert {:ok, _} = Git.list_tree(repository, "HEAD", "", recursive: true)
      assert_receive {:observed, [:code, :git, :tree], _, %{source: :native, outcome: :ok}}
      refute_received {:observed, [:code, :git, :command], _, _}
      assert :timeout = Code.Native.root_tree(repository, "HEAD", true, 0)
    end

    test "pathspecs and rich revisions retain Git", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})
      assert :fallback_git = Code.Native.root_tree(repository, "HEAD~0", true, 10_000)
      observe([:code, :git, :tree])
      assert {:ok, _} = Git.list_tree(repository, "HEAD", ".", recursive: true)
      assert_receive {:observed, [:code, :git, :tree], _, %{source: :git, outcome: :ok}}
    end
  end

  describe "bounded native commit resolution" do
    test "HEAD, full refs and complete IDs agree with Git without subprocesses", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})

      for revision <- ["HEAD", "refs/heads/main", tip] do
        assert {:ok, ^tip} = Code.Native.resolve_commit(repository, revision, 10_000)

        assert {:ok, output} =
                 Git.run(repository, ["rev-parse", "--verify", "--end-of-options", revision <> "^{commit}"])

        assert String.trim(output) == tip
      end

      observe([:code, :git, :command])
      observe([:code, :git, :resolve])
      assert {:ok, ^tip} = Git.resolve(repository, "HEAD")
      assert_receive {:observed, [:code, :git, :resolve], _, %{source: :native, outcome: :ok}}
      refute_received {:observed, [:code, :git, :command], _, _}
      assert :timeout = Code.Native.resolve_commit(repository, "HEAD", 0)
    end

    test "revision syntax, missing IDs and annotated tags retain Git peeling", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})

      assert {:ok, _} =
               Git.run(repository, [
                 "-c",
                 "user.name=Test",
                 "-c",
                 "user.email=test@example.com",
                 "tag",
                 "-a",
                 "release",
                 "-m",
                 "annotated",
                 tip
               ])

      for revision <- ["HEAD~0", "main", "refs/tags/release", String.duplicate("1", 40), "--help"] do
        assert :fallback_git = Code.Native.resolve_commit(repository, revision, 10_000)
      end

      assert {:ok, ^tip} = Git.resolve(repository, "refs/tags/release")
      assert {:ok, ^tip} = Git.resolve(repository, "HEAD~0")
      assert {:error, _} = Git.resolve(repository, "--help")
    end

    test "loose commits validate content and declared size before returning an ID", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})
      assert {:ok, body} = Git.run(repository, ["cat-file", "commit", tip])
      loose = Path.join([repository, "objects", String.slice(tip, 0, 2), String.slice(tip, 2, 38)])
      File.mkdir_p!(Path.dirname(loose))
      File.write!(loose, :zlib.compress("commit #{byte_size(body)}\0" <> body))
      assert {:ok, ^tip} = Code.Native.resolve_commit(repository, "HEAD", 10_000)
      File.write!(loose, :zlib.compress("commit 1000000000\0" <> body))
      assert :fallback_git = Code.Native.resolve_commit(repository, "HEAD", 10_000)

      File.write!(
        loose,
        :zlib.compress("commit #{byte_size(body)}\0" <> String.duplicate("x", byte_size(body)))
      )

      assert :fallback_git = Code.Native.resolve_commit(repository, "HEAD", 10_000)
    end

    test "replacement refs and corrupted object bytes cannot bypass Git", %{root: root} do
      {repository, tip} = refs_repository(root)
      assert :ok = Git.reset_refs(repository, %{"refs/heads/main" => tip})
      File.mkdir_p!(Path.join(repository, "refs/replace"))
      assert :fallback_git = Code.Native.resolve_commit(repository, "HEAD", 10_000)
      File.rmdir!(Path.join(repository, "refs/replace"))
      [pack] = Git.packs(repository)
      bytes = File.read!(pack)

      overwrite(
        pack,
        binary_part(bytes, 0, 12) <>
          String.duplicate(<<0>>, byte_size(bytes) - 32) <> binary_part(bytes, byte_size(bytes) - 20, 20)
      )

      assert :fallback_git = Code.Native.resolve_commit(repository, "HEAD", 10_000)
    end
  end

  describe "bounded closure presence checks" do
    test "native walk enumerates exactly real Git's objects and refuses shallow/colliding output", %{
      root: root
    } do
      {repository, tip} = refs_repository(root)
      listed = Path.join(root, "native-walk")
      assert {:ok, count} = Code.Native.plain_walk(repository, [tip, tip], listed, 10_000)
      assert {:ok, expected} = Git.run(repository, ["rev-list", "--objects", "--no-object-names", tip])
      actual = listed |> File.read!() |> String.split("\n", trim: true) |> MapSet.new()
      assert actual == MapSet.new(String.split(expected, "\n", trim: true))
      assert count == MapSet.size(actual)
      assert :fallback_git = Code.Native.plain_walk(repository, [tip], listed, 10_000)
      assert actual == MapSet.new(String.split(File.read!(listed), "\n", trim: true))
      assert :timeout = Code.Native.plain_walk(repository, [tip], listed <> "-timeout", 0)
      File.write!(Path.join(repository, "shallow"), tip <> "\n")
      assert :fallback_git = Code.Native.plain_walk(repository, [tip], listed <> "-shallow", 10_000)
    end

    test "exclusion and quarantine walks remain Git and unprovided objects still fail", %{root: root} do
      {repository, tip} = refs_repository(root)
      observe([:code, :git, :closure_walk])
      assert {:ok, 0} = Git.count_unprovided(repository, [tip], [tip], nil)
      assert_receive {:observed, [:code, :git, :closure_walk], _, %{source: :git, outcome: :ok}}
      assert {:ok, missing} = Git.count_unprovided(repository, [tip], [], nil)
      assert missing > 0
      assert_receive {:observed, [:code, :git, :closure_walk], _, %{source: :native, outcome: :ok}}
      assert {:error, {:repack_incomplete, ^missing}} = Git.verify_packs_closed(repository, [], [tip])
    end

    test "pack-only presence agrees with real Git, including missing IDs", %{root: root} do
      {repository, tip} = refs_repository(root)
      listed = Path.join(root, "listed")
      File.write!(listed, tip <> "\n" <> String.duplicate("1", 40) <> "\n")
      objects = Path.join(repository, "objects")
      assert {:ok, 1} = Code.Native.packed_missing(repository, listed, objects, 10_000)

      assert {:ok, output} =
               Git.run(repository, ["cat-file", "--batch-check="],
                 stdin_file: listed,
                 env: [{"GIT_OBJECT_DIRECTORY", objects}, {"GIT_ALTERNATE_OBJECT_DIRECTORIES", nil}]
               )

      assert Enum.count(String.split(output, "\n"), &String.ends_with?(&1, " missing")) == 1
      assert :timeout = Code.Native.packed_missing(repository, listed, objects, 0)
      File.write!(listed, String.duplicate("x", 1000) <> "\n")
      assert :fallback_git = Code.Native.packed_missing(repository, listed, objects, 10_000)
    end

    test "closure independently walks and checks provision without subprocesses on ordinary packs", %{
      root: root
    } do
      {repository, tip} = refs_repository(root)
      observe([:code, :git, :command])
      observe([:code, :git, :closure_presence])
      assert :ok = Git.verify_packs_closed(repository, Git.packs(repository), [tip])
      assert_receive {:observed, [:code, :git, :closure_presence], _, %{source: :native, outcome: :ok}}
      refute_received {:observed, [:code, :git, :command], _, %{subcommand: "rev-list"}}
      refute_received {:observed, [:code, :git, :command], _, %{subcommand: "cat-file"}}
    end

    test "included config forces Git fallback whose stdout is never captured", %{root: root} do
      {repository, tip} = refs_repository(root)
      included = Path.join(root, "included.config")
      File.write!(included, "[custom]\n value = retained\n")
      assert :ok = Git.config(repository, "include.path", included)
      observe([:code, :git, :command])
      observe([:code, :git, :closure_presence])
      assert :ok = Git.verify_packs_closed(repository, Git.packs(repository), [tip])
      assert_receive {:observed, [:code, :git, :closure_presence], _, %{source: :git, outcome: :ok}}
      assert_receive {:observed, [:code, :git, :command], %{bytes: 0}, %{subcommand: "cat-file", status: 0}}
      assert Path.wildcard(Path.join(repository, ".code-verify-*")) == []
    end

    test "corrupt indexes and loose objects refuse the native presence path", %{root: root} do
      {repository, tip} = refs_repository(root)
      objects = Path.join(repository, "objects")
      listed = Path.join(root, "objects.list")
      File.write!(listed, tip <> "\n")
      File.mkdir!(Path.join(objects, "aa"))
      assert :fallback_git = Code.Native.packed_missing(repository, listed, objects, 10_000)
      File.rmdir!(Path.join(objects, "aa"))
      [pack] = Git.packs(repository)
      idx = Path.rootname(pack) <> ".idx"
      bytes = File.read!(idx)
      overwrite(idx, binary_part(bytes, 0, byte_size(bytes) - 1) <> <<Bitwise.bxor(:binary.last(bytes), 1)>>)
      assert :fallback_git = Code.Native.packed_missing(repository, listed, objects, 10_000)
    end
  end

  describe "HEAD convergence" do
    test "an exact valid match does not launch a write", %{root: root} do
      repository = Path.join(root, "head.git")
      assert :ok = Git.init_bare(repository)
      observe([:code, :git, :command])
      assert :ok = Git.set_head(repository, "refs/heads/main")
      refute_received {:observed, _, _, _}

      assert :ok = Git.set_head(repository, "refs/heads/next")
      assert_receive {:observed, _, _, %{subcommand: "symbolic-ref", status: 0}}
      assert {:ok, "refs/heads/next"} = Git.head(repository)
    end

    test "a matching prefix or invalid target cannot bypass Git", %{root: root} do
      repository = Path.join(root, "bad-head.git")
      assert :ok = Git.init_bare(repository)
      File.write!(Path.join(repository, "HEAD"), "ref: refs/heads/main\nextra")
      observe([:code, :git, :command])
      # Git may refuse this corrupt repository; either way it must execute.
      Git.set_head(repository, "refs/heads/main")
      assert_receive {:observed, _, _, %{subcommand: "symbolic-ref"}}

      File.write!(Path.join(repository, "HEAD"), "ref: refs/heads/bad..name\n")
      assert {:error, _} = Git.set_head(repository, "refs/heads/bad..name")
      assert_receive {:observed, _, _, %{subcommand: "symbolic-ref"}}
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

  describe "packing new objects" do
    test "objects already reachable from the basis need no pack", %{root: root} do
      source = fixture_repository()
      tip = oid(source)
      observe([:code, :git, :pack_objects])
      assert {:ok, nil} = Git.pack_objects(Path.join(source, ".git"), [tip], [tip], Path.join(root, "empty"))
      assert_receive {:observed, [:code, :git, :pack_objects], _, %{outcome: :empty}}
    end

    test "newly reachable objects produce a real pack", %{root: root} do
      source = fixture_repository()
      tip = oid(source)
      observe([:code, :git, :pack_objects])
      assert {:ok, pack} = Git.pack_objects(Path.join(source, ".git"), [tip], [], Path.join(root, "new"))
      assert is_binary(pack)
      assert {:ok, 3} = Code.Native.file_pack_count(pack)
      assert_receive {:observed, [:code, :git, :pack_objects], _, %{outcome: :nonempty}}
    end

    test "packing failure remains an error", %{root: root} do
      source = fixture_repository()
      observe([:code, :git, :pack_objects])

      assert {:error, _} =
               Git.pack_objects(
                 Path.join(source, ".git"),
                 [String.duplicate("f", 40)],
                 [],
                 Path.join(root, "bad")
               )

      assert_receive {:observed, [:code, :git, :pack_objects], _, %{outcome: :error}}
    end
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

    test "a disposable download is moved rather than copied", %{
      pack: pack,
      repository: repository,
      commit: commit
    } do
      inode = File.stat!(pack).inode
      bytes = File.stat!(pack).size
      observe([:code, :git, :pack_stage])
      assert {:ok, installed} = Git.install_pack(repository, pack, consume: true)
      refute File.exists?(pack)
      assert File.stat!(installed).inode == inode
      assert_receive {:observed, [:code, :git, :pack_stage], %{bytes: ^bytes}, %{outcome: :moved}}
      assert File.exists?(Path.rootname(installed) <> ".idx")
      assert Git.object?(repository, commit)
    end

    test "native index validation accepts explicit unrelated names and falls back before oversized metadata",
         %{pack: pack} do
      idx = Path.rootname(pack) <> ".idx"
      copied = Path.join(Path.dirname(pack), "unrelated.idx")
      File.cp!(idx, copied)
      observe([:code, :git, :pack_index_validate])
      assert true == Code.Native.file_index_matches(pack, copied)
      assert Git.valid_index?(pack, copied)
      assert_receive {:observed, [:code, :git, :pack_index_validate], _, %{source: :native, outcome: :valid}}
      File.chmod!(copied, 0o644)
      {:ok, io} = :file.open(copied, [:read, :write, :raw, :binary])
      {:ok, _} = :file.position(io, {:eof, 4 * 1024 * 1024})
      :ok = :file.write(io, <<0>>)
      :ok = :file.close(io)
      assert :fallback_git == Code.Native.file_index_matches(pack, copied)
      refute Git.valid_index?(pack, copied)

      assert_receive {:observed, [:code, :git, :pack_index_validate], _,
                      %{source: :elixir, outcome: :invalid}}
    end

    test "ordinary installation leaves the source independent", %{
      pack: pack,
      repository: repository,
      commit: commit
    } do
      assert {:ok, installed} = Git.install_pack(repository, pack)
      assert File.stat!(installed).inode != File.stat!(pack).inode
      overwrite(pack, "destroyed source")
      assert Git.object?(repository, commit)
    end

    test "consuming an aliased source is refused without changing it", %{pack: pack, repository: repository} do
      symlink = Path.join(Path.dirname(pack), "alias.pack")
      File.ln_s!(pack, symlink)
      assert {:error, :einval} = Git.install_pack(repository, symlink, consume: true)
      assert File.lstat!(symlink).type == :symlink
      File.rm!(symlink)
      File.ln!(pack, symlink)
      assert {:error, :einval} = Git.install_pack(repository, pack, consume: true)
      assert File.stat!(pack).links == 2
      assert Git.installed_packs(repository) == []
    end

    test "a consumed corrupt pack leaves no visible or staged artefacts", %{
      pack: pack,
      repository: repository
    } do
      File.rm!(Path.rootname(pack) <> ".idx")
      overwrite(pack, binary_part(File.read!(pack), 0, 40))
      assert {:error, _} = Git.install_pack(repository, pack, consume: true)
      assert Git.installed_packs(repository) == []
      assert Path.wildcard(Path.join(repository, "objects/pack/*"), match_dot: true) == []
    end

    test "rebuilds an index that does not match its pack", %{
      pack: pack,
      repository: repository,
      commit: commit
    } do
      idx = Path.rootname(pack) <> ".idx"
      bytes = File.read!(idx)
      # Replacing with zero occasionally leaves an already-zero checksum
      # unchanged. Flipping a bit guarantees this fixture is actually corrupt.
      overwrite(idx, binary_part(bytes, 0, byte_size(bytes) - 1) <> <<Bitwise.bxor(:binary.last(bytes), 1)>>)
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
