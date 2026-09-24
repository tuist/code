defmodule Code.PromEx.Plugin do
  @moduledoc """
  Code's own metrics.

  Grouped by the question each one answers:

  **Is the cluster healthy?** `code_wal_read_duration` (seconds) bucketed by
  outcome. A healthy node's reads are overwhelmingly `not_modified`, because
  that is a metadata-only round trip against object storage. If `modified`
  starts dominating, replicas are doing catch-up work on the read path.

  **Is there write contention?** Read `code_wal_append_batch_size` first: it
  is how many pushes each compare-and-swap absorbed, so rising with load is
  group commit doing its job. `code_wal_cas_retry_count` is the contention
  that got past it — a few are normal, but many mean pushes are arriving at
  several nodes at once and the preferred-writer routing is not taking effect.

  **How far behind is this node?** `code_replica_sync_entries_behind` on each
  sync. Persistent non-zero values mean hints are not arriving, or object
  storage is slow.

  **Should we scale?** `code_git_requests_in_flight` is the honest measure
  of a Git server's load: a clone occupies a connection and a process for its
  entire duration, so concurrency saturates long before CPU does. It counts
  only Git smart-HTTP requests on the public listener; see
  `Code.Telemetry.InFlight`.

  **Is maintenance working?** `code_maintenance_job_count{kind,outcome}`
  counts every job, including the unattended ones a sweep schedules, so a
  compaction that keeps failing shows up without anyone having asked for it.
  """

  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    [
      http_metrics(),
      object_store_metrics(),
      wal_metrics(),
      replica_metrics(),
      push_metrics(),
      maintenance_metrics(),
      git_metrics(),
      mcp_metrics(),
      factory_metrics(),
      auth_metrics()
    ]
  end

  defp http_metrics do
    Event.build(:code_http_event_metrics, [
      distribution(
        [:code, :http, :request, :duration_seconds],
        event_name: [:code, :http, :request],
        measurement: :duration_us,
        description: "End-to-end HTTP request duration, by listener, method and response status class.",
        unit: {:microsecond, :second},
        tags: [:listener, :method, :status],
        reporter_options: [buckets: [0.001, 0.005, 0.025, 0.1, 0.5, 1, 5, 30, 300, 1800]]
      ),
      counter(
        [:code, :http, :request, :count],
        event_name: [:code, :http, :request],
        description: "Completed HTTP requests.",
        tags: [:listener, :method, :status]
      ),
      sum(
        [:code, :http, :request, :bytes],
        event_name: [:code, :http, :request],
        measurement: :response_bytes,
        unit: :byte,
        description: "Bytes sent in HTTP responses.",
        tags: [:listener]
      ),
      counter(
        [:code, :http, :exception, :count],
        event_name: [:code, :http, :exception],
        description: "Unhandled HTTP request exceptions.",
        tags: [:listener]
      )
    ])
  end

  defp object_store_metrics do
    Event.build(:code_object_store_event_metrics, [
      distribution(
        [:code, :object_store, :request, :duration_seconds],
        event_name: [:code, :object_store, :request],
        measurement: :duration_us,
        description: "Object-store request duration. The object store is the source of truth.",
        unit: {:microsecond, :second},
        tags: [:operation, :outcome],
        reporter_options: [buckets: [0.001, 0.005, 0.025, 0.1, 0.5, 1, 5, 30, 300]]
      ),
      counter(
        [:code, :object_store, :request, :count],
        event_name: [:code, :object_store, :request],
        description: "Object-store requests, by operation and bounded outcome.",
        tags: [:operation, :outcome]
      )
    ])
  end

  defp wal_metrics do
    Event.build(:code_wal_event_metrics, [
      distribution(
        [:code, :wal, :read, :duration],
        event_name: [:code, :wal, :read],
        measurement: :duration_us,
        description: "Time to validate a replica's cached view of the log; not_modified is the fast path.",
        unit: {:microsecond, :second},
        tags: [:outcome],
        reporter_options: [buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]]
      ),
      counter(
        [:code, :wal, :read, :count],
        event_name: [:code, :wal, :read],
        description: "Write-ahead log index reads.",
        tags: [:outcome]
      ),
      counter(
        [:code, :wal, :append, :count],
        event_name: [:code, :wal, :append],
        description: "Entries appended to the log."
      ),
      distribution(
        [:code, :wal, :append, :attempts],
        event_name: [:code, :wal, :append],
        measurement: :attempts,
        description: "Compare-and-swap attempts needed to commit an entry.",
        reporter_options: [buckets: [1, 2, 3, 5, 8, 12]]
      ),
      distribution(
        [:code, :wal, :append_batch, :size],
        event_name: [:code, :wal, :append_batch],
        measurement: :size,
        description:
          "Entries committed per compare-and-swap. This is group commit working: " <>
            "rising with load is the system absorbing contention rather than retrying through it.",
        reporter_options: [buckets: [1, 2, 4, 8, 16, 32, 64]]
      ),
      counter(
        [:code, :wal, :cas_retry, :count],
        event_name: [:code, :wal, :cas_retry],
        description: "Pushes that lost a compare-and-swap and retried against newer state."
      ),
      counter(
        [:code, :wal, :ambiguous_commit, :count],
        event_name: [:code, :wal, :ambiguous_commit],
        description:
          "Lost compare-and-swaps that turned out to be this node's own write, whose reply was lost. " <>
            "Harmless, since the entry is durable, but a rising rate means the store is dropping replies."
      ),
      counter(
        [:code, :wal, :compact, :count],
        event_name: [:code, :wal, :compact],
        description: "Compactions performed by this node."
      ),
      sum(
        [:code, :wal, :pack_upload, :bytes],
        event_name: [:code, :wal, :pack_upload],
        measurement: :bytes,
        unit: :byte,
        description: "Packfile bytes streamed into the log. Object-store egress starts here."
      ),
      sum(
        [:code, :wal, :pack_download, :bytes],
        event_name: [:code, :wal, :pack_download],
        measurement: :bytes,
        unit: :byte,
        description:
          "Packfile bytes streamed out of the log to warm a replica. Sustained growth " <>
            "means caches are being rebuilt more often than they are being used."
      )
    ])
  end

  defp replica_metrics do
    Event.build(:code_replica_event_metrics, [
      distribution(
        [:code, :replica, :sync, :duration],
        event_name: [:code, :replica, :sync],
        measurement: :duration_ms,
        description: "Time to bring a replica into agreement with the log.",
        unit: {:millisecond, :second},
        reporter_options: [buckets: [0.005, 0.025, 0.1, 0.5, 1, 5, 15, 60, 300]]
      ),
      distribution(
        [:code, :replica, :sync, :entries_behind],
        event_name: [:code, :replica, :sync],
        measurement: :entries_behind,
        description: "How many log entries a replica was behind when it synced.",
        reporter_options: [buckets: [0, 1, 5, 25, 100, 500, 2500]]
      ),
      sum(
        [:code, :replica, :sync, :packs_downloaded],
        event_name: [:code, :replica, :sync],
        measurement: :packs_downloaded,
        description: "Packfiles downloaded from object storage."
      ),
      counter(
        [:code, :replica, :evict, :count],
        event_name: [:code, :replica, :evict],
        description: "Repositories evicted from local disk."
      ),
      counter(
        [:code, :replica, :evict_deferred, :count],
        event_name: [:code, :replica, :evict_deferred],
        description: "Evictions postponed because a clone or push still held the repository."
      ),
      counter(
        [:code, :replica, :rematerialize, :count],
        event_name: [:code, :replica, :rematerialize],
        description: "Replicas rebuilt from the log because their local copy had gone missing."
      ),
      sum(
        [:code, :replica, :prune, :packs],
        event_name: [:code, :replica, :prune],
        measurement: :packs,
        description: "Superseded packfiles removed from local disk."
      ),
      sum(
        [:code, :replica, :prune_deferred, :packs],
        event_name: [:code, :replica, :prune_deferred],
        measurement: :packs,
        description: "Superseded packfiles kept because the repository was in use."
      ),
      counter(
        [:code, :git, :pack_index, :count],
        event_name: [:code, :git, :pack_index],
        description: "Pack indexes installed, by whether the downloaded index was reused or rebuilt.",
        tags: [:outcome]
      )
    ])
  end

  defp push_metrics do
    Event.build(:code_push_event_metrics, [
      distribution(
        [:code, :push, :committed, :duration],
        event_name: [:code, :push, :committed],
        measurement: :duration_ms,
        description: "Time from receiving a push to it being durable in the log.",
        unit: {:millisecond, :second},
        reporter_options: [buckets: [0.01, 0.05, 0.1, 0.5, 1, 5, 15, 60]]
      ),
      counter(
        [:code, :push, :committed, :count],
        event_name: [:code, :push, :committed],
        description: "Pushes committed to the log."
      ),
      counter(
        [:code, :push, :rejected, :count],
        event_name: [:code, :push, :rejected],
        description: "Pushes rejected, by reason.",
        tags: [:reason]
      ),
      distribution(
        [:code, :push, :closure_check, :duration],
        event_name: [:code, :push, :closure_check],
        measurement: :duration_us,
        description: "Time spent proving a push carries every object its new refs need.",
        unit: {:microsecond, :second},
        tags: [:outcome],
        reporter_options: [buckets: [0.005, 0.025, 0.1, 0.5, 1, 5, 30]]
      ),
      counter(
        [:code, :push, :local_apply_failed, :count],
        event_name: [:code, :push, :local_apply_failed],
        description:
          "Committed pushes this node could not apply to its local cache; the next sync repairs it."
      ),
      counter(
        [:code, :writer, :fallback, :count],
        event_name: [:code, :writer, :fallback],
        description:
          "Pushes committed locally because the preferred writer was unreachable. " <>
            "Expected during a rolling deploy; sustained outside one, routing is not taking effect.",
        tags: [:reason]
      ),
      counter(
        [:code, :writer, :timeout, :count],
        event_name: [:code, :writer, :timeout],
        description: "Pushes that gave up waiting for the repository writer; their entries may still commit."
      )
    ])
  end

  defp maintenance_metrics do
    Event.build(:code_maintenance_event_metrics, [
      distribution(
        [:code, :maintenance, :job, :duration],
        event_name: [:code, :maintenance, :job],
        measurement: :duration_us,
        description: "Duration of maintenance jobs, by kind and outcome (ok, not_due, error, crashed).",
        unit: {:microsecond, :second},
        tags: [:kind, :outcome],
        reporter_options: [buckets: [0.01, 0.1, 1, 5, 30, 120, 600, 3600]]
      ),
      counter(
        [:code, :maintenance, :job, :count],
        event_name: [:code, :maintenance, :job],
        description: "Maintenance jobs finished, by kind and outcome, including unattended ones.",
        tags: [:kind, :outcome]
      )
    ])
  end

  @doc false
  def git_command_tags(%{subcommand: subcommand} = meta) do
    %{subcommand: subcommand, outcome: git_outcome(Map.get(meta, :status))}
  end

  defp git_outcome(0), do: :ok
  defp git_outcome(:timeout), do: :timeout
  defp git_outcome(_status), do: :error

  defp git_metrics do
    Event.build(:code_git_event_metrics, [
      distribution(
        [:code, :git, :command, :duration],
        event_name: [:code, :git, :command],
        measurement: :duration_us,
        description: "Duration of git plumbing invocations, by subcommand and outcome (ok, error, timeout).",
        unit: {:microsecond, :second},
        tags: [:subcommand, :outcome],
        tag_values: &git_command_tags/1,
        reporter_options: [buckets: [0.001, 0.01, 0.05, 0.25, 1, 5, 30, 300]]
      ),
      counter(
        [:code, :git, :command, :count],
        event_name: [:code, :git, :command],
        description: "Git plumbing invocations, by subcommand and outcome (ok, error, timeout).",
        tags: [:subcommand, :outcome],
        tag_values: &git_command_tags/1
      ),
      distribution(
        [:code, :git, :served, :duration],
        event_name: [:code, :git, :served],
        measurement: :duration_ms,
        description: "Duration of a served Git protocol request.",
        unit: {:millisecond, :second},
        tags: [:service],
        reporter_options: [buckets: [0.01, 0.1, 1, 5, 30, 120, 600]]
      ),
      sum(
        [:code, :git, :served, :bytes],
        event_name: [:code, :git, :served],
        measurement: :bytes,
        description: "Bytes served over the Git protocol.",
        tags: [:service]
      ),
      counter(
        [:code, :git, :aborted, :count],
        event_name: [:code, :git, :aborted],
        description: "Git streams that ended before completing.",
        tags: [:service]
      )
    ])
  end

  defp mcp_metrics do
    Event.build(:code_mcp_event_metrics, [
      distribution(
        [:code, :mcp, :request, :duration],
        event_name: [:code, :mcp, :request],
        measurement: :duration_us,
        description: "Duration of an MCP request, by method.",
        unit: {:microsecond, :second},
        tags: [:method],
        reporter_options: [buckets: [0.001, 0.01, 0.05, 0.25, 1, 5, 30]]
      ),
      counter(
        [:code, :mcp, :request, :count],
        event_name: [:code, :mcp, :request],
        description: "MCP requests handled.",
        tags: [:method, :outcome]
      )
    ])
  end

  defp factory_metrics do
    Event.build(:code_factory_event_metrics, [
      distribution(
        [:code, :factory, :operation, :duration],
        event_name: [:code, :factory, :operation],
        measurement: :duration_us,
        description:
          "Duration of durable graph-run and account-configuration operations, by bounded operation and outcome.",
        unit: {:microsecond, :second},
        tags: [:operation, :outcome],
        reporter_options: [buckets: [0.001, 0.005, 0.025, 0.1, 0.5, 1, 5, 30]]
      ),
      counter(
        [:code, :factory, :operation, :count],
        event_name: [:code, :factory, :operation],
        description:
          "Durable graph-run and account-configuration operations, by bounded operation and outcome.",
        tags: [:operation, :outcome]
      )
    ])
  end

  defp auth_metrics do
    Event.build(:code_auth_event_metrics, [
      counter(
        [:code, :auth, :denied, :count],
        event_name: [:code, :auth, :denied],
        description: "Authorization denials, by permission.",
        tags: [:permission]
      ),
      counter(
        [:code, :auth, :rejected, :count],
        event_name: [:code, :auth, :rejected],
        description:
          "Credentials that failed authentication, by bounded reason. Anonymous requests are not counted.",
        tags: [:reason]
      ),
      counter(
        [:code, :policy, :revalidation_failed, :count],
        event_name: [:code, :policy, :revalidation_failed],
        description:
          "Policy revalidations that could not reach object storage, by outcome: served_stale or failed_closed.",
        tags: [:outcome]
      )
    ])
  end

  @impl true
  def polling_metrics(opts) do
    interval = Keyword.get(opts, :poll_rate, 10_000)

    [
      Polling.build(
        :code_cluster_polling_metrics,
        interval,
        {__MODULE__, :observe, []},
        [
          last_value(
            [:code, :cluster, :observed, :size],
            event_name: [:code, :cluster, :observed],
            measurement: :size,
            description: "Nodes currently in the cluster."
          ),
          last_value(
            [:code, :cluster, :observed, :resident],
            event_name: [:code, :cluster, :observed],
            measurement: :resident,
            description: "Repositories materialized on this node."
          ),
          # Named for what it measures rather than for the poll that reads it:
          # this is the series the chart's HorizontalPodAutoscaler asks for.
          last_value(
            [:code, :git, :requests_in_flight],
            event_name: [:code, :cluster, :observed],
            measurement: :in_flight,
            description:
              "Git protocol requests currently being served. The right signal to autoscale on: " <>
                "a clone holds a connection for its whole duration, so concurrency saturates before CPU."
          ),
          last_value(
            [:code, :cluster, :observed, :disk_used_bytes],
            event_name: [:code, :cluster, :observed],
            measurement: :disk_used_bytes,
            description:
              "Bytes the local repository cache is occupying. Measured in the background at most every " <>
                "five minutes, so it can lag by that much."
          )
        ]
      )
    ]
  end

  @doc false
  def observe do
    :telemetry.execute(
      [:code, :cluster, :observed],
      %{
        size: length(Code.Cluster.members()),
        resident: length(Code.Replica.resident()),
        in_flight: in_flight(),
        disk_used_bytes: Code.Telemetry.DiskUsage.bytes()
      },
      %{}
    )
  end

  defp in_flight, do: Code.Telemetry.InFlight.count()
end
