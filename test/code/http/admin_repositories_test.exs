defmodule Code.HTTP.AdminRepositoriesTest do
  @moduledoc """
  The admin API's repository creation and replica-count routes validate the
  count they are given instead of forwarding untyped JSON into the index.
  """

  use Code.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Code.Config
  alias Code.HTTP.AdminRouter
  alias Code.WAL

  setup do
    Config.put_overrides(Map.put(Config.overrides(), :admin_token, "admin-secret"))
    :ok
  end

  test "creates a repository with a valid count, or the default when none is sent", context do
    assert request(:post, "/repositories", %{repository: repo(context, "five"), replicas: 5}).status == 201
    assert {:ok, %{replicas: 5}, _} = WAL.fetch(repo(context, "five"))

    assert request(:post, "/repositories", %{repository: repo(context, "default")}).status == 201
    assert {:ok, %{replicas: 3}, _} = WAL.fetch(repo(context, "default"))
  end

  test "refuses an invalid count on creation with a 422", %{repo: repo} do
    for count <- [0, -1, "3", 2.5, 10_000] do
      response = request(:post, "/repositories", %{repository: repo, replicas: count})

      assert response.status == 422, inspect(count)
      assert %{"error" => "replicas must be an integer between 1 and 256"} = JSON.decode!(response.resp_body)
    end

    assert {:error, :not_found} = WAL.fetch(repo)
  end

  test "changes the count, and refuses an invalid or missing target", %{repo: repo} do
    assert request(:post, "/repositories", %{repository: repo}).status == 201

    assert %{status: 200} = response = request(:put, "/replicas/#{repo}", %{replicas: 2})
    assert %{"replicas" => 2} = JSON.decode!(response.resp_body)

    assert request(:put, "/replicas/#{repo}", %{replicas: "2"}).status == 422
    assert request(:put, "/replicas/#{repo}", %{replicas: 0}).status == 422
    assert request(:put, "/replicas/#{repo}-missing", %{replicas: 2}).status == 404
    assert {:ok, %{replicas: 2}, _} = WAL.fetch(repo)
  end

  test "deletes a repository, and answers 404 for a missing, invalid or parent id", %{repo: repo} do
    assert request(:post, "/repositories", %{repository: repo}).status == 201
    [account, _] = String.split(repo, "/", parts: 2)

    # The account prefix is not a repository; deleting it must not reach the
    # repository underneath.
    assert request(:delete, "/repositories/#{account}", %{}).status == 404
    assert {:ok, _, _} = WAL.fetch(repo)

    assert request(:delete, "/repositories/#{repo}", %{}).status == 204
    assert {:error, :not_found} = WAL.fetch(repo)
    assert request(:delete, "/repositories/#{repo}", %{}).status == 404
    assert request(:delete, "/repositories/#{account}/..", %{}).status == 404
  end

  defp request(method, path, payload) do
    method
    |> conn(path, JSON.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer admin-secret")
    |> AdminRouter.call(AdminRouter.init([]))
  end
end
