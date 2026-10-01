defmodule Code.HTTP.AdminRecoveryTest do
  use Code.Case, async: true
  use Mimic

  setup :set_mimic_private

  import Plug.Conn
  import Plug.Test

  alias Code.Config
  alias Code.HTTP.AdminRouter
  alias Code.ObjectStore
  alias Code.WAL
  alias Code.WAL.Index

  setup do
    Config.put_overrides(
      Map.merge(Config.overrides(), %{admin_token: "admin-secret", recovery_enabled: true})
    )

    :ok
  end

  test "only the admin credential can list or restore recovery points", %{repo: repo} do
    {:ok, _} = WAL.create(repo)

    for path <- ["/recovery-points/#{repo}", "/restore/#{repo}"] do
      response = conn(:get, path) |> AdminRouter.call(AdminRouter.init([]))
      assert response.status == 401
    end

    assert request(:post, "/restore/#{repo}", %{repository: repo <> "-copy", point: "x"}, "wrong").status ==
             401

    assert request(:delete, "/restore/#{repo}", nil, "wrong").status == 401
  end

  test "lists points, restores a new repository and refuses to overwrite it", context do
    {:ok, _} = WAL.create(context.repo, default_branch: "refs/heads/trunk")
    response = request(:get, "/recovery-points/#{context.repo}")
    assert response.status == 200
    assert %{"points" => [%{"id" => point}]} = JSON.decode!(response.resp_body)
    target = repo(context, "copy")
    payload = %{repository: target, point: point}
    response = request(:post, "/restore/#{context.repo}", payload)
    assert response.status == 202
    assert %{"id" => id, "state" => "queued"} = JSON.decode!(response.resp_body)
    assert {:ok, job} = Code.Recovery.Jobs.claim(id)
    assert {:ok, _} = Code.Recovery.Jobs.run(job)

    assert %{"repository" => ^target, "state" => "queued"} =
             JSON.decode!(response.resp_body)

    assert {:ok, _, _} = WAL.fetch(target)
    assert request(:post, "/restore/#{context.repo}", payload).status == 409
    assert request(:delete, "/restore/#{target}").status == 409
    assert {:ok, _, _} = WAL.fetch(target)
  end

  test "discards only an unfinished reservation", context do
    target = repo(context, "pending")
    index = Index.new(target)
    pending = %{Index.tombstone(index, "test") | recovering: true}
    {:ok, _} = ObjectStore.put(WAL.index_key(target), Index.encode(pending))
    {:ok, _} = ObjectStore.put(WAL.deleting_key(target), Index.encode(pending))
    assert request(:post, "/repositories", %{repository: target}).status == 409
    assert request(:delete, "/repositories/#{target}").status == 409
    status = request(:get, "/restore/#{target}")
    assert status.status == 200
    assert %{"state" => "recovering", "started_at_ms" => at} = JSON.decode!(status.resp_body)
    assert at > 0
    assert {:ok, ids} = WAL.list_repositories()
    refute target in ids
    response = request(:delete, "/restore/#{target}")
    assert response.status == 200
    assert %{"discarded" => ^target} = JSON.decode!(response.resp_body)
    assert {:error, :not_found} = ObjectStore.get(WAL.index_key(target))
  end

  test "returns stable errors for invalid input, absent sources and stale points", context do
    assert request(:get, "/recovery-points/#{context.repo}").status == 404
    {:ok, _} = WAL.create(context.repo)
    target = repo(context, "copy")

    for payload <- [%{}, %{repository: "../escape", point: "x"}, %{repository: target, point: "latest"}] do
      assert request(:post, "/restore/#{context.repo}", payload).status == 422
    end

    response =
      request(:post, "/restore/#{context.repo}", %{repository: target, point: String.duplicate("a", 64)})

    assert response.status == 404
    assert %{"error" => "recovery_point_not_found"} = JSON.decode!(response.resp_body)
    assert {:error, :not_found} = WAL.fetch(target)
  end

  test "corrupt indexes are reported as invalid history rather than a storage outage", %{repo: repo} do
    {:ok, _} = ObjectStore.put(WAL.index_key(repo), "corrupt")
    response = request(:get, "/recovery-points/#{repo}")
    assert response.status == 500
    assert %{"error" => "recovery_history_invalid"} = JSON.decode!(response.resp_body)
  end

  test "ordinary deletion reports unsupported conditional storage without deleting the repository", %{
    repo: repo
  } do
    {:ok, index} = WAL.create(repo)
    stub(ObjectStore, :verify_conditional_deletes, fn -> {:error, :conditional_delete_unsupported} end)
    response = request(:delete, "/repositories/#{repo}")
    assert response.status == 503
    assert %{"error" => "conditional_delete_unsupported"} = JSON.decode!(response.resp_body)
    assert {:ok, ^index, _} = WAL.fetch(repo)
  end

  test "ordinary deletion reports a cleanup version conflict", %{repo: repo} do
    {:ok, _} = WAL.create(repo)

    stub(ObjectStore, :delete_if_match, fn key, version ->
      if key == WAL.index_key(repo),
        do: {:error, :precondition_failed},
        else: Mimic.call_original(ObjectStore, :delete_if_match, [key, version])
    end)

    response = request(:delete, "/repositories/#{repo}")
    assert response.status == 409
    assert %{"error" => "repository_changed_concurrently"} = JSON.decode!(response.resp_body)
  end

  test "job control routes require admin authentication and persist cancellation", context do
    {:ok, _} = WAL.create(context.repo)
    {:ok, %{points: [point]}} = Code.Recovery.points(context.repo)
    target = repo(context, "job-control")
    id = String.duplicate("b", 32)
    response = request(:post, "/restore/#{context.repo}", %{repository: target, point: point.id, id: id})
    assert response.status == 202

    for {method, suffix} <- [{:get, ""}, {:post, "/cancel"}, {:post, "/retry"}] do
      assert request(method, "/recovery-jobs/#{id}#{suffix}", %{}, "invalid").status == 401
    end

    assert request(:get, "/recovery-jobs/#{id}").status == 200
    assert request(:post, "/recovery-jobs/#{id}/cancel").status == 200
    assert %{"state" => "cancelled"} = JSON.decode!(request(:get, "/recovery-jobs/#{id}").resp_body)
    assert request(:post, "/recovery-jobs/#{id}/retry").status == 202
  end

  defp request(method, path, payload \\ %{}, token \\ "admin-secret") do
    method
    |> conn(path, JSON.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> AdminRouter.call(AdminRouter.init([]))
  end
end
