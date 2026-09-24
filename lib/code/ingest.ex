defmodule Code.Ingest do
  @moduledoc """
  Committing a push to the write-ahead log.

  This runs inside Git's `pre-receive` window: the objects have been received
  and checked but nothing is visible yet, and Git will apply the reference
  updates if and only if this returns success.

  Three things happen, in an order chosen so that a failure at any point leaves
  nothing half-done:

    1. **Upload the packs.** They are content-addressed and nothing references
       them yet, so this is idempotent and a crash here leaks at most an
       unreferenced object.
    2. **Write the entry.** Also content-addressed, also unreferenced.
    3. **Compare-and-swap the index.** This is the moment the push exists.
       Before it, nothing has happened; after it, the push is durable, ordered,
       and visible to every replica.

  ## Rejecting stale pushes across nodes

  Git gives the hook the `old` value each ref had *on this node*. That is not
  enough on its own: another node may have accepted a push in between, and this
  node's local view could be behind. So every command is checked against the
  index's ref map — the authoritative current state — inside the CAS retry
  loop, where it is re-read on each attempt.

  The result is that a non-fast-forward is rejected cluster-wide with the same
  certainty a single-server Git gets from its ref lock, without any node having
  to know what the others are doing.
  """

  require Logger

  alias Code.Cluster
  alias Code.Git
  alias Code.Git.Ref
  alias Code.Ingest.Writer
  alias Code.Replica
  alias Code.Replica.Lease
  alias Code.WAL
  alias Code.WAL.Entry
  alias Code.WAL.Index
  alias Code.Wal.V1

  @type command :: V1.RefCommand.t()

  @doc """
  Commit a push. Returns `{:ok, result}` when Git may apply the refs.

  The error tuple's second element is a message written for whoever ran
  `git push`, not for a log.
  """
  @spec commit(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def commit(repo_id, opts) do
    commands = Keyword.fetch!(opts, :commands)
    quarantine = Keyword.get(opts, :quarantine)
    actor = Keyword.get(opts, :actor, %V1.Actor{})
    started = System.monotonic_time(:millisecond)

    Code.Telemetry.span(
      "code.push.commit",
      %{
        "code.repository.id" => repo_id,
        "code.push.ref_count" => length(commands)
      },
      fn ->
        result =
          with {:ok, packs} <- collect_packs(repo_id, quarantine),
               {:ok, result} <- commit_pushed(repo_id, commands, packs, actor, quarantine, 1) do
            Replica.record_local_push(repo_id, result.epoch, result.seq)
            Cluster.announce(repo_id, result.epoch, result.seq)

            duration = System.monotonic_time(:millisecond) - started

            :telemetry.execute(
              [:code, :push, :committed],
              %{duration_ms: duration, refs: length(commands), packs: length(packs)},
              %{repo_id: repo_id, seq: result.seq}
            )

            Logger.info("push committed", repo_id: repo_id, seq: result.seq, duration_ms: duration)
            {:ok, result}
          else
            {:error, reason} ->
              :telemetry.execute([:code, :push, :rejected], %{}, %{
                repo_id: repo_id,
                reason: classify(reason)
              })

              {:error, message(reason)}
          end

        Code.Telemetry.put_span_attributes(%{
          "code.push.outcome" => if(match?({:ok, _}, result), do: "committed", else: "rejected")
        })

        result
      end
    )
  end

  # Objects arrive in a quarantine directory that Git discards if we fail.
  # With `receive.unpackLimit = 1` they are always a packfile, so the artefact
  # on disk and the artefact in the log are the same bytes and no repacking or
  # re-encoding stands between the client's push and what gets stored.
  defp collect_packs(_repo_id, nil), do: {:ok, []}

  defp collect_packs(repo_id, quarantine) do
    quarantine
    |> Path.join("pack/*.pack")
    |> Path.wildcard()
    |> Enum.reduce_while({:ok, []}, fn pack, {:ok, acc} ->
      case WAL.put_pack(repo_id, pack) do
        {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
        {:error, reason} -> {:halt, {:error, {:pack_upload_failed, reason}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # A pushed pack holds only what the client did not expect the server to have.
  # Everything else the new refs reach was, at the moment `receive-pack`
  # checked connectivity, somewhere in this node's object database — which is
  # a cache, and may hold objects no pack in the log provides (loose objects,
  # a pack the log stopped naming, a pack a compaction has since replaced).
  #
  # So before the push is proposed, its closure is proved against a real
  # version of the index: every object reachable from the new values and not
  # from that index's tips must be in the quarantine, whose packs are what gets
  # uploaded. The index's tips are closed within its packs, so that makes the
  # push closed within the log. The index it was proved against is recorded as
  # the entry's basis, and the writer re-checks the basis against whichever
  # index wins the compare-and-swap (see `Code.WAL.check_basis/2`); if a
  # compaction in between invalidated it, the proof is redone against the new
  # index, a bounded number of times.
  @closure_attempts 3

  defp commit_pushed(repo_id, commands, packs, actor, quarantine, attempt) do
    {basis, closure} = push_basis(repo_id, commands, quarantine, attempt)

    case append(repo_id, commands, packs, actor, basis: basis, closure: closure) do
      {:error, :basis_compacted} when attempt < @closure_attempts ->
        commit_pushed(repo_id, commands, packs, actor, quarantine, attempt + 1)

      other ->
        other
    end
  end

  defp push_basis(repo_id, commands, quarantine, attempt) do
    zero = Entry.zero_oid()
    tips = commands |> Enum.map(& &1.new_oid) |> Enum.reject(&(&1 == zero)) |> Enum.uniq()

    case basis_index(repo_id, attempt) do
      {:ok, index} ->
        exclude = index |> Index.tips() |> MapSet.to_list()
        {WAL.basis(index, exclude), closure(repo_id, tips, exclude, quarantine)}

      {:error, reason} ->
        {nil, {:error, {:closure_check_failed, reason}}}
    end
  end

  # The replica's own last read of the index on the first attempt: the local
  # repository holds everything its tips reach, which the proof's walk needs,
  # and it costs no round trip. A retry follows a compaction, so it reads the
  # index that won.
  defp basis_index(repo_id, 1) do
    case Replica.cached_index(repo_id) do
      {:ok, index} -> {:ok, index}
      :error -> basis_index(repo_id, 2)
    end
  end

  defp basis_index(repo_id, _attempt) do
    with {:ok, index, _etag} <- WAL.fetch(repo_id), do: {:ok, index}
  end

  defp closure(_repo_id, [], _exclude, _quarantine), do: :ok

  defp closure(repo_id, tips, exclude, quarantine) do
    started = System.monotonic_time(:microsecond)
    result = Git.count_unprovided(Replica.path(repo_id), tips, exclude, quarantine)

    outcome =
      case result do
        {:ok, 0} -> :closed
        {:ok, _missing} -> :incomplete
        {:error, _reason} -> :error
      end

    :telemetry.execute(
      [:code, :push, :closure_check],
      %{duration_us: System.monotonic_time(:microsecond) - started},
      %{repo_id: repo_id, outcome: outcome}
    )

    case result do
      {:ok, 0} -> :ok
      {:ok, missing} -> {:error, {:objects_not_provided, missing}}
      {:error, reason} -> {:error, {:closure_check_failed, reason}}
    end
  end

  # Uploading the entry and installing it in the index are separate steps on
  # purpose. The upload is content-addressed and contention-free, so it happens
  # on whichever node received the push; only the index update is funnelled
  # through the repository's writer, where concurrent pushes become one batch
  # instead of a queue of losers retrying. See `Code.Ingest.Writer`.
  defp append(repo_id, commands, packs, actor, opts) do
    entry =
      Entry.new(
        type: :ENTRY_TYPE_PUSH,
        commands: commands,
        packs: packs,
        actor: %{actor | node: Code.Config.node_id()}
      )

    # Re-run on every compare-and-swap attempt, against the index that actually
    # won, so a push racing another is judged against the winner's result and
    # not against whatever was true when it started.
    # Both checks run on every compare-and-swap attempt. The name check does
    # not depend on the index, but it belongs here because this is the last
    # point before a command becomes part of the log, and the log is where an
    # unrepresentable name does permanent damage.
    #
    # The closure proof is reported after the ref checks, not before: a push
    # that is stale or badly named is refused for that reason, which is the
    # one its author can act on.
    closure = Keyword.get(opts, :closure, :ok)

    validate = fn index ->
      with :ok <- check_ref_names(commands, Keyword.get(opts, :internal?, false)),
           :ok <- check_fast_forward(index, commands) do
        closure
      end
    end

    with {:ok, prepared} <- WAL.prepare(repo_id, entry, validate, basis: Keyword.get(opts, :basis)) do
      Writer.commit(repo_id, prepared)
    end
  end

  # A name Git cannot represent must never reach the log: it would be applied
  # by nobody, and every replica would fail to converge on it forever.
  defp check_ref_names(commands, internal?) do
    refs = Enum.map(commands, & &1.ref)

    with :ok <- Ref.validate(refs) do
      case Enum.find(refs, &Ref.internal?/1) do
        nil ->
          :ok

        ref ->
          if internal? and Enum.all?(refs, &Ref.internal?/1) do
            :ok
          else
            {:error, {:reserved_ref, ref}}
          end
      end
    end
  end

  defp check_fast_forward(index, commands) do
    Enum.reduce_while(commands, :ok, fn %V1.RefCommand{} = command, _acc ->
      current = Index.ref(index, command.ref)

      if current == command.old_oid do
        {:cont, :ok}
      else
        {:halt, {:error, {:stale, command.ref, command.old_oid, current}}}
      end
    end)
  end

  @doc """
  Parse the `<old> <new> <ref>` lines Git writes to the hook's stdin.
  """
  @spec parse_commands(String.t()) :: {:ok, [command()]} | {:error, String.t()}
  def parse_commands(body) do
    commands =
      body
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(String.trim(&1), " ", parts: 3))
      |> Enum.map(fn
        [old, new, ref] -> %V1.RefCommand{ref: ref, old_oid: old, new_oid: new}
        _ -> nil
      end)

    if Enum.any?(commands, &is_nil/1) do
      {:error, "malformed reference update"}
    else
      {:ok, commands}
    end
  end

  @doc """
  Resolve the quarantine directory Git handed the hook.

  `GIT_QUARANTINE_PATH` is usually relative to the repository, so it is
  resolved against the hook's working directory rather than ours.
  """
  @spec resolve_quarantine(String.t() | nil, String.t() | nil) :: Path.t() | nil
  def resolve_quarantine(nil, _git_dir), do: nil
  def resolve_quarantine("", _git_dir), do: nil

  def resolve_quarantine(quarantine, git_dir) do
    if Path.type(quarantine) == :absolute do
      quarantine
    else
      Path.expand(quarantine, git_dir || File.cwd!())
    end
  end

  @doc """
  Record a symbolic ref change, such as moving the default branch.

  It goes through the log like everything else, so replicas pick it up by the
  same mechanism and there is no second channel for "metadata" to get out of
  step with the repository itself.
  """
  @spec set_head(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_head(repo_id, target) do
    if Ref.internal?(target) do
      {:error, :reserved_ref}
    else
      entry = Entry.new(type: :ENTRY_TYPE_SYMREF, symrefs: %{"HEAD" => target})

      with {:ok, prepared} <- WAL.prepare(repo_id, entry, fn _index -> :ok end),
           {:ok, result} <- Writer.commit(repo_id, prepared) do
        Replica.record_local_push(repo_id, result.epoch, result.seq)
        Cluster.announce(repo_id, result.epoch, result.seq)
        {:ok, result}
      end
    end
  end

  @doc """
  Apply ref updates directly, without a Git client.

  This is the write path for the agent-facing API: an agent that has just
  written a tree and a commit needs the same durability and the same
  non-fast-forward checks as `git push`, so it takes the same road.
  """
  @spec update_refs(String.t(), [command()], keyword()) :: {:ok, map()} | {:error, String.t()}
  def update_refs(repo_id, commands, opts \\ []) do
    case update_refs_raw(repo_id, commands, opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @doc false
  @spec update_refs_raw(String.t(), [command()], keyword()) :: {:ok, map()} | {:error, term()}
  def update_refs_raw(repo_id, commands, opts \\ []), do: update_refs_raw(repo_id, commands, opts, 1)

  # A compaction landing between packing and the compare-and-swap can drop
  # objects the pack left out. The writer refuses that as `:basis_compacted`,
  # and the write is simply redone from a fresh read of the log.
  defp update_refs_raw(repo_id, commands, opts, attempt) do
    result =
      with {:ok, view} <- Replica.ensure_fresh(repo_id) do
        # Held from packing until the ref is applied locally: the new pack is
        # installed here before any index names it, and a sync must not prune
        # it in that window.
        Lease.hold(view.path, fn -> agent_write(repo_id, view, commands, opts) end)
      end

    case result do
      {:error, :basis_compacted} when attempt < @closure_attempts ->
        update_refs_raw(repo_id, commands, opts, attempt + 1)

      other ->
        other
    end
  end

  defp agent_write(repo_id, view, commands, opts) do
    with {:ok, index, _etag} <- WAL.fetch(repo_id),
         {:ok, packs, exclude} <- pack_new_objects(repo_id, view.path, commands, index),
         {:ok, result} <-
           append(repo_id, commands, packs, Keyword.get(opts, :actor, %V1.Actor{}),
             internal?: Keyword.get(opts, :internal?, false),
             basis: WAL.basis(index, exclude)
           ) do
      # The write is durable the moment the log accepted it, so a failure to
      # apply it locally cannot fail the call. It does mean this node is behind,
      # though, so its position is deliberately not recorded — the next read
      # re-reads the log and converges rather than believing it is current.
      #
      # The local update asserts the old values the log just validated. If the
      # local refs have moved in the meantime — a sync applied a later push —
      # applying this older one would move them backwards, so it is refused
      # and the next read converges instead.
      case Git.update_refs(view.path, commands, check_old?: true) do
        :ok ->
          Replica.record_local_push(repo_id, result.epoch, result.seq)

        {:error, reason} ->
          :telemetry.execute([:code, :push, :local_apply_failed], %{count: 1}, %{repo_id: repo_id})

          Logger.warning("could not apply committed push locally; the next read converges from the log",
            repo_id: repo_id,
            seq: result.seq,
            reason: inspect(reason)
          )
      end

      Cluster.announce(repo_id, result.epoch, result.seq)
      {:ok, result}
    end
  end

  # Objects written by the agent API land loose in the local repository and have
  # to become a packfile before they can be logged, because a pack is the only
  # unit the log carries.
  #
  # The pack holds exactly what this change introduced: everything reachable
  # from the proposed new values, minus everything already reachable from the
  # repository's current refs.
  #
  # `git repack` is the wrong tool here, and getting this wrong is silent. It
  # only packs objects reachable from a ref, and on this path the new commit
  # has no ref yet — the ref is precisely what we are proposing — so a repack
  # produces an empty pack and the log ends up naming an object no pack
  # provides. Every replica then fails to converge, while the node that wrote
  # it carries on happily, because it still has the objects loose on disk.
  # It would also rewrite and re-upload the entire repository on every commit.
  defp pack_new_objects(repo_id, path, commands, index) do
    zero = Entry.zero_oid()
    include = commands |> Enum.map(& &1.new_oid) |> Enum.reject(&(&1 == zero)) |> Enum.uniq()

    exclude = index.refs |> Map.values() |> Enum.uniq()

    if include == [] do
      # A pure deletion introduces no objects.
      {:ok, [], exclude}
    else
      scratch =
        Path.join(
          System.tmp_dir!(),
          "code-pack-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        )

      try do
        with {:ok, pack} <- Git.pack_objects(path, include, exclude, scratch) |> pack_failed(),
             {:ok, packs} <- upload_new_pack(repo_id, path, pack) do
          {:ok, packs, exclude}
        end
      after
        File.rm_rf(scratch)
      end
    end
  end

  defp pack_failed({:error, reason}), do: {:error, {:pack_failed, reason}}
  defp pack_failed(ok), do: ok

  defp upload_new_pack(_repo_id, _path, nil), do: {:ok, []}

  defp upload_new_pack(repo_id, path, pack) do
    with {:ok, descriptor} <- WAL.put_pack(repo_id, pack),
         # Install it locally too, so this node holds the same artefact every
         # other replica will download rather than a pile of loose objects.
         {:ok, _installed} <- Git.install_pack(path, pack) do
      {:ok, [descriptor]}
    else
      {:error, reason} -> {:error, {:pack_upload_failed, reason}}
    end
  end

  defp classify(:writer_overloaded), do: :overloaded
  defp classify(:writer_timeout), do: :timeout
  defp classify({:invalid_ref, _}), do: :invalid_ref
  defp classify({:reserved_ref, _}), do: :invalid_ref
  defp classify({:pack_failed, _}), do: :storage
  defp classify({:stale, _, _, _}), do: :non_fast_forward
  defp classify({:pack_upload_failed, _}), do: :storage
  defp classify(:cas_exhausted), do: :contention
  defp classify(:basis_compacted), do: :contention
  defp classify({:objects_not_provided, _}), do: :incomplete_push
  defp classify(reason) when reason in [:repository_deleted, :repository_replaced, :not_found], do: :deleted
  defp classify(_), do: :other

  defp message({:objects_not_provided, count}) do
    "code: the push refers to #{count} object(s) it did not include and the repository does not " <>
      "provide; fetch and push again"
  end

  defp message(:basis_compacted) do
    "code: the repository was compacted while this push was in flight; please retry"
  end

  defp message(reason) when reason in [:repository_deleted, :repository_replaced, :not_found] do
    "code: this repository does not exist or is being deleted"
  end

  defp message({:stale, ref, proposed, actual}) do
    """
    code: #{ref} has moved since you last fetched.
      you expected: #{short(proposed)}
      it is now:    #{short(actual)}
    Fetch and rebase, then push again.
    """
    |> String.trim()
  end

  defp message({:invalid_ref, ref}) do
    "code: #{inspect(ref)} is not a valid reference name"
  end

  defp message({:reserved_ref, ref}) do
    "code: #{inspect(ref)} is reserved for Code"
  end

  defp message(:writer_overloaded) do
    "code: too many pushes are queued for this repository; please retry"
  end

  # Unlike the other rejections this one is not a refusal: the batch may
  # still commit after the caller stopped waiting, so "rejected" would be a
  # lie that invites a blind retry.
  defp message(:writer_timeout) do
    "code: timed out waiting for this push to become durable; it may still land. " <>
      "Fetch to see whether it did before pushing again"
  end

  defp message(:cas_exhausted) do
    "code: too much concurrent write activity on this repository; please retry"
  end

  defp message({:pack_upload_failed, reason}) do
    "code: could not durably store the pushed objects (#{inspect(reason)}); nothing was applied"
  end

  defp message(reason), do: "code: push rejected (#{inspect(reason)})"

  defp short(oid) do
    zero = Entry.zero_oid()
    if oid == zero, do: "(absent)", else: String.slice(oid, 0, 12)
  end
end
