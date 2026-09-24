defmodule Code.MCP.Tools.Account do
  @moduledoc false
  # Account configuration tools: secret backends and inference profiles.

  alias Code.Factory.InferenceProfile
  alias Code.Factory.SecretBackend
  alias Code.MCP.Tools.Support

  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        name: "configure_secret_backend",
        title: "Configure secret backend",
        description:
          "Store a versioned account binding to the deployment-managed Infisical secret backend. It never accepts an endpoint, workload token, or secret value.",
        inputSchema: %{
          type: "object",
          required: ["repository", "backend", "project"],
          properties: %{
            repository: Support.repository_property(),
            backend: %{type: "string"},
            project: %{type: "string", description: "The Infisical project identifier for this account."},
            previous_version: %{type: "string", description: "Required when replacing an existing backend."}
          }
        }
      },
      %{
        name: "list_secret_backends",
        title: "List secret backends",
        description: "List the current non-secret backend bindings for a repository account.",
        inputSchema: %{
          type: "object",
          required: ["repository"],
          properties: %{repository: Support.repository_property()}
        }
      },
      %{
        name: "get_secret_backend",
        title: "Get secret backend",
        description: "Read one current non-secret backend binding for a repository account.",
        inputSchema: %{
          type: "object",
          required: ["repository", "backend"],
          properties: %{repository: Support.repository_property(), backend: %{type: "string"}}
        }
      },
      %{
        name: "configure_inference_profile",
        title: "Configure inference profile",
        description:
          "Store a versioned account inference profile. Its credential binding refers to a managed backend and never accepts a credential value or provider endpoint.",
        inputSchema: %{
          type: "object",
          required: ["repository", "profile", "endpoint", "model", "credential_binding"],
          properties: %{
            repository: Support.repository_property(),
            profile: %{type: "string"},
            endpoint: %{type: "string", description: "HTTPS inference endpoint without credentials."},
            model: %{type: "string"},
            credential_binding: %{type: "object"},
            previous_version: %{type: "string", description: "Required when replacing an existing profile."}
          }
        }
      },
      %{
        name: "list_inference_profiles",
        title: "List inference profiles",
        description: "List the current non-secret inference profiles for a repository account.",
        inputSchema: %{
          type: "object",
          required: ["repository"],
          properties: %{repository: Support.repository_property()}
        }
      },
      %{
        name: "get_inference_profile",
        title: "Get inference profile",
        description: "Read one current non-secret inference profile for a repository account.",
        inputSchema: %{
          type: "object",
          required: ["repository", "profile"],
          properties: %{repository: Support.repository_property(), profile: %{type: "string"}}
        }
      }
    ]
  end

  @spec call(String.t(), map(), Code.Auth.Principal.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def call("configure_inference_profile", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize_account(principal, repo_id) do
      InferenceProfile.put(
        Code.Policy.account_of(repo_id),
        args["profile"],
        Map.drop(args, ["repository", "profile"]),
        principal
      )
    end
  end

  def call("list_inference_profiles", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize_account(principal, repo_id),
         do: InferenceProfile.list(Code.Policy.account_of(repo_id))
  end

  def call("get_inference_profile", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize_account(principal, repo_id),
         do: InferenceProfile.get(Code.Policy.account_of(repo_id), args["profile"])
  end

  def call("configure_secret_backend", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize_account(principal, repo_id) do
      SecretBackend.put(
        Code.Policy.account_of(repo_id),
        args["backend"],
        args
        |> Map.drop(["repository", "backend"])
        |> Map.put("driver", "managed_infisical"),
        principal
      )
    end
  end

  def call("list_secret_backends", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize_account(principal, repo_id),
         do: SecretBackend.list(Code.Policy.account_of(repo_id))
  end

  def call("get_secret_backend", args, principal, _opts) do
    repo_id = args["repository"]

    with :ok <- Support.authorize_account(principal, repo_id),
         do: SecretBackend.get(Code.Policy.account_of(repo_id), args["backend"])
  end
end
