defmodule Code.PromExTest do
  @moduledoc """
  The metric names an operator types into a dashboard, an alert or the chart's
  HorizontalPodAutoscaler are the names the exporter actually emits.

  They are taken from a real scrape rather than from the metric definitions,
  because the exporter decides the final spelling: an HPA that names a series
  nobody serves stops scaling entirely, and a doc that names one sends an
  operator looking for something that does not exist.
  """

  use ExUnit.Case, async: true

  alias Code.PromEx.Plugin
  alias PromEx.Storage.Core, as: PromExCore

  @root Path.expand("../..", __DIR__)

  # Every series Code's own plugin exports. Changing this list is changing the
  # observable contract: update docs/operations.md in the same commit.
  @expected ~w(
    code_auth_denied_count
    code_git_aborted_count
    code_git_command_count
    code_git_command_duration
    code_git_requests_in_flight
    code_git_served_bytes
    code_git_served_duration
    code_http_exception_count
    code_http_request_bytes
    code_http_request_count
    code_http_request_duration_seconds
    code_cluster_observed_disk_used_bytes
    code_cluster_observed_resident
    code_cluster_observed_size
    code_factory_operation_count
    code_factory_operation_duration
    code_maintenance_job_count
    code_maintenance_job_duration
    code_mcp_request_count
    code_mcp_request_duration
    code_object_store_request_count
    code_object_store_request_duration_seconds
    code_push_committed_count
    code_push_committed_duration
    code_push_rejected_count
    code_replica_evict_count
    code_replica_sync_duration
    code_replica_sync_entries_behind
    code_replica_sync_packs_downloaded
    code_wal_ambiguous_commit_count
    code_wal_append_attempts
    code_wal_append_batch_size
    code_wal_append_count
    code_wal_cas_retry_count
    code_wal_compact_count
    code_wal_pack_download_bytes
    code_wal_pack_upload_bytes
    code_wal_read_count
    code_wal_read_duration
    code_writer_fallback_count
    code_writer_timeout_count
  )

  setup do
    name = :"code_prom_ex_test_#{System.unique_integer([:positive])}"
    metrics = Enum.flat_map(Plugin.event_metrics([]) ++ Plugin.polling_metrics([]), & &1.metrics)
    start_supervised!(PromExCore.child_spec(name, metrics))
    {:ok, name: name, metrics: metrics}
  end

  defp emit_every_event(metrics) do
    metrics
    |> Enum.map(& &1.event_name)
    |> Enum.uniq()
    |> Enum.each(fn event ->
      measurements = %{
        duration_us: 1_000,
        duration_ms: 1,
        bytes: 10,
        response_bytes: 10,
        attempts: 1,
        size: 1,
        entries_behind: 0,
        packs_downloaded: 0,
        seq: 1,
        epoch: 1,
        packs: 1,
        count: 1,
        resident: 0,
        in_flight: 0,
        disk_used_bytes: 0
      }

      meta = %{
        listener: :public,
        method: :get,
        status: 0,
        operation: :get,
        outcome: :ok,
        reason: :overloaded,
        subcommand: "cat-file",
        service: "git-upload-pack",
        permission: :read,
        kind: :compact,
        mode: :force,
        repo_id: "acme/app"
      }

      :telemetry.execute(event, measurements, meta)
    end)
  end

  defp scraped_names(name) do
    name
    |> PromExCore.scrape()
    |> String.split("\n")
    |> Enum.flat_map(fn
      "# TYPE " <> rest -> [rest |> String.split(" ") |> hd()]
      _ -> []
    end)
    |> Enum.sort()
  end

  test "the exporter emits exactly the documented series", %{name: name, metrics: metrics} do
    emit_every_event(metrics)
    assert scraped_names(name) == Enum.sort(@expected)
  end

  test "git command outcomes are bounded to ok, error and timeout", %{name: name} do
    for status <- [0, 1, 128, :timeout] do
      :telemetry.execute([:code, :git, :command], %{duration_us: 1, bytes: 0}, %{
        subcommand: "repack",
        status: status
      })
    end

    scrape = PromExCore.scrape(name)

    outcomes =
      Regex.scan(~r/code_git_command_count\{[^}]*outcome="([a-z]+)"/, scrape) |> Enum.map(&List.last/1)

    assert Enum.sort(Enum.uniq(outcomes)) == ["error", "ok", "timeout"]
  end

  test "every Code metric named in the docs and the chart is one the exporter emits" do
    files =
      ~w(docs/operations.md docs/multi-tenancy.md docs/kubernetes.md content/operations.md
         lib/code/prom_ex.ex lib/code/prom_ex/plugin.ex) ++
        Path.wildcard(Path.join(@root, "charts/code/templates/*.yaml"))

    emitted = MapSet.new(@expected)

    for file <- files do
      path = if Path.type(file) == :absolute, do: file, else: Path.join(@root, file)
      body = File.read!(path)

      for [metric] <- Regex.scan(~r/\bcode_[a-z_]+[a-z]\b/, body),
          prometheus_series?(metric),
          not MapSet.member?(emitted, metric) do
        flunk("#{Path.relative_to(path, @root)} names #{metric}, which the exporter does not emit")
      end
    end
  end

  # Documentation also contains unrelated identifiers that start with `code_`,
  # such as the `code_grants` token claim and the plugin's metric group names.
  # Series are the names with one of the exporter's group prefixes.
  defp prometheus_series?(name) do
    String.starts_with?(name, ~w(
      code_auth_ code_cluster_ code_factory_ code_git_ code_http_ code_maintenance_ code_mcp_
      code_object_store_ code_push_ code_replica_ code_wal_ code_writer_
    )) and not String.ends_with?(name, ["_event_metrics", "_polling_metrics"])
  end
end
