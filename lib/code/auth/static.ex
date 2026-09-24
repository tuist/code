defmodule Code.Auth.Static do
  @moduledoc """
  Bearer tokens from configuration.

  Suitable for development, tests, and installations small enough that rotating
  a token by hand is reasonable. Tokens are compared in constant time, since a
  Git server is a perfectly good oracle for a timing attack otherwise.
  """

  @behaviour Code.Auth

  alias Code.Auth.Principal

  @impl true
  def authenticate({:bearer, token}, config) do
    tokens =
      config |> Keyword.get(:tokens, %{}) |> Enum.reject(fn {token, _attrs} -> Code.Auth.blank?(token) end)

    case find_token(tokens, token) do
      nil -> {:error, :invalid_credential}
      {_token, attrs} -> {:ok, build(attrs)}
    end
  end

  def authenticate({:basic, _user, password}, config), do: authenticate({:bearer, password}, config)
  def authenticate(:anonymous, _config), do: {:error, :unauthenticated}

  # Compare every candidate so the work done does not depend on which token
  # matched, or on how early a mismatch occurred. A blank candidate matches
  # nothing, and blank configured tokens were dropped above, so an empty
  # secret can never be the thing that authenticates a request.
  defp find_token(tokens, candidate) do
    if Code.Auth.blank?(candidate) do
      nil
    else
      Enum.reduce(tokens, nil, fn {token, attrs}, acc ->
        if secure_compare(token, candidate), do: {token, attrs}, else: acc
      end)
    end
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_compare(_a, _b), do: false

  defp build(attrs) do
    grants =
      case Map.get(attrs, :grants) do
        nil -> default_grants(attrs)
        grants -> Enum.map(grants, &normalize_grant/1)
      end

    %Principal{
      subject: Map.get(attrs, :subject, Map.get(attrs, :account, "static")),
      account: Map.get(attrs, :account),
      grants: grants,
      source: :static
    }
  end

  # A token configured with an account and a scope list is the common shape;
  # it expands to a grant over that account's namespace and nothing else.
  #
  # Emphatically *not* also a `**` grant. Adding one alongside the scoped grant
  # makes the scoping decorative — the broad pattern subsumes it — so a token
  # meant for one tenant would authorise writes to every other. A token with no
  # account is the only unscoped case, and that is an explicit choice made in
  # configuration rather than an accident of expansion.
  defp default_grants(attrs) do
    permissions = Map.get(attrs, :scopes, [:read])

    case Map.get(attrs, :account) do
      nil -> [Principal.grant("**", permissions)]
      account -> [Principal.grant("#{account}/**", permissions)]
    end
  end

  defp normalize_grant(%{pattern: _, permissions: _} = grant), do: grant
  defp normalize_grant({pattern, permissions}), do: Principal.grant(pattern, permissions)

  @doc """
  Parse `CODE_AUTH_TOKENS` into the configuration shape.

  Format is `token=account:permissions` entries separated by semicolons, e.g.
  `sekret=acme:read,write;other=beta:read`.

  Errors name the entry by position and never repeat its contents. The value
  is made of secrets, and a configuration error is exactly the kind of thing
  that ends up in a crash report, a log aggregator or a CI transcript.
  """
  @spec parse_tokens(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse_tokens(raw) when is_binary(raw) do
    raw
    |> String.split(";", trim: true)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {entry, position}, {:ok, tokens} ->
      case parse_entry(entry) do
        {:ok, token, attrs} ->
          if Map.has_key?(tokens, token) do
            {:halt, {:error, "CODE_AUTH_TOKENS entry #{position} repeats an earlier token"}}
          else
            {:cont, {:ok, Map.put(tokens, token, attrs)}}
          end

        {:error, problem} ->
          {:halt,
           {:error, "CODE_AUTH_TOKENS entry #{position} #{problem}; expected token=account:permissions"}}
      end
    end)
  end

  @doc """
  Like `parse_tokens/1`, but raises a redacted `ArgumentError`.

  Used from runtime configuration, where raising is how a node refuses to
  boot with configuration it cannot honour.
  """
  @spec parse_tokens!(String.t()) :: map()
  def parse_tokens!(raw) do
    case parse_tokens(raw) do
      {:ok, tokens} -> tokens
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp parse_entry(entry) do
    with [token, rest] <- String.split(entry, "=", parts: 2),
         token = String.trim(token),
         false <- token == "",
         [account, permissions] <- String.split(rest, ":", parts: 2),
         account = String.trim(account),
         false <- account == "",
         {:ok, scopes} <- parse_permissions(permissions) do
      {:ok, token, %{account: account, scopes: scopes}}
    else
      true -> {:error, "has an empty token or account"}
      {:error, problem} -> {:error, problem}
      _ -> {:error, "is malformed"}
    end
  end

  defp parse_permissions(permissions) do
    scopes =
      permissions
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.trim() |> Principal.permission()))

    cond do
      scopes == [] -> {:error, "grants no permissions"}
      Enum.any?(scopes, &is_nil/1) -> {:error, "names an unknown permission"}
      true -> {:ok, scopes}
    end
  end
end
