defmodule Code.WAL do
  @moduledoc """
  The write-ahead log: the source of truth for every repository.

  ## Layout

      repos/<repo_id>/index.pb                     the only mutable object, under CAS
      repos/<repo_id>/wal/<digest>.pb              entries, immutable, content-addressed
      repos/<repo_id>/packs/<name>.pack            packfiles, immutable
      repos/<repo_id>/packs/<name>.idx
      repos/<repo_id>/history/<epoch>-<digest>.pb  index snapshots kept for provenance

  Everything but the packfiles is protobuf (`priv/proto/code/wal/v1`). The
  log outlives any single version of this code, so its encoding is a schema
  with compatibility rules rather than whatever a serializer happened to emit.

  ## How a push becomes visible

  Objects are written before they are referenced, and the reference is
  installed with a compare-and-swap:

    1. The packfile is uploaded. It is content-addressed, so this is idempotent
       and can be retried freely.
    2. The entry describing the ref transaction is uploaded under the hash of
       its own bytes. Also idempotent, which is why a lost CAS costs one small
       `PUT` on retry rather than re-uploading the pack.
    3. The index is read, the entry pointer appended, and the result written
       back with `If-Match` on the ETag we read. Exactly one writer can win.

  Nothing is acknowledged to the client until step 3 succeeds. A push that is
  in the log is durable and ordered. When the store's answer to step 3 is lost
  — a precondition failure on a write that actually landed, or a transport
  error after the store accepted it — the index is re-read and the entry's
  content address looked up, so a write that landed is reported as the success
  it was.

  ## Why there is no consensus protocol here

  Ordering is decided by one atomic operation on one object. That is enough to
  linearize pushes, which means any node can accept a push without first
  agreeing with the others about who is in charge. Losing the race is not a
  failure: it means someone else's push landed first, so we re-read and try
  again against the state they left behind.
  """

  require Logger

  alias Code.Config
  alias Code.ObjectStore
  alias Code.WAL.Entry
  alias Code.WAL.Index

  @type repo_id :: String.t()
  @type read_result :: {:ok, Index.t(), ObjectStore.etag()} | {:ok, :not_modified} | {:error, term()}

  @cas_attempts 12
  @content_type "application/vnd.code.wal.v1+protobuf"

  @typedoc """
  What a prepared entry's objects were computed against.

  A writer that leaves objects out of its pack because the repository already
  has them — the agent API excluding everything reachable from the current
  refs, or a Git client omitting what the server advertised — is only correct
  if the index it finally lands in still provides those objects. `tips` are
  the object ids the omission was relative to, `epoch` and `incarnation` the
  index they came from. See `check_basis/2` for how it is judged.
  """
  @type basis :: %{incarnation: String.t(), epoch: non_neg_integer(), tips: [String.t()]}

  @typedoc """
  An entry whose object is already stored, ready to be installed in the index.

  `validate` is re-run against the live index on every compare-and-swap
  attempt, so a check like "this ref must still be where the client thought"
  is evaluated against the state that actually won, not a stale read. `basis`,
  when present, is checked the same way.
  """
  @type prepared :: %{
          required(:entry) => Entry.t(),
          required(:key) => String.t(),
          required(:size) => non_neg_integer(),
          required(:digest) => String.t(),
          required(:validate) => (Index.t() -> :ok | {:error, term()}),
          optional(:basis) => basis() | nil
        }

  @doc "Validate a repository identifier, which is also an object-store key prefix."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id) do
    byte_size(id) <= 512 and
      Regex.match?(~r{^[a-zA-Z0-9][a-zA-Z0-9._\-]*(/[a-zA-Z0-9][a-zA-Z0-9._\-]*)*$}, id) and
      not String.contains?(id, "..")
  end

  def valid_id?(_), do: false

  @spec index_key(repo_id()) :: String.t()
  def index_key(repo_id), do: "repos/#{repo_id}/index.pb"

  @spec entry_key(repo_id(), String.t()) :: String.t()
  def entry_key(repo_id, digest), do: "repos/#{repo_id}/wal/#{digest}.pb"

  @spec pack_key(repo_id(), String.t()) :: String.t()
  def pack_key(repo_id, name), do: "repos/#{repo_id}/packs/#{name}"

  @doc """
  Where the snapshot of one exact index version is kept.

  Keyed by the digest of the snapshot's bytes as well as its epoch. Two
  compactions racing from the same epoch but different sequence numbers write
  two different snapshots rather than one silently standing in for the other,
  and the base that wins records which one it replaced.
  """
  @spec history_key(repo_id(), non_neg_integer(), String.t()) :: String.t()
  def history_key(repo_id, epoch, digest), do: "repos/#{repo_id}/history/#{epoch}-#{digest}.pb"

  @doc """
  Create the log for a new repository.

  Uses `If-None-Match: *`, so if two nodes create the same repository at the
  same moment exactly one wins and the other is told `:already_exists`. No
  locking, no coordination.

  Every repository gets a fresh `incarnation`, so one created under the id of a
  deleted repository is distinguishable from it: work prepared against the old
  one cannot land in the new one.
  """
  @spec create(repo_id(), keyword()) ::
          {:ok, Index.t()} | {:error, :already_exists | :deletion_in_progress | term()}
  def create(repo_id, opts \\ []) do
    unless valid_id?(repo_id), do: throw({:invalid_repo_id, repo_id})

    index = Index.new(repo_id, Keyword.put_new(opts, :node_id, Config.node_id()))

    case ObjectStore.put(index_key(repo_id), Index.encode(index),
           if_none_match: "*",
           content_type: @content_type
         ) do
      {:ok, _etag} -> {:ok, index}
      {:error, :precondition_failed} -> existing(repo_id)
      {:error, reason} -> {:error, reason}
    end
  catch
    {:invalid_repo_id, id} -> {:error, {:invalid_repo_id, id}}
  end

  # The name is taken. A tombstone still holds it until its cleanup finishes,
  # and saying so is more useful than claiming the repository exists.
  defp existing(repo_id) do
    case read_raw(repo_id, nil) do
      {:ok, index, _etag} ->
        if Index.deleted?(index), do: {:error, :deletion_in_progress}, else: {:error, :already_exists}

      _ ->
        {:error, :already_exists}
    end
  end

  @doc """
  Read the index, optionally conditionally.

  Passing the ETag from a previous read turns this into the cheap path that the
  whole consistency story rests on: a `304` is a metadata-only round trip and
  means the replica may serve immediately.

  A repository whose deletion has begun reads as `:not_found`: from the moment
  the tombstone is written it no longer exists for anyone but the cleanup.
  """
  @spec read(repo_id(), ObjectStore.etag() | nil) :: read_result()
  def read(repo_id, etag \\ nil) do
    case read_raw(repo_id, etag) do
      {:ok, index, new_etag} ->
        if Index.deleted?(index), do: {:error, :not_found}, else: {:ok, index, new_etag}

      other ->
        other
    end
  end

  defp read_raw(repo_id, etag) do
    started = System.monotonic_time(:microsecond)
    result = ObjectStore.get(index_key(repo_id), etag: etag)
    duration = System.monotonic_time(:microsecond) - started

    case result do
      {:ok, :not_modified} ->
        emit_read(:not_modified, duration, repo_id)
        {:ok, :not_modified}

      {:ok, body, new_etag} ->
        emit_read(:modified, duration, repo_id)

        with {:ok, index} <- Index.decode(body), do: {:ok, index, new_etag}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Read the index unconditionally, failing if the repository does not exist."
  @spec fetch(repo_id()) :: {:ok, Index.t(), ObjectStore.etag()} | {:error, term()}
  def fetch(repo_id) do
    case read(repo_id, nil) do
      {:ok, :not_modified} -> {:error, :unexpected_not_modified}
      other -> other
    end
  end

  # What every writer reads. Unlike `fetch/1` it names a tombstone for what it
  # is, so a push racing a deletion is told why it was refused.
  defp fetch_live(repo_id) do
    case read_raw(repo_id, nil) do
      {:ok, :not_modified} ->
        {:error, :unexpected_not_modified}

      {:ok, index, etag} ->
        if Index.deleted?(index), do: {:error, :repository_deleted}, else: {:ok, index, etag}

      other ->
        other
    end
  end

  @doc """
  Append an entry to the log, retrying until the compare-and-swap wins.

  `build` receives the current index and returns `{:ok, entry}` to proceed or
  `{:error, reason}` to abort. It is re-invoked on every attempt, so a caller
  that needs to validate against the latest state (a non-fast-forward check,
  say) sees fresh data each time rather than deciding once against a stale read.

  Returns the entry's assigned sequence number and the resulting index.
  """
  @spec append(repo_id(), (Index.t() -> {:ok, Entry.t()} | {:error, term()})) ::
          {:ok, %{seq: non_neg_integer(), epoch: non_neg_integer(), index: Index.t()}} | {:error, term()}
  def append(repo_id, build) do
    append(repo_id, build, @cas_attempts)
  end

  defp append(_repo_id, _build, 0), do: {:error, :cas_exhausted}

  defp append(repo_id, build, attempts) do
    with {:ok, index, etag} <- fetch_live(repo_id),
         {:ok, entry} <- build.(index),
         {:ok, key, size, digest} <- put_entry(repo_id, entry) do
      updated = Index.append(index, entry, key, size, digest, Config.node_id())

      case ObjectStore.put(index_key(repo_id), Index.encode(updated),
             if_match: etag,
             content_type: @content_type
           ) do
        {:ok, _etag} ->
          :telemetry.execute(
            [:code, :wal, :append],
            %{seq: updated.seq, attempts: @cas_attempts - attempts + 1},
            %{
              repo_id: repo_id
            }
          )

          {:ok, %{seq: updated.seq, epoch: updated.epoch, index: updated}}

        {:error, :precondition_failed} ->
          # Either somebody else's push landed between our read and our write,
          # or ours landed and we never heard the answer. Those are
          # indistinguishable from here, and treating the second as the first
          # is how an operation that succeeded gets reported as rejected.
          #
          # The entry is addressed by the hash of its own bytes, so the
          # question is answerable: if the index already carries this exact
          # entry, the write was ours and it is already durable.
          :telemetry.execute([:code, :wal, :cas_retry], %{attempts: 1}, %{repo_id: repo_id})

          case already_committed(repo_id, digest) do
            {:ok, position} ->
              emit_ambiguous(repo_id, position.seq, :precondition_failed)
              {:ok, position}

            :no ->
              backoff(@cas_attempts - attempts)
              append(repo_id, build, attempts - 1)
          end

        {:error, reason} ->
          # A transport error or a server error is no more a rejection than a
          # precondition failure is: the store may have applied the write and
          # lost the response. The same content-address check answers it.
          case already_committed(repo_id, digest) do
            {:ok, position} ->
              emit_ambiguous(repo_id, position.seq, :transport_error)
              {:ok, position}

            :no ->
              {:error, reason}
          end
      end
    end
  end

  @doc """
  Append several prepared entries under a single compare-and-swap.

  This is group commit. Each push already uploaded its own packs and its own
  entry object — both content-addressed, both contention-free — so the only
  serialized part is installing the pointers in the index. Doing that for a
  batch costs one read and one conditional write regardless of how many pushes
  are in it, which is what turns per-repository write throughput from "one
  round trip per push" into "one round trip per batch".

  Each prepared entry is validated in turn against the index as it evolves, so
  a batch behaves exactly as if its pushes had arrived one at a time: a push
  that would be a non-fast-forward *given the ones ahead of it in the batch* is
  rejected, and the rest still land. Results come back in the order given.
  """
  @spec append_batch(repo_id(), [prepared()]) ::
          {:ok, [{:ok, %{seq: non_neg_integer(), epoch: non_neg_integer()}} | {:error, term()}]}
          | {:error, term()}
  def append_batch(repo_id, prepared), do: append_batch(repo_id, prepared, @cas_attempts)

  defp append_batch(_repo_id, _prepared, 0), do: {:error, :cas_exhausted}

  defp append_batch(repo_id, prepared, attempts) do
    with {:ok, index, etag} <- fetch_live(repo_id) do
      {updated, results} = apply_batch(index, prepared)

      if updated == index do
        # Every entry in the batch was rejected, so there is nothing to write.
        {:ok, results}
      else
        case ObjectStore.put(index_key(repo_id), Index.encode(updated),
               if_match: etag,
               content_type: @content_type
             ) do
          {:ok, _etag} ->
            :telemetry.execute(
              [:code, :wal, :append_batch],
              %{size: length(prepared), seq: updated.seq},
              %{repo_id: repo_id}
            )

            {:ok, results}

          {:error, :precondition_failed} ->
            # The retry folds the batch again against the index that won, and
            # `apply_batch/2` recognises entries of ours that are already in it.
            :telemetry.execute([:code, :wal, :cas_retry], %{attempts: 1}, %{repo_id: repo_id})
            backoff(@cas_attempts - attempts)
            append_batch(repo_id, prepared, attempts - 1)

          {:error, reason} ->
            reconcile_batch(repo_id, prepared, results, reason)
        end
      end
    end
  end

  # The conditional write failed without a precondition answer, so it may or
  # may not have landed. Every entry this attempt tried to install is looked up
  # by content address in the index as it now stands: found means committed,
  # whatever the transport said. Entries the batch had already rejected keep
  # their own reasons.
  defp reconcile_batch(repo_id, prepared, results, reason) do
    case fetch_live(repo_id) do
      {:ok, index, _etag} ->
        committed = Enum.reduce(index.entries, %{}, &Map.put_new(&2, &1.digest, &1.seq))

        reconciled =
          prepared
          |> Enum.zip(results)
          |> Enum.map(fn
            {item, {:ok, _position}} ->
              case Map.fetch(committed, item.digest) do
                {:ok, seq} -> {:committed, {:ok, %{seq: seq, epoch: index.epoch}}}
                :error -> {:unknown, {:error, reason}}
              end

            {_item, rejected} ->
              {:rejected, rejected}
          end)

        if Enum.any?(reconciled, &match?({:committed, _}, &1)) do
          emit_ambiguous(repo_id, index.seq, :transport_error)
          {:ok, Enum.map(reconciled, &elem(&1, 1))}
        else
          {:error, reason}
        end

      {:error, _unreadable} ->
        {:error, reason}
    end
  end

  # Whether an entry with this digest is already installed.
  #
  # Only meaningful because entries are content-addressed and a digest is
  # therefore unique to one proposed change: finding it means this attempt
  # already succeeded, not that someone else made the same change.
  defp already_committed(repo_id, digest) do
    with {:ok, index, _etag} <- fetch_live(repo_id),
         pointer when not is_nil(pointer) <- Enum.find(index.entries, &(&1.digest == digest)) do
      {:ok, %{seq: pointer.seq, epoch: index.epoch, index: index}}
    else
      _ -> :no
    end
  end

  # Fold the batch in order, so each entry sees the ref state left by the ones
  # before it. An entry already present in the index is a previously successful
  # conditional write whose response was lost. Returning its original position
  # is essential: blindly appending it again would make a group commit visible
  # twice after an ambiguous response.
  defp apply_batch(index, prepared) do
    # A batch can contain 256 pushes and the active log can contain many more
    # entries. Indexing the current digests once avoids rescanning the whole
    # log for every push while preserving the first sequence number if a legacy
    # index already has duplicate pointers from an older writer.
    committed = Enum.reduce(index.entries, %{}, &Map.put_new(&2, &1.digest, &1.seq))

    {index, _committed, results} =
      Enum.reduce(prepared, {index, committed, []}, fn item, {index, committed, results} ->
        case Map.fetch(committed, item.digest) do
          :error ->
            case validate(index, item) do
              :ok ->
                updated = Index.append(index, item.entry, item.key, item.size, item.digest, Config.node_id())

                {
                  updated,
                  Map.put(committed, item.digest, updated.seq),
                  [{:ok, %{seq: updated.seq, epoch: updated.epoch}} | results]
                }

              {:error, reason} ->
                {index, committed, [{:error, reason} | results]}
            end

          {:ok, seq} ->
            {index, committed, [{:ok, %{seq: seq, epoch: index.epoch}} | results]}
        end
      end)

    {index, Enum.reverse(results)}
  end

  defp validate(index, item) do
    with :ok <- check_basis(index, Map.get(item, :basis)), do: item.validate.(index)
  end

  @doc """
  Whether objects omitted relative to `basis` are still provided by `index`.

  Packs only ever accumulate within an epoch, so an index in the basis's epoch
  still requires every pack the basis did, and everything reachable from the
  basis tips is still there. Compaction replaces the pack set with a repack of
  the base refs, so across an epoch the omission is safe only if every tip it
  was relative to is still a tip of `index`: those are exactly the objects the
  new pack set is known to contain (see `Code.WAL.Index.tips/1`). Anything
  else is refused as `:basis_compacted`, and the writer recomputes against a
  fresh index rather than committing a ref to an object no pack provides.

  A basis from a different incarnation belongs to a repository that was
  deleted, and is refused whatever its objects.
  """
  @spec check_basis(Index.t(), basis() | nil) ::
          :ok | {:error, :basis_compacted | :repository_replaced}
  def check_basis(_index, nil), do: :ok

  def check_basis(%{incarnation: current}, %{incarnation: basis}) when current != basis,
    do: {:error, :repository_replaced}

  def check_basis(%{epoch: epoch}, %{epoch: epoch}), do: :ok

  def check_basis(index, %{tips: tips}) do
    live = Index.tips(index)

    if Enum.all?(tips, &MapSet.member?(live, &1)) do
      :ok
    else
      :telemetry.execute([:code, :wal, :basis_compacted], %{count: 1}, %{repo_id: index.repo_id})
      {:error, :basis_compacted}
    end
  end

  @doc """
  The basis a writer records when it computes a pack against `index`,
  omitting everything reachable from `tips`.
  """
  @spec basis(Index.t(), Enumerable.t()) :: basis()
  def basis(index, tips) do
    %{incarnation: index.incarnation, epoch: index.epoch, tips: Enum.uniq(tips)}
  end

  @doc """
  Upload an entry object and return what `append_batch/2` needs to install it.

  Separated from the append so the expensive, contention-free part — writing
  content-addressed objects — happens on whichever node received the push,
  while only the index update is funnelled through one writer.

  Pass `basis:` when the entry's packs omit objects the repository already
  has; it is checked against the index that wins the compare-and-swap.
  """
  @spec prepare(repo_id(), Entry.t(), (Index.t() -> :ok | {:error, term()}), keyword()) ::
          {:ok, prepared()} | {:error, term()}
  def prepare(repo_id, entry, validate, opts \\ []) do
    body = Entry.encode(entry)
    digest = digest(body)
    key = entry_key(repo_id, digest)

    with {:ok, _} <- write_immutable(key, body) do
      {:ok,
       %{
         entry: entry,
         key: key,
         size: byte_size(body),
         digest: digest,
         validate: validate,
         basis: Keyword.get(opts, :basis)
       }}
    end
  end

  @doc """
  Replace the log's base with a compaction result.

  The previous index is snapshotted first, under a key derived from its own
  bytes, so the full sequence of states a repository has been in stays
  reconstructible even though the active index no longer lists the replayed
  entries. The new base records that key, which binds it to the exact index
  version it replaced rather than to whichever snapshot happened to be written
  first for the epoch.

  Compaction is itself a compare-and-swap, so a push racing a compaction cannot
  be lost: whichever lands second sees the other's result and retries.
  """
  @spec compact(repo_id(), [Entry.pack()], map(), map(), Index.t(), ObjectStore.etag()) ::
          {:ok, Index.t()} | {:error, term()}
  def compact(repo_id, packs, refs, symrefs, index, etag) do
    snapshot = Index.encode(index)
    history = history_key(repo_id, index.epoch, digest(snapshot))

    if Index.deleted?(index) do
      {:error, :repository_deleted}
    else
      with {:ok, _} <- write_immutable(history, snapshot) do
        compacted = Index.rebase(index, packs, refs, symrefs, Config.node_id(), history)

        case ObjectStore.put(index_key(repo_id), Index.encode(compacted),
               if_match: etag,
               content_type: @content_type
             ) do
          {:ok, _etag} ->
            :telemetry.execute([:code, :wal, :compact], %{epoch: compacted.epoch, packs: length(packs)}, %{
              repo_id: repo_id
            })

            {:ok, compacted}

          {:error, :precondition_failed} ->
            {:error, :raced}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @doc "Read one entry, verifying it against the digest recorded in the index."
  @spec read_entry(repo_id(), Index.pointer()) :: {:ok, Entry.t()} | {:error, term()}
  def read_entry(_repo_id, pointer) do
    case ObjectStore.get(pointer.key) do
      {:ok, body, _etag} ->
        if digest(body) == pointer.digest do
          Entry.decode(body)
        else
          {:error, {:entry_digest_mismatch, pointer.key}}
        end

      {:ok, :not_modified} ->
        {:error, :unexpected_not_modified}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Upload a packfile and its index, returning the descriptor to record in a WAL
  entry.

  Packs are content-addressed by Git itself, so a name collision means the same
  object set, and re-uploading is a no-op. `If-None-Match: *` makes that
  explicit: a precondition failure here is success.

  The pack never passes through a binary of its own size: it is hashed in
  chunks and uploaded as a stream. A repository's history is set by the
  customer, so buffering one would make a node's memory ceiling somebody
  else's repository.
  """
  @spec put_pack(repo_id(), Path.t()) :: {:ok, Entry.pack()} | {:error, term()}
  def put_pack(repo_id, pack_path) do
    name = Path.basename(pack_path)

    with {:ok, digest, size} <- ObjectStore.digest_file(pack_path),
         {:ok, _} <- stream_immutable(pack_key(repo_id, name), pack_path),
         :ok <- put_pack_index(repo_id, pack_path) do
      :telemetry.execute([:code, :wal, :pack_upload], %{bytes: size}, %{repo_id: repo_id})
      {:ok, %Code.Wal.V1.Pack{key: pack_key(repo_id, name), size: size, digest: digest}}
    end
  end

  defp put_pack_index(repo_id, pack_path) do
    idx = Path.rootname(pack_path) <> ".idx"

    if File.exists?(idx) do
      with {:ok, _} <- stream_immutable(pack_key(repo_id, Path.basename(idx)), idx), do: :ok
    else
      # Not fatal: a replica can rebuild the index locally with `index-pack`.
      :ok
    end
  end

  @doc """
  Download a pack (and its index when present) into `dir`.

  The pack is written to a temporary name, verified against the digest the log
  recorded, and only then renamed to its real name, so a truncated or
  corrupted transfer fails here rather than surfacing as a mysterious
  repository error later, and a caller never finds a half-written file where a
  verified one is expected.

  The pack's `.idx` is downloaded beside it when the store has one. It carries
  no digest in the log, so it is a hint: `Code.Git.install_pack/2` checks it
  against the pack and rebuilds it when it does not match.
  """
  @spec get_pack(repo_id(), Entry.pack(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def get_pack(repo_id, pack, dir) do
    File.mkdir_p!(dir)
    name = Path.basename(pack.key)
    destination = Path.join(dir, name)
    partial = destination <> ".part"

    case ObjectStore.get_file(pack.key, partial) do
      {:ok, size} ->
        case verify_pack(partial, pack) do
          :ok ->
            File.rename!(partial, destination)
            :telemetry.execute([:code, :wal, :pack_download], %{bytes: size}, %{repo_id: repo_id})
            fetch_pack_index(pack, dir, name)
            {:ok, destination}

          {:error, reason} ->
            File.rm(partial)
            {:error, reason}
        end

      {:error, reason} ->
        File.rm(partial)
        {:error, reason}
    end
  end

  defp verify_pack(_path, %{digest: digest}) when digest in [nil, ""], do: :ok

  defp verify_pack(path, pack) do
    expected = pack.digest

    case ObjectStore.digest_file(path) do
      {:ok, ^expected, _size} -> :ok
      {:ok, _other, _size} -> {:error, {:pack_digest_mismatch, pack.key}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_pack_index(pack, dir, name) do
    idx_key = Path.rootname(pack.key) <> ".idx"
    destination = Path.join(dir, Path.rootname(name) <> ".idx")
    partial = destination <> ".part"

    case ObjectStore.get_file(idx_key, partial) do
      {:ok, _size} -> File.rename(partial, destination)
      _ -> File.rm(partial)
    end

    :ok
  end

  # ----------------------------------------------------------------------
  # Deletion
  # ----------------------------------------------------------------------

  @doc """
  Begin deleting a repository by tombstoning its index.

  From the moment this returns the repository reads as not found, and every
  writer is refused with `:repository_deleted`, including one that read the
  live index before the tombstone: its conditional write loses and its re-read
  finds the tombstone. Idempotent: a repository already tombstoned returns
  its tombstone, so an interrupted deletion can be resumed.
  """
  @spec tombstone(repo_id()) :: {:ok, Index.t()} | {:error, :not_found | {:invalid_repo_id, term()} | term()}
  def tombstone(repo_id), do: tombstone(repo_id, @cas_attempts)

  defp tombstone(_repo_id, 0), do: {:error, :cas_exhausted}

  defp tombstone(repo_id, attempts) do
    with :ok <- check_id(repo_id),
         {:ok, index, etag} <- fetch_raw(repo_id) do
      if Index.deleted?(index), do: {:ok, index}, else: write_tombstone(repo_id, index, etag, attempts)
    end
  end

  defp write_tombstone(repo_id, index, etag, attempts) do
    tombstoned = Index.tombstone(index, Config.node_id())

    case ObjectStore.put(index_key(repo_id), Index.encode(tombstoned),
           if_match: etag,
           content_type: @content_type
         ) do
      {:ok, _etag} ->
        {:ok, tombstoned}

      {:error, :precondition_failed} ->
        backoff(@cas_attempts - attempts)
        tombstone(repo_id, attempts - 1)

      # Possibly written: the next attempt reads it back and, finding the
      # tombstone, returns it.
      {:error, _reason} when attempts > 1 ->
        tombstone(repo_id, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_id(repo_id), do: if(valid_id?(repo_id), do: :ok, else: {:error, {:invalid_repo_id, repo_id}})

  defp fetch_raw(repo_id) do
    case read_raw(repo_id, nil) do
      {:ok, :not_modified} -> {:error, :unexpected_not_modified}
      other -> other
    end
  end

  @doc """
  Delete every object belonging to a repository. Irreversible.

  Repository ids nest — `acme/app` and `acme/app/tools` are both valid — so
  this never deletes by prefix. It tombstones the index, then deletes exactly
  the keys the repository's own layout produces: those its index names, and
  anything else under its `wal/`, `packs/` and `history/` directories whose
  name has the shape this module writes there. A nested repository's objects
  always sit at least one directory deeper and never match.

  `extra_keys` lists further keys the caller owns on the repository's behalf
  (the factory's run records). It is called only after the tombstone is in
  place, so nothing created through a live index can appear after it looked,
  and its keys are deleted in the same pass.

  The tombstone is removed only once every other deletion has succeeded, so a
  partial failure leaves the repository refusing writes and the deletion
  resumable; it is reported as `{:error, {:partial_cleanup, failed}}` with the
  number of keys that could not be removed.
  """
  @spec destroy(repo_id(), (-> {:ok, [String.t()]} | {:error, term()})) ::
          :ok | {:error, :not_found | {:partial_cleanup, pos_integer()} | term()}
  def destroy(repo_id, extra_keys \\ fn -> {:ok, []} end) do
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, index} <- tombstone(repo_id),
           :ok <- mark_deleting(repo_id),
           {:ok, owned} <- owned_keys(repo_id, index),
           {:ok, extra} <- extra_keys.() do
        keys = Enum.uniq(owned ++ extra)
        failed = delete_keys(keys)

        # The marker goes before the index: an orphaned marker with no index
        # next to it would hide a repository later created under the same id.
        if failed == [] do
          with :ok <- ObjectStore.delete(deleting_key(repo_id)),
               :ok <- ObjectStore.delete(index_key(repo_id)),
               do: {:ok, length(keys)}
        else
          Logger.error("repository deletion left objects behind",
            repo_id: repo_id,
            failed: length(failed),
            deleted: length(keys) - length(failed),
            reason: inspect(hd(failed))
          )

          {:error, {:partial_cleanup, length(failed)}}
        end
      end

    outcome =
      case result do
        {:ok, _} -> :ok
        {:error, {:partial_cleanup, _}} -> :partial
        {:error, :not_found} -> :not_found
        {:error, _} -> :error
      end

    :telemetry.execute(
      [:code, :wal, :destroy],
      %{duration_ms: System.monotonic_time(:millisecond) - started, objects: deleted_count(result)},
      %{repo_id: repo_id, outcome: outcome}
    )

    case result do
      {:ok, _count} -> :ok
      error -> error
    end
  end

  # A listing hint, not state: the tombstone in the index is what refuses
  # writes and reads. The marker sits beside `index.pb` so the repository walk,
  # which already sees every key at that level, can leave a repository whose
  # deletion is in progress (or stopped at partial cleanup) out of the list
  # without reading its index.
  defp mark_deleting(repo_id) do
    case ObjectStore.put(deleting_key(repo_id), "", content_type: "application/octet-stream") do
      {:ok, _etag} -> :ok
      error -> error
    end
  end

  @doc false
  @spec deleting_key(repo_id()) :: String.t()
  def deleting_key(repo_id), do: "repos/#{repo_id}/deleting"

  defp deleted_count({:ok, count}), do: count
  defp deleted_count(_), do: 0

  defp delete_keys(keys) do
    keys
    |> Task.async_stream(fn key -> {key, ObjectStore.delete(key)} end,
      max_concurrency: 16,
      timeout: :timer.minutes(2),
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {_key, :ok}} -> []
      {:ok, {key, {:error, reason}}} -> [{key, reason}]
      {:exit, reason} -> [{:unknown, reason}]
    end)
  end

  @owned_patterns [
    {"wal/", ~r"^wal/[0-9a-f]{64}\.pb$"},
    {"packs/", ~r"^packs/pack-[0-9a-f]{40,64}\.(pack|idx|rev|bitmap)$"},
    {"history/", ~r"^history/[0-9]+(-[0-9a-f]{64})?\.pb$"}
  ]

  @doc false
  @spec owned_keys(repo_id(), Index.t()) :: {:ok, [String.t()]} | {:error, term()}
  def owned_keys(repo_id, index) do
    prefix = "repos/#{repo_id}/"

    named =
      Enum.flat_map(index.entries, &[&1.key]) ++
        Enum.flat_map(Index.required_packs(index), &[&1.key, Path.rootname(&1.key) <> ".idx"]) ++
        if(index.base.history_key != "", do: [index.base.history_key], else: [])

    Enum.reduce_while(@owned_patterns, {:ok, named}, fn {dir, pattern}, {:ok, acc} ->
      case ObjectStore.list(prefix <> dir) do
        {:ok, entries} ->
          owned =
            entries
            |> Enum.map(& &1.key)
            |> Enum.filter(&Regex.match?(pattern, String.replace_prefix(&1, prefix, "")))

          {:cont, {:ok, acc ++ owned}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, keys |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.uniq()}
      error -> error
    end
  end

  @doc """
  Every repository in the store.

  Walks the key hierarchy one level at a time with delimiter listings, instead
  of listing every object under `repos/`. A flat listing returns every log
  entry, pack and history snapshot of every repository, which grows with the
  corpus's whole history; this grows with the number of repositories and
  account prefixes.

  A repository's own storage prefixes (`wal/`, `packs/`, `history/`) are never
  listed. A repository nested at exactly one of those names, such as
  `acme/app/wal` beside `acme/app`, is still found with a single `stat` of its
  index; one nested further below such a name is not.
  """
  @spec list_repositories() :: {:ok, [repo_id()]} | {:error, term()}
  def list_repositories do
    with {:ok, ids} <- walk_repositories("repos/", []), do: {:ok, Enum.sort(ids)}
  end

  @storage_prefixes ["wal/", "packs/", "history/"]

  defp walk_repositories(prefix, acc) do
    with {:ok, %{keys: keys, prefixes: children}} <- ObjectStore.list_prefixes(prefix) do
      index = prefix <> "index.pb"
      repository? = Enum.any?(keys, &(&1.key == index))
      deleting? = Enum.any?(keys, &(&1.key == prefix <> "deleting"))
      acc = if repository? and not deleting?, do: [repository_id(prefix) | acc], else: acc

      Enum.reduce_while(children, {:ok, acc}, fn child, {:ok, acc} ->
        result =
          if repository? and String.replace_prefix(child, prefix, "") in @storage_prefixes do
            nested_under_storage(child, acc)
          else
            walk_repositories(child, acc)
          end

        case result do
          {:ok, acc} -> {:cont, {:ok, acc}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp nested_under_storage(child, acc) do
    case ObjectStore.stat(child <> "index.pb") do
      {:ok, _} -> {:ok, [repository_id(child) | acc]}
      {:error, :not_found} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repository_id(prefix) do
    prefix |> String.replace_prefix("repos/", "") |> String.trim_trailing("/")
  end

  @spec digest(binary()) :: String.t()
  def digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp put_entry(repo_id, entry) do
    body = Entry.encode(entry)
    key = entry_key(repo_id, digest(body))

    with {:ok, _} <- write_immutable(key, body), do: {:ok, key, byte_size(body), digest(body)}
  end

  # Immutable objects are keyed by their content, so "it is already there"
  # and "we just wrote it" are the same outcome.
  defp write_immutable(key, body) do
    ObjectStore.put(key, body, if_none_match: "*") |> allow_already_present()
  end

  defp stream_immutable(key, path) do
    ObjectStore.put_file(key, path, if_none_match: "*") |> allow_already_present()
  end

  defp allow_already_present({:error, :precondition_failed}), do: {:ok, :already_present}
  defp allow_already_present(other), do: other

  defp backoff(attempt) do
    # Jitter so that a burst of concurrent pushers spreads out instead of
    # colliding on the same retry instant.
    Process.sleep(min(200, trunc(:math.pow(2, attempt))) + :rand.uniform(25))
  end

  defp emit_ambiguous(repo_id, seq, cause) do
    :telemetry.execute([:code, :wal, :ambiguous_commit], %{seq: seq}, %{repo_id: repo_id, cause: cause})
  end

  defp emit_read(outcome, duration, repo_id) do
    :telemetry.execute([:code, :wal, :read], %{duration_us: duration}, %{
      outcome: outcome,
      repo_id: repo_id
    })
  end
end
