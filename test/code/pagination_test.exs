defmodule Code.PaginationTest do
  @moduledoc """
  Cursor pagination for work runs, work-run events and issues. Without
  options every list keeps returning everything; with them a page is bounded
  in what it returns and in what it reads.
  """

  use Code.Case, async: true
  use Mimic

  import Plug.Conn
  import Plug.Test

  alias Code.Auth.Principal
  alias Code.Config
  alias Code.Control
  alias Code.Factory
  alias Code.HTTP.Router
  alias Code.Issues
  alias Code.ObjectStore
  alias Code.ServiceError
  alias Code.WAL
  alias Code.WAL.Entry

  # Private mode: the one stub below only counts this test process's reads.
  setup :set_mimic_private

  setup %{namespace: namespace} do
    principal = %Principal{
      subject: "pager",
      account: namespace,
      grants: [Principal.grant("#{namespace}/**", [:read, :write, :execute, :admin])],
      source: :test
    }

    {:ok, principal: principal}
  end

  describe "work runs" do
    setup %{repo: repo} do
      assert {:ok, _} = WAL.create(repo)

      assert {:ok, _} =
               WAL.append(repo, fn _ ->
                 {:ok,
                  Entry.new(
                    type: :ENTRY_TYPE_PUSH,
                    commands: [Entry.command("refs/heads/main", Entry.zero_oid(), base_commit())]
                  )}
               end)

      :ok
    end

    test "pages newest first and visits every run exactly once", %{repo: repo, principal: principal} do
      created =
        for _ <- 1..5 do
          assert {:ok, run} = Factory.create(repo, one_node_graph(), %{base_commit: base_commit()}, principal)
          # Distinct creation milliseconds make newest-first unambiguous.
          Process.sleep(2)
          run.id
        end

      assert {:ok, %{runs: all, next_cursor: nil, count: 5}} = Factory.list(repo)
      assert Enum.map(all, & &1.id) == Enum.reverse(created)

      pages = collect_pages(fn cursor -> Factory.list(repo, limit: 2, cursor: cursor) end)
      assert Enum.map(pages, &length/1) == [2, 2, 1]
      assert pages |> List.flatten() |> Enum.map(& &1.id) == Enum.reverse(created)
    end

    test "a page reads only its own runs", %{repo: repo, principal: principal} do
      for _ <- 1..6 do
        assert {:ok, _} = Factory.create(repo, one_node_graph(), %{base_commit: base_commit()}, principal)
      end

      reads = :counters.new(1, [])

      stub(ObjectStore, :get, fn key ->
        if String.ends_with?(key, "/state.json"), do: :counters.add(reads, 1, 1)
        Mimic.call_original(ObjectStore, :get, [key])
      end)

      assert {:ok, %{runs: [_, _], next_cursor: cursor}} = Factory.list(repo, limit: 2)
      assert is_binary(cursor)
      assert :counters.get(reads, 1) == 2
    end

    test "rejects an out-of-range limit or a malformed cursor", %{repo: repo} do
      for opts <- [[limit: 0], [limit: 501], [limit: "2"], [cursor: "../state"], [cursor: 7]] do
        assert {:error, %ServiceError{kind: :invalid}} = Factory.list(repo, opts), inspect(opts)
      end
    end

    test "events page by revision and say whether more remain", %{repo: repo, principal: principal} do
      graph = %{"nodes" => [%{"id" => "a", "title" => "A"}, %{"id" => "b", "title" => "B"}]}
      assert {:ok, run} = Factory.create(repo, graph, %{base_commit: base_commit()}, principal)
      assert {:ok, _} = Factory.claim(repo, run.id, "pod-a", principal)
      assert {:ok, _} = Factory.claim(repo, run.id, "pod-b", principal)
      assert {:ok, _} = Factory.cancel(repo, run.id, principal)

      assert {:ok, %{events: first, next_cursor: 2, has_more: true}} =
               Factory.events(repo, run.id, 0, limit: 2)

      assert Enum.map(first, & &1["revision"]) == [1, 2]

      assert {:ok, %{events: second, next_cursor: 4, has_more: false}} =
               Factory.events(repo, run.id, 2, limit: 5)

      assert Enum.map(second, & &1["revision"]) == [3, 4]

      assert {:ok, %{events: [], next_cursor: 4, has_more: false}} = Factory.events(repo, run.id, 4, limit: 5)

      # Without a limit, the historical response: everything after the cursor.
      assert {:ok, %{events: all, next_cursor: 4}} = Factory.events(repo, run.id)
      assert length(all) == 4

      assert {:error, %ServiceError{kind: :invalid}} = Factory.events(repo, run.id, 0, limit: 0)
    end
  end

  describe "issues" do
    setup %{repo: repo} do
      start_replica_runtime()
      {:ok, _} = Control.create_repository(repo)
      :ok
    end

    test "pages by number, skipping deleted issues without ending a page early", %{
      repo: repo,
      principal: principal
    } do
      for title <- ~w(one two three four five) do
        assert {:ok, _} = Issues.create(repo, title, "", principal)
      end

      assert {:ok, _} = Issues.delete(repo, 2, principal)

      assert {:ok, %{issues: all, next_cursor: nil, count: 4}} = Issues.list(repo)
      assert Enum.map(all, & &1.number) == [1, 3, 4, 5]

      assert {:ok, %{issues: first, next_cursor: 3}} = Issues.list(repo, limit: 2)
      assert Enum.map(first, & &1.number) == [1, 3]

      assert {:ok, %{issues: second, next_cursor: nil}} = Issues.list(repo, limit: 2, cursor: 3)
      assert Enum.map(second, & &1.number) == [4, 5]

      assert {:error, %ServiceError{kind: :invalid}} = Issues.list(repo, limit: 501)
      assert {:error, %ServiceError{kind: :invalid}} = Issues.list(repo, cursor: "3")
    end

    test "are exposed over HTTP with validated parameters", %{
      repo: repo,
      namespace: namespace,
      principal: principal
    } do
      Config.put_overrides(
        Map.put(
          Config.overrides(),
          :auth,
          {Code.Auth.Static, tokens: %{"reader" => %{account: namespace, scopes: [:read]}}}
        )
      )

      for title <- ~w(one two three) do
        assert {:ok, _} = Issues.create(repo, title, "", principal)
      end

      page = request(:get, "/api/issues?repository=#{repo}&limit=2")
      assert page.status == 200
      assert %{"count" => 2, "next_cursor" => 2} = JSON.decode!(page.resp_body)

      rest = request(:get, "/api/issues?repository=#{repo}&limit=2&cursor=2")
      assert %{"issues" => [%{"number" => 3}], "next_cursor" => nil} = JSON.decode!(rest.resp_body)

      assert request(:get, "/api/issues?repository=#{repo}&limit=abc").status == 422
      assert request(:get, "/api/issues?repository=#{repo}&limit=0").status == 422
      assert request(:get, "/api/work-runs?repository=#{repo}&limit=-1").status == 422
      assert request(:get, "/api/work-runs?repository=#{repo}&limit=1").status == 200
    end
  end

  defp collect_pages(fetch, cursor \\ nil, acc \\ []) do
    assert {:ok, %{runs: runs, next_cursor: next}} = fetch.(cursor)
    acc = acc ++ [runs]
    if next, do: collect_pages(fetch, next, acc), else: acc
  end

  defp request(method, path) do
    method
    |> conn(path, "")
    |> put_req_header("authorization", "Bearer reader")
    |> Router.call(Router.init([]))
  end

  defp one_node_graph, do: %{"nodes" => [%{"id" => "work", "title" => "Work"}]}
  defp base_commit, do: String.duplicate("a", 40)
end
