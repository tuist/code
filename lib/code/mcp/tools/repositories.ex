defmodule Code.MCP.Tools.Repositories do
  @moduledoc false
  # Repository lifecycle and Git plumbing tools.

  alias Code.Auth
  alias Code.Control
  alias Code.Git
  alias Code.MCP.Tools.Support
  alias Code.WAL
  alias Code.WAL.Index
  alias Code.Wal.V1

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "list_repositories",
        title: "List repositories",
        description: "List the repositories the caller may read.",
        inputSchema: %{
          type: "object",
          properties: %{
            prefix: %{type: "string", description: "Only return repositories starting with this prefix."}
          }
        }
      },
      %{
        name: "describe_repository",
        title: "Describe a repository",
        description:
          "Log state, default branch, size and replica placement for one repository. " <>
            "Useful for confirming a write landed and for diagnosing replica lag.",
        inputSchema: %{
          type: "object",
          required: ["repository"],
          properties: %{repository: Support.repository_property()}
        }
      },
      %{
        name: "create_repository",
        title: "Create a repository",
        description:
          "Create an empty repository. Cheap by design: a repository is one object in storage " <>
            "until something is pushed to it, so creating one per task is a reasonable thing to do.",
        inputSchema: %{
          type: "object",
          required: ["repository"],
          properties: %{
            repository: Support.repository_property(),
            default_branch: %{type: "string", description: "Defaults to main."}
          }
        }
      },
      %{
        name: "list_refs",
        title: "List refs",
        description: "Branches and tags with the object ids they point at.",
        inputSchema: %{
          type: "object",
          required: ["repository"],
          properties: %{
            repository: Support.repository_property(),
            pattern: %{type: "string", description: "Glob to filter ref names, e.g. refs/heads/*."}
          }
        }
      },
      %{
        name: "read_file",
        title: "Read a file",
        description: "Read a file's contents at a revision, without cloning.",
        inputSchema: %{
          type: "object",
          required: ["repository", "path"],
          properties: %{
            repository: Support.repository_property(),
            path: %{type: "string", description: "Path within the repository."},
            ref: %{type: "string", description: "Branch, tag or commit. Defaults to the default branch."}
          }
        }
      },
      %{
        name: "list_tree",
        title: "List a directory",
        description: "List the entries of a directory at a revision.",
        inputSchema: %{
          type: "object",
          required: ["repository"],
          properties: %{
            repository: Support.repository_property(),
            path: %{type: "string", description: "Directory to list. Defaults to the root."},
            ref: %{type: "string"},
            recursive: %{type: "boolean", description: "List the whole subtree."}
          }
        }
      },
      %{
        name: "search",
        title: "Search the code",
        description:
          "Search file contents at a revision. Runs git grep server-side, so it does not " <>
            "require the agent to hold the repository.",
        inputSchema: %{
          type: "object",
          required: ["repository", "query"],
          properties: %{
            repository: Support.repository_property(),
            query: %{type: "string"},
            ref: %{type: "string"},
            path: %{type: "string", description: "Restrict the search to this path."},
            regex: %{type: "boolean", description: "Treat the query as an extended regular expression."},
            ignore_case: %{type: "boolean"},
            limit: %{type: "integer", description: "Maximum matches to return. Defaults to 100."}
          }
        }
      },
      %{
        name: "log",
        title: "Commit history",
        description: "Commit history for a revision, newest first.",
        inputSchema: %{
          type: "object",
          required: ["repository"],
          properties: %{
            repository: Support.repository_property(),
            ref: %{type: "string"},
            path: %{type: "string", description: "Only commits touching this path."},
            limit: %{type: "integer", description: "Defaults to 50."}
          }
        }
      },
      %{
        name: "diff",
        title: "Diff two revisions",
        description: "Unified diff between two revisions.",
        inputSchema: %{
          type: "object",
          required: ["repository", "from", "to"],
          properties: %{
            repository: Support.repository_property(),
            from: %{type: "string"},
            to: %{type: "string"},
            path: %{type: "string"},
            stat_only: %{type: "boolean", description: "Return a summary instead of the full diff."}
          }
        }
      },
      %{
        name: "commit",
        title: "Commit changes",
        description:
          "Write files and commit them to a branch, without a working tree. Goes through the " <>
            "write-ahead log exactly as a git push would, so it is durable, ordered, and " <>
            "rejected if the branch moved underneath you.",
        inputSchema: %{
          type: "object",
          required: ["repository", "branch", "message", "changes"],
          properties: %{
            repository: Support.repository_property(),
            branch: %{type: "string", description: "Branch to commit onto. Created if absent."},
            message: %{type: "string", description: "Commit message."},
            changes: %{
              type: "array",
              description: "Files to write or delete.",
              items: %{
                type: "object",
                required: ["path"],
                properties: %{
                  path: %{type: "string"},
                  content: %{type: "string", description: "Omit to delete the file."},
                  encoding: %{type: "string", enum: ["utf8", "base64"], description: "Defaults to utf8."},
                  mode: %{type: "string", description: "Git file mode. Defaults to 100644."}
                }
              }
            },
            expected_head: %{
              type: "string",
              description:
                "Commit the branch must currently point at. Supply it to make the write " <>
                  "conditional and avoid clobbering a concurrent change."
            },
            author_name: %{type: "string"},
            author_email: %{type: "string"}
          }
        }
      },
      %{
        name: "create_branch",
        title: "Create or move a branch",
        description: "Point a branch at a commit.",
        inputSchema: %{
          type: "object",
          required: ["repository", "branch", "target"],
          properties: %{
            repository: Support.repository_property(),
            branch: %{type: "string"},
            target: %{type: "string", description: "Commit or ref to point at."},
            force: %{type: "boolean", description: "Allow moving a branch that already exists."}
          }
        }
      },
      %{
        name: "delete_branch",
        title: "Delete a branch",
        description: "Delete a branch.",
        inputSchema: %{
          type: "object",
          required: ["repository", "branch"],
          properties: %{repository: Support.repository_property(), branch: %{type: "string"}}
        }
      },
      %{
        name: "history",
        title: "Write-ahead log history",
        description:
          "The repository's push history as recorded in the log, including who pushed what " <>
            "and when. Every state the repository has ever been in is retained, so this is " <>
            "an audit trail rather than a best-effort record.",
        inputSchema: %{
          type: "object",
          required: ["repository"],
          properties: %{
            repository: Support.repository_property(),
            limit: %{type: "integer", description: "Defaults to 50."}
          }
        }
      },
      %{
        name: "clone_url",
        title: "Get the clone URL",
        description:
          "The URL to clone this repository from, for when an agent genuinely does want a " <>
            "working tree and the tools above are not enough.",
        inputSchema: %{
          type: "object",
          required: ["repository"],
          properties: %{repository: Support.repository_property()}
        }
      }
    ]
  end

  @spec call(String.t(), map(), Code.Auth.Principal.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def call("list_repositories", args, principal, _opts) do
    prefix = args["prefix"]

    with {:ok, ids} <- Control.list_repositories() do
      visible =
        ids
        |> Enum.filter(&Auth.Principal.allows?(principal, &1, :read))
        |> then(fn list -> if prefix, do: Enum.filter(list, &String.starts_with?(&1, prefix)), else: list end)

      {:ok, %{repositories: visible, count: length(visible)}}
    end
  end

  def call("create_repository", args, principal, _opts) do
    repo_id = args["repository"]
    default_branch = Support.normalize_branch(args["default_branch"] || "main")

    with :ok <- Support.authorize(principal, repo_id, :write),
         :ok <- Support.public_reference(default_branch) do
      opts = if args["default_branch"], do: [default_branch: default_branch], else: []

      case Control.create_repository(repo_id, opts) do
        {:ok, summary} -> {:ok, summary}
        {:error, :already_exists} -> {:error, "repository #{repo_id} already exists"}
        {:error, reason} -> {:error, "could not create #{repo_id}: #{inspect(reason)}"}
      end
    end
  end

  def call("describe_repository", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read) do
      case Control.describe_repository(repo_id) do
        {:ok, description} -> {:ok, description}
        {:error, :not_found} -> {:error, "repository #{repo_id} not found"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  def call("list_refs", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read),
         {:ok, index, _etag} <- WAL.fetch(repo_id) do
      refs =
        index.refs
        |> Enum.reject(fn {ref, _oid} -> Git.Ref.internal?(ref) end)
        |> Enum.filter(fn {ref, _oid} -> matches_pattern?(ref, args["pattern"]) end)
        |> Enum.sort()
        |> Enum.map(fn {ref, oid} -> %{ref: ref, oid: oid} end)

      {:ok, %{refs: refs, head: Index.head(index), count: length(refs)}}
    end
  end

  def call("read_file", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read) do
      Support.in_repository(repo_id, &read_file_at(&1, args))
    end
  end

  def call("list_tree", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read) do
      Support.in_repository(repo_id, &list_tree_at(&1, args))
    end
  end

  def call("search", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read) do
      Support.in_repository(repo_id, &search_at(&1, args))
    end
  end

  def call("log", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read) do
      Support.in_repository(repo_id, &log_at(&1, args))
    end
  end

  def call("diff", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read) do
      Support.in_repository(repo_id, &diff_at(&1, args))
    end
  end

  def call("commit", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :write) do
      Support.in_repository(repo_id, fn view -> do_commit(view, repo_id, args, principal) end)
    end
  end

  def call("create_branch", args, principal, _opts) do
    repo_id = args["repository"]
    branch = Support.normalize_branch(args["branch"])

    with :ok <- Support.authorize(principal, repo_id, :write),
         :ok <- Support.public_reference(branch),
         :ok <- Support.public_reference(args["target"]) do
      Support.in_repository(repo_id, &point_branch(&1, repo_id, branch, args, principal))
    end
  end

  def call("delete_branch", args, principal, _opts) do
    repo_id = args["repository"]
    branch = Support.normalize_branch(args["branch"])

    with :ok <- Support.authorize(principal, repo_id, :write),
         :ok <- Support.public_reference(branch),
         {:ok, index, _etag} <- WAL.fetch(repo_id) do
      current = Index.ref(index, branch)
      zero = WAL.Entry.zero_oid()

      if current == zero do
        {:error, "#{branch} does not exist"}
      else
        command = %V1.RefCommand{ref: branch, old_oid: current, new_oid: zero}
        apply_refs(repo_id, [command], principal, %{branch: branch, deleted: true})
      end
    end
  end

  def call("history", args, principal, _opts) do
    repo_id = args["repository"]
    limit = args["limit"] || 50

    with :ok <- Support.authorize(principal, repo_id, :read),
         {:ok, index, _etag} <- WAL.fetch(repo_id) do
      entries =
        index.entries
        |> Enum.reverse()
        |> Enum.take(limit)
        |> Enum.map(fn pointer ->
          %{
            seq: pointer.seq,
            type:
              pointer.type
              |> Atom.to_string()
              |> String.replace_prefix("ENTRY_TYPE_", "")
              |> String.downcase(),
            at: to_iso(pointer.at_ms),
            size: pointer.size,
            packs: length(pointer.packs)
          }
        end)

      {:ok,
       %{
         repository: repo_id,
         epoch: index.epoch,
         seq: index.seq,
         entries: entries,
         note:
           "Entries before the current epoch were compacted into the base; " <>
             "earlier index generations are retained in object storage under history/."
       }}
    end
  end

  def call("clone_url", args, principal, opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize(principal, repo_id, :read) do
      base = Keyword.get(opts, :public_url) || Code.Config.public_url()
      {:ok, %{repository: repo_id, http: "#{base}/#{repo_id}.git"}}
    end
  end

  defp read_file_at(view, args) do
    with {:ok, rev} <- Support.public_revision(args["ref"], view) do
      case Git.read_file(view.path, rev, args["path"]) do
        {:ok, content} ->
          {:ok,
           %{
             path: args["path"],
             ref: rev,
             size: byte_size(content),
             binary: binary?(content),
             content: if(binary?(content), do: Base.encode64(content), else: content),
             encoding: if(binary?(content), do: "base64", else: "utf8")
           }}

        {:error, _} ->
          {:error, "#{args["path"]} does not exist at #{rev}"}
      end
    end
  end

  defp list_tree_at(view, args) do
    with {:ok, rev} <- Support.public_revision(args["ref"], view) do
      dir = args["path"] || ""
      dir = if dir == "" or String.ends_with?(dir, "/"), do: dir, else: dir <> "/"

      case Git.list_tree(view.path, rev, dir, recursive: args["recursive"] == true) do
        {:ok, entries} ->
          {:ok, %{ref: rev, path: args["path"] || "", entries: entries, count: length(entries)}}

        {:error, _} ->
          {:error, "could not list #{args["path"] || "/"} at #{rev}"}
      end
    end
  end

  defp search_at(view, args) do
    with {:ok, rev} <- Support.public_revision(args["ref"], view) do
      opts = [
        limit: args["limit"] || 100,
        fixed: args["regex"] != true,
        ignore_case: args["ignore_case"] == true,
        path: args["path"]
      ]

      case Git.grep(view.path, rev, args["query"], opts) do
        {:ok, matches} ->
          {:ok, %{ref: rev, query: args["query"], matches: matches, count: length(matches)}}

        {:error, reason} ->
          {:error, "search failed: #{inspect(reason)}"}
      end
    end
  end

  defp log_at(view, args) do
    with {:ok, rev} <- Support.public_revision(args["ref"], view) do
      case Git.log(view.path, rev, limit: args["limit"] || 50, path: args["path"]) do
        {:ok, commits} -> {:ok, %{ref: rev, commits: commits, count: length(commits)}}
        {:error, _} -> {:error, "could not read history at #{rev}"}
      end
    end
  end

  defp diff_at(view, args) do
    with {:ok, from} <- Support.public_revision(args["from"], view),
         {:ok, to} <- Support.public_revision(args["to"], view) do
      case Git.diff(view.path, from, to, path: args["path"], stat_only: args["stat_only"] == true) do
        {:ok, diff} -> {:ok, %{from: from, to: to, diff: diff, empty: diff == ""}}
        {:error, reason} -> {:error, "could not diff: #{inspect(reason)}"}
      end
    end
  end

  defp point_branch(view, repo_id, branch, args, principal) do
    with {:ok, index, _etag} <- WAL.fetch(repo_id),
         {:ok, target} <- Git.resolve(view.path, args["target"]),
         true <- Git.public_commit?(view.path, target),
         current = Index.ref(index, branch),
         :ok <- check_branch_free(branch, current, args["force"]) do
      command = %V1.RefCommand{ref: branch, old_oid: current, new_oid: target}
      apply_refs(repo_id, [command], principal, %{branch: branch, oid: target})
    else
      false -> {:error, "reference not found"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "could not resolve #{args["target"]}: #{inspect(reason)}"}
    end
  end

  defp check_branch_free(branch, current, force) do
    if current != WAL.Entry.zero_oid() and force != true do
      {:error, "#{branch} already exists; pass force to move it"}
    else
      :ok
    end
  end

  # ----------------------------------------------------------------------

  defp do_commit(view, repo_id, args, principal) do
    branch = Support.normalize_branch(args["branch"])

    with :ok <- Support.public_reference(branch),
         {:ok, index, _etag} <- WAL.fetch(repo_id),
         current = Index.ref(index, branch),
         :ok <- check_expected_head(current, args["expected_head"]),
         {:ok, changes} <- build_changes(view.path, args["changes"]),
         {:ok, tree} <- Git.write_tree(view.path, base_tree(current), changes),
         {:ok, commit} <-
           Git.commit_tree(view.path, tree, parents(current), message(args), author(args, principal)) do
      command = %V1.RefCommand{ref: branch, old_oid: current, new_oid: commit}

      apply_refs(repo_id, [command], principal, %{
        branch: branch,
        commit: commit,
        tree: tree,
        parents: parents(current),
        files_changed: length(changes)
      })
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "commit failed: #{inspect(reason)}"}
    end
  end

  defp check_expected_head(_current, nil), do: :ok

  defp check_expected_head(current, expected) do
    if current == expected do
      :ok
    else
      {:error, "branch is at #{String.slice(current, 0, 12)}, not #{String.slice(expected, 0, 12)}"}
    end
  end

  defp base_tree(oid) do
    if oid == WAL.Entry.zero_oid(), do: nil, else: oid
  end

  defp parents(oid) do
    if oid == WAL.Entry.zero_oid(), do: [], else: [oid]
  end

  defp message(args), do: String.trim_trailing(args["message"]) <> "\n"

  defp author(args, principal) do
    %{
      name: args["author_name"] || principal.subject,
      email: args["author_email"] || "#{principal.subject}@code.local"
    }
  end

  defp build_changes(repo_path, changes) when is_list(changes) do
    changes
    |> Enum.reduce_while({:ok, []}, fn change, {:ok, acc} ->
      case build_change(repo_path, change) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp build_changes(_repo_path, _changes), do: {:error, "changes must be an array"}

  defp build_change(_repo_path, %{"path" => path} = change) when not is_map_key(change, "content") do
    {:ok, %{path: path, oid: nil}}
  end

  defp build_change(repo_path, %{"path" => path, "content" => content} = change) do
    with {:ok, bytes} <- decode_content(content, change["encoding"]),
         {:ok, oid} <- Git.write_blob(repo_path, bytes) do
      {:ok, %{path: path, oid: oid, mode: change["mode"] || "100644"}}
    end
  end

  defp build_change(_repo_path, _change), do: {:error, "each change needs a path"}

  defp decode_content(content, "base64") do
    case Base.decode64(content) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, "content is not valid base64"}
    end
  end

  defp decode_content(content, _encoding), do: {:ok, content}

  # Every write goes through the same ingest path a git push takes, so the
  # compare-and-swap, the ordering and the durability guarantee are identical.
  defp apply_refs(repo_id, commands, principal, result) do
    actor = %V1.Actor{
      subject: principal.subject,
      account: principal.account || "",
      node: Code.Config.node_id()
    }

    case Code.Ingest.update_refs(repo_id, commands, actor: actor) do
      {:ok, appended} -> {:ok, Map.merge(result, %{seq: appended.seq, epoch: appended.epoch})}
      {:error, message} -> {:error, message}
    end
  end

  defp matches_pattern?(_ref, nil), do: true

  defp matches_pattern?(ref, pattern) do
    Code.Auth.Principal.matches?(pattern, ref)
  end

  defp binary?(content), do: not String.valid?(content) or String.contains?(content, <<0>>)

  defp to_iso(0), do: nil
  defp to_iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
