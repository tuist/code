defmodule Code.HTTP.ServiceErrorsTest do
  @moduledoc """
  The forge service routes map a failure to a status by its kind, not by the
  words in its message: a conflict with durable state is `409`, a temporary
  failure is `503` with `Retry-After`, a missing object is `404` and a
  malformed request is `422`.
  """

  use Code.Case, async: true
  use Mimic

  import Plug.Conn
  import Plug.Test

  alias Code.Config
  alias Code.Control
  alias Code.HTTP.Router
  alias Code.ObjectStore
  alias Code.WAL
  alias Code.WAL.Entry

  # Private mode: the only stub here is sustained compare-and-swap contention,
  # which a real store cannot be made to produce on demand, and it runs in the
  # test process that calls the router.
  setup :set_mimic_private

  setup %{repo: repo, namespace: namespace} do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(repo)
    base_commit = String.duplicate("a", 40)

    assert {:ok, _} =
             WAL.append(repo, fn _ ->
               {:ok,
                Entry.new(
                  type: :ENTRY_TYPE_PUSH,
                  commands: [Entry.command("refs/heads/main", Entry.zero_oid(), base_commit)]
                )}
             end)

    Config.put_overrides(
      Map.put(
        Config.overrides(),
        :auth,
        {Code.Auth.Static,
         tokens: %{
           "writer" => %{account: namespace, scopes: [:read, :write, :execute]},
           "admin" => %{account: namespace, scopes: [:admin]}
         }}
      )
    )

    {:ok, base_commit: base_commit}
  end

  test "a request that conflicts with a terminal run is 409", %{repo: repo, base_commit: base_commit} do
    run_id = create_run(repo, base_commit)
    assert request(:post, "/api/work-runs/#{run_id}/cancel?repository=#{repo}", %{}, "admin").status == 200

    response =
      request(:post, "/api/work-runs/#{run_id}/claim?repository=#{repo}", %{executor: "pod"}, "writer")

    assert response.status == 409
    assert %{"error" => "code: work run is cancelled"} = JSON.decode!(response.resp_body)
    assert get_resp_header(response, "retry-after") == []
  end

  test "a missing run is 404 and a malformed request is 422", %{repo: repo} do
    assert request(:get, "/api/work-runs/rmissing?repository=#{repo}", nil, "writer").status == 404
    assert request(:post, "/api/work-runs?repository=#{repo}", %{graph: %{}}, "writer").status == 422
  end

  test "sustained contention on a run is a retryable 503", %{repo: repo, base_commit: base_commit} do
    run_id = create_run(repo, base_commit)

    stub(ObjectStore, :put, fn key, body, opts ->
      if String.ends_with?(key, "/state.json") and Keyword.has_key?(opts, :if_match) do
        {:error, :precondition_failed}
      else
        Mimic.call_original(ObjectStore, :put, [key, body, opts])
      end
    end)

    response =
      request(:post, "/api/work-runs/#{run_id}/claim?repository=#{repo}", %{executor: "pod"}, "writer")

    assert response.status == 503
    assert get_resp_header(response, "retry-after") == ["1"]
    assert %{"error" => "code: work run changed concurrently; retry later"} = JSON.decode!(response.resp_body)
  end

  test "replacing account configuration from a stale version is 409", %{repo: repo} do
    path = "/api/secret-backends/production?repository=#{repo}"
    first = request(:put, path, %{driver: "managed_infisical", project: "acme-one"}, "admin")
    assert first.status == 200
    assert %{"version" => version} = JSON.decode!(first.resp_body)

    assert request(
             :put,
             path,
             %{driver: "managed_infisical", project: "acme-two", previous_version: version},
             "admin"
           ).status ==
             200

    stale =
      request(
        :put,
        path,
        %{driver: "managed_infisical", project: "acme-three", previous_version: version},
        "admin"
      )

    assert stale.status == 409
    assert %{"error" => "code: secret backend changed concurrently"} = JSON.decode!(stale.resp_body)
  end

  test "a comment on a missing issue is 404, whatever its message says", context do
    # A repository of its own: the run fixtures above point `main` at a commit
    # that exists only in the log, which a replica cannot materialize.
    repo = repo(context, "issues")
    {:ok, _} = Control.create_repository(repo)

    response = request(:post, "/api/issues/7/comments?repository=#{repo}", %{body: "hello"}, "writer")
    assert response.status == 404
  end

  defp create_run(repo, base_commit) do
    created =
      request(
        :post,
        "/api/work-runs?repository=#{repo}",
        %{graph: %{"nodes" => [%{"id" => "work", "title" => "Work"}]}, base_commit: base_commit},
        "writer"
      )

    assert created.status == 201
    JSON.decode!(created.resp_body)["id"]
  end

  defp request(method, path, payload, token) do
    conn = conn(method, path, if(payload, do: JSON.encode!(payload), else: ""))
    conn = if payload, do: put_req_header(conn, "content-type", "application/json"), else: conn
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, Router.init([]))
  end
end
