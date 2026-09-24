defmodule Code.IssuesTest do
  use Code.Case, async: true

  alias Code.Auth.Principal
  alias Code.Control
  alias Code.Git
  alias Code.Issues
  alias Code.Replica
  alias Code.ServiceError

  setup %{repo: repo, namespace: namespace} do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(repo)

    principal = %Principal{
      subject: "issue-author",
      account: namespace,
      grants: [Principal.grant("#{namespace}/**", [:read, :write])],
      source: :test
    }

    {:ok, principal: principal}
  end

  test "keeps issues and their verified authors in the repository after a replica rebuild", %{
    repo: repo,
    principal: principal
  } do
    assert {:ok, created} = Issues.create(repo, "The title", "The description", principal)
    assert created.issue.number == 1
    assert created.issue.author == %{subject: "issue-author", account: principal.account}

    assert {:ok, view} = Replica.ensure_fresh(repo)
    assert {:ok, refs} = Git.refs(view.path)
    assert Map.has_key?(refs, Issues.ref())

    Replica.evict(repo)

    assert {:ok, %{issue: issue}} = Issues.get(repo, 1)
    assert issue.title == "The title"
    assert issue.body == "The description"
    assert issue.author == %{subject: "issue-author", account: principal.account}
  end

  test "records comment and issue lifecycle events while hiding deleted state from current views", %{
    repo: repo,
    principal: principal
  } do
    assert {:ok, %{issue: issue}} = Issues.create(repo, "The title", "The description", principal)
    assert {:ok, %{issue: issue}} = Issues.update(repo, issue.number, %{state: "closed"}, principal)
    assert issue.state == "closed"

    assert {:ok, %{issue: issue}} = Issues.add_comment(repo, issue.number, "First comment", principal)
    [comment] = issue.comments
    assert comment.author.subject == "issue-author"

    assert {:ok, %{issue: issue}} =
             Issues.update_comment(repo, issue.number, comment.id, "Edited comment", principal)

    assert [%{body: "Edited comment"}] = issue.comments
    assert {:ok, %{issue: issue}} = Issues.delete_comment(repo, issue.number, comment.id, principal)
    assert issue.comments == []
    assert issue.comment_count == 0

    assert {:error, %ServiceError{kind: :not_found, message: message}} =
             Issues.get_comment(repo, issue.number, comment.id)

    assert message =~ "not found"

    assert {:ok, %{events: events}} = Issues.events(repo, issue.number)

    assert Enum.map(events, & &1.type) == [
             "issue_opened",
             "issue_updated",
             "comment_added",
             "comment_updated",
             "comment_deleted"
           ]

    assert {:ok, %{issue: deleted}} = Issues.delete(repo, issue.number, principal)
    assert deleted.state == "deleted"
    assert {:error, %ServiceError{kind: :not_found, message: message}} = Issues.get(repo, issue.number)
    assert message =~ "not found"
    assert {:ok, %{issues: []}} = Issues.list(repo)
    assert {:ok, %{events: events}} = Issues.events(repo, issue.number)
    assert List.last(events).type == "issue_deleted"
  end

  test "lists every current issue in number order, without deleted ones", %{repo: repo, principal: principal} do
    for title <- ~w(first second third) do
      assert {:ok, _} = Issues.create(repo, title, "", principal)
    end

    assert {:ok, _} = Issues.delete(repo, 2, principal)

    assert {:ok, %{issues: issues, count: 2}} = Issues.list(repo)
    assert Enum.map(issues, &{&1.number, &1.title}) == [{1, "first"}, {3, "third"}]
  end

  test "refuses a comment on a deleted issue without recording one", %{repo: repo, principal: principal} do
    assert {:ok, %{issue: issue}} = Issues.create(repo, "Doomed", "", principal)
    assert {:ok, _} = Issues.delete(repo, issue.number, principal)

    assert {:error, %ServiceError{kind: :not_found, message: "issue #1 not found"}} =
             Issues.add_comment(repo, issue.number, "Too late", principal)

    # The tombstone stays the last thing that happened to the issue.
    assert {:ok, %{events: events}} = Issues.events(repo, issue.number)
    assert Enum.map(events, & &1.type) == ["issue_opened", "issue_deleted"]
  end
end
