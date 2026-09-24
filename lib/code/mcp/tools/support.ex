defmodule Code.MCP.Tools.Support do
  @moduledoc false
  # Helpers every tool domain shares: authorization, routing to the owning
  # replica, and the rules that keep internal references out of agent reach.

  alias Code.Auth
  alias Code.Git
  alias Code.Replica
  alias Code.WAL

  @spec repository_property() :: map()
  def repository_property do
    %{type: "string", description: "Repository id, for example acme/ios-app."}
  end

  @spec limit_property() :: map()
  def limit_property do
    %{
      type: "integer",
      minimum: 1,
      maximum: Code.Page.max_limit(),
      description: "Page size. Omit both limit and cursor to receive everything."
    }
  end

  @spec authorize(Auth.Principal.t(), term(), Auth.Principal.permission()) :: :ok | {:error, String.t()}
  def authorize(principal, repo_id, permission) do
    cond do
      not WAL.valid_id?(repo_id) ->
        {:error, "invalid repository id: #{inspect(repo_id)}"}

      Auth.authorize(principal, repo_id, permission) == :ok ->
        :ok

      true ->
        # Same reasoning as the HTTP surface: do not confirm existence to
        # someone who may not read it.
        {:error, "repository #{repo_id} not found"}
    end
  end

  @spec authorize_account(Auth.Principal.t(), term()) :: :ok | {:error, String.t()}
  def authorize_account(principal, repo_id) do
    with :ok <- authorize(principal, repo_id, :admin) do
      account = Code.Policy.account_of(repo_id)

      case Auth.authorize_account(principal, account, :admin) do
        :ok -> :ok
        {:error, :forbidden} -> {:error, "not permitted to administer account #{account}"}
      end
    end
  end

  # Route to the node that already holds the repository. Any pod can accept the
  # call; this is what stops every pod from having to materialize everything.
  @spec in_repository(String.t(), (Replica.view() -> term())) :: term()
  def in_repository(repo_id, fun) do
    case Replica.via_owner(repo_id, fn ->
           case Replica.ensure_fresh(repo_id) do
             {:ok, view} -> fun.(view)
             {:error, :no_such_repository} -> {:error, "repository #{repo_id} not found"}
             {:error, reason} -> {:error, "repository unavailable: #{inspect(reason)}"}
           end
         end) do
      {:ok, result} -> result
    end
  end

  @spec public_revision(String.t() | nil, Replica.view()) :: {:ok, String.t()} | {:error, String.t()}
  def public_revision(nil, view), do: {:ok, view.head}
  def public_revision("", view), do: {:ok, view.head}

  def public_revision(ref, view) do
    with :ok <- public_reference(ref),
         {:ok, commit} <- Git.resolve(view.path, ref),
         true <- Git.public_commit?(view.path, commit) do
      {:ok, ref}
    else
      false -> {:error, "reference not found"}
      {:error, _reason} -> {:error, "reference not found"}
    end
  end

  @spec public_reference(term()) :: :ok | {:error, String.t()}
  def public_reference(ref) do
    if Git.Ref.internal?(ref), do: {:error, "reference not found"}, else: :ok
  end

  @spec normalize_branch(String.t()) :: String.t()
  def normalize_branch("refs/" <> _ = ref), do: ref
  def normalize_branch(branch), do: "refs/heads/#{branch}"
end
