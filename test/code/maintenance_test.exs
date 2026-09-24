defmodule Code.MaintenanceTest do
  use Code.Case, async: true

  alias Code.Config
  alias Code.Maintenance
  alias Code.MCP.Tools

  test "normalizes node capability roles" do
    Config.put_overrides(Map.put(Config.overrides(), :roles, "serve, events,serve"))

    assert Config.roles() == [:serve, :events]
    assert Config.serve?()
    refute Config.maintain?()
    assert Config.events?()
  end

  test "rejects unknown maintenance job kinds" do
    assert {:error, {:unknown_maintenance_kind, :unknown}} = Maintenance.run("acme/app", :unknown)
  end

  test "scheduler runs an eligible cache-only job locally when membership is unavailable", %{repo: repo} do
    start_replica_runtime()
    assert {:ok, _} = Code.Control.create_repository(repo)
    scheduler = start_maintenance_scheduler()

    assert :not_due = Maintenance.run(repo, :lookup, mode: :if_due, scheduler: scheduler)
  end

  test "a forced lookup rebuild bypasses the pack-count threshold", %{repo: repo} do
    start_replica_runtime()
    assert {:ok, _} = Code.Control.create_repository(repo)

    principal = %Code.Auth.Principal{
      subject: "test",
      grants: [Code.Auth.Principal.grant("**", [:admin])]
    }

    assert {:ok, _} =
             Tools.call(
               "commit",
               %{
                 "repository" => repo,
                 "branch" => "main",
                 "message" => "lookup fixture",
                 "changes" => [%{"path" => "README.md", "content" => "lookup\n"}]
               },
               principal
             )

    scheduler = start_maintenance_scheduler()

    assert {:ok, %{packs: packs}} = Maintenance.run(repo, :lookup, scheduler: scheduler)
    assert packs >= 1
  end

  test "scheduler compacts from an exact write-ahead-log snapshot", %{repo: repo} do
    start_replica_runtime()
    assert {:ok, _} = Code.Control.create_repository(repo)

    principal = %Code.Auth.Principal{
      subject: "test",
      grants: [Code.Auth.Principal.grant("**", [:admin])]
    }

    assert {:ok, _} =
             Tools.call(
               "commit",
               %{
                 "repository" => repo,
                 "branch" => "main",
                 "message" => "maintenance fixture",
                 "changes" => [%{"path" => "README.md", "content" => "maintenance\n"}]
               },
               principal
             )

    scheduler = start_maintenance_scheduler()

    assert {:ok, %{epoch: 2, seq: 1}} = Maintenance.run(repo, :compact, scheduler: scheduler)
  end

  describe "observability" do
    setup %{repo: repo} do
      handler = {__MODULE__, :maintenance_job, self()}
      parent = self()

      :ok =
        :telemetry.attach(
          handler,
          [:code, :maintenance, :job],
          fn _event, measurements, meta, _config ->
            # Other tests run maintenance concurrently; only this repository's
            # jobs are this test's.
            if meta.repo_id == repo, do: send(parent, {:maintenance_job, measurements, meta})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "every job reports a bounded outcome and its latency", %{repo: repo} do
      start_replica_runtime()
      assert {:ok, _} = Code.Control.create_repository(repo)
      scheduler = start_maintenance_scheduler()

      assert :not_due = Maintenance.run(repo, :lookup, mode: :if_due, scheduler: scheduler)

      assert_receive {:maintenance_job, %{duration_us: duration}, meta}
      assert is_integer(duration) and duration >= 0
      assert %{kind: :lookup, mode: :if_due, outcome: :not_due} = meta
    end

    test "a failing job is counted even though nobody asked for its result", %{repo: repo} do
      # Never created, so the job fails. A sweep-scheduled job has no waiter,
      # which is why the job itself must report this.
      Maintenance.observe(repo, :compact, :if_due, {:error, :not_found}, 5)

      assert_receive {:maintenance_job, %{duration_us: 5}, %{kind: :compact, outcome: :error}}
    end

    test "a crash is reported with its own outcome", %{repo: repo} do
      Maintenance.observe(repo, :compact, :if_due, {:crashed, :killed}, 5)

      assert_receive {:maintenance_job, _measurements, %{outcome: :crashed}}
    end
  end

  defp start_maintenance_scheduler do
    overrides = Map.put(Config.overrides(), :roles, [:maintain])
    Config.put_overrides(overrides)

    name =
      {:via, Registry, {Maintenance.registry(), {:maintenance_test, :erlang.unique_integer([:positive])}}}

    start_supervised!({Maintenance, name: name, interval: :timer.hours(1), overrides: overrides})
    name
  end
end
