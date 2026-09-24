defmodule Code.MCP.Tools.Issues do
  @moduledoc false
  # Issue and comment tools.

  alias Code.Issues
  alias Code.MCP.Tools.Support

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "create_issue",
        title: "Create issue",
        description: "Open an issue and record its verified author in durable repository history.",
        inputSchema: %{
          type: "object",
          required: ["repository", "title"],
          properties: %{
            repository: Support.repository_property(),
            title: %{type: "string"},
            body: %{type: "string", description: "Issue description. Defaults to empty."}
          }
        }
      },
      %{
        name: "list_issues",
        title: "List issues",
        description:
          "List the current issues in a repository, by number. Pass limit or cursor to page " <>
            "through them; next_cursor is null on the last page.",
        inputSchema: %{
          type: "object",
          required: ["repository"],
          properties: %{
            repository: Support.repository_property(),
            limit: Support.limit_property(),
            cursor: %{type: "integer", minimum: 0, description: "The next_cursor from the previous page."}
          }
        }
      },
      %{
        name: "get_issue",
        title: "Get issue",
        description: "Read an issue and its current comments.",
        inputSchema: %{
          type: "object",
          required: ["repository", "issue"],
          properties: %{repository: Support.repository_property(), issue: %{type: "integer", minimum: 1}}
        }
      },
      %{
        name: "update_issue",
        title: "Update issue",
        description: "Update an issue's title, description, or open and closed state.",
        inputSchema: %{
          type: "object",
          required: ["repository", "issue"],
          properties: %{
            repository: Support.repository_property(),
            issue: %{type: "integer", minimum: 1},
            title: %{type: "string"},
            body: %{type: "string"},
            state: %{type: "string", enum: ["open", "closed"]}
          }
        }
      },
      %{
        name: "delete_issue",
        title: "Delete issue",
        description: "Hide an issue from current views while retaining its immutable audit history.",
        inputSchema: %{
          type: "object",
          required: ["repository", "issue"],
          properties: %{repository: Support.repository_property(), issue: %{type: "integer", minimum: 1}}
        }
      },
      %{
        name: "add_issue_comment",
        title: "Add issue comment",
        description: "Add a comment recorded with the verified author.",
        inputSchema: %{
          type: "object",
          required: ["repository", "issue", "body"],
          properties: %{
            repository: Support.repository_property(),
            issue: %{type: "integer", minimum: 1},
            body: %{type: "string"}
          }
        }
      },
      %{
        name: "get_issue_comment",
        title: "Get issue comment",
        description: "Read one current comment from an issue.",
        inputSchema: %{
          type: "object",
          required: ["repository", "issue", "comment"],
          properties: %{
            repository: Support.repository_property(),
            issue: %{type: "integer", minimum: 1},
            comment: %{type: "string"}
          }
        }
      },
      %{
        name: "update_issue_comment",
        title: "Update issue comment",
        description: "Replace a comment's current body while retaining its immutable history.",
        inputSchema: %{
          type: "object",
          required: ["repository", "issue", "comment", "body"],
          properties: %{
            repository: Support.repository_property(),
            issue: %{type: "integer", minimum: 1},
            comment: %{type: "string"},
            body: %{type: "string"}
          }
        }
      },
      %{
        name: "delete_issue_comment",
        title: "Delete issue comment",
        description: "Hide a comment from current views while retaining its immutable history.",
        inputSchema: %{
          type: "object",
          required: ["repository", "issue", "comment"],
          properties: %{
            repository: Support.repository_property(),
            issue: %{type: "integer", minimum: 1},
            comment: %{type: "string"}
          }
        }
      },
      %{
        name: "issue_history",
        title: "Issue history",
        description: "Read an issue's immutable event history.",
        inputSchema: %{
          type: "object",
          required: ["repository", "issue"],
          properties: %{repository: Support.repository_property(), issue: %{type: "integer", minimum: 1}}
        }
      }
    ]
  end

  @spec call(String.t(), map(), Code.Auth.Principal.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def call("create_issue", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :write) do
      Issues.create(repo_id, args["title"], args["body"] || "", principal)
    end
  end

  def call("list_issues", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read),
         do: Issues.list(repo_id, limit: args["limit"], cursor: args["cursor"])
  end

  def call("get_issue", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read), do: Issues.get(repo_id, args["issue"])
  end

  def call("update_issue", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :write) do
      Issues.update(repo_id, args["issue"], issue_changes(args), principal)
    end
  end

  def call("delete_issue", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :write),
         do: Issues.delete(repo_id, args["issue"], principal)
  end

  def call("add_issue_comment", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :write) do
      Issues.add_comment(repo_id, args["issue"], args["body"], principal)
    end
  end

  def call("get_issue_comment", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read) do
      Issues.get_comment(repo_id, args["issue"], args["comment"])
    end
  end

  def call("update_issue_comment", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :write) do
      Issues.update_comment(repo_id, args["issue"], args["comment"], args["body"], principal)
    end
  end

  def call("delete_issue_comment", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :write) do
      Issues.delete_comment(repo_id, args["issue"], args["comment"], principal)
    end
  end

  def call("issue_history", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read), do: Issues.events(repo_id, args["issue"])
  end

  defp issue_changes(args) do
    [:title, :body, :state]
    |> Enum.reduce(%{}, fn key, changes ->
      value = args[Atom.to_string(key)]
      if is_nil(value), do: changes, else: Map.put(changes, key, value)
    end)
  end
end
