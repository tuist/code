defmodule Code.Factory.CredentialLocator do
  @moduledoc """
  Shapes for the values in account configuration that *locate* a credential
  in the managed secret backend: the backend project, the machine identity,
  and the secret's path and field.

  These values are stored in the object store and readable by account
  administrators, so they must never be credentials themselves. Each one is
  constrained to the narrow shape the managed Infisical driver actually uses,
  and every free-form segment is additionally checked against well-known
  credential formats:

    * `project`: an Infisical project id (a UUID) or a lowercase project slug
      of up to 64 characters (`acme-production`).
    * `identity_id`: an Infisical machine identity id, which is a UUID.
    * `secret.reference`: an absolute secret path of 1 to 16 segments, each 1
      to 64 characters of `[A-Za-z0-9_.-]` (`/production/coding`), at most 512
      bytes.
    * `secret.field`: an optional key name of up to 64 characters of
      `[A-Za-z0-9_]`, starting with a letter or underscore (`api_key`).

  The credential-format check rejects well-known token prefixes (for example
  `sk-`, `ghp_`, `xoxb-`, `AKIA`, `glpat-`, JSON Web Tokens) and long segments
  that mix letters and digits with no separator, which is what generated
  secrets look like. It is a guard against pasting a secret into the wrong
  field, not a proof: the shapes above are what make it hard to store one.
  """

  @uuid ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
  @slug ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @segment ~r/^[A-Za-z0-9_.-]{1,64}$/
  @field ~r/^[A-Za-z_][A-Za-z0-9_]{0,63}$/

  # Prefixes of widely deployed credential formats. Matching is on the start
  # of each segment and is case-sensitive, as the formats are.
  @credential_prefixes ~w(
    sk- sk_live_ sk_test_ rk_live_ pk_live_ ghp_ gho_ ghu_ ghs_ ghr_ github_pat_
    xoxa- xoxb- xoxp- xoxr- xoxs- AKIA ASIA AIza glpat- ya29. eyJ
  )

  @spec project(term()) :: {:ok, String.t()} | {:error, String.t()}
  def project(value) when is_binary(value) do
    if (uuid?(value) or (byte_size(value) <= 64 and Regex.match?(@slug, value))) and
         not looks_like_credential?(value),
       do: {:ok, value},
       else: {:error, "secret backend project must be an Infisical project id or lowercase slug"}
  end

  def project(_), do: {:error, "secret backend project must be an Infisical project id or lowercase slug"}

  @spec identity_id(term()) :: :ok | {:error, String.t()}
  def identity_id(value) do
    if uuid?(value),
      do: :ok,
      else: {:error, "credential_binding identity_id must be an Infisical machine identity id (a UUID)"}
  end

  @spec secret_reference(term()) :: :ok | {:error, String.t()}
  def secret_reference("/" <> path = value) when byte_size(value) <= 512 do
    segments = String.split(path, "/")

    if length(segments) in 1..16 and Enum.all?(segments, &valid_segment?/1),
      do: :ok,
      else: secret_reference_error()
  end

  def secret_reference(_), do: secret_reference_error()

  @spec secret_field(term()) :: :ok | {:error, String.t()}
  def secret_field(nil), do: :ok

  def secret_field(value) when is_binary(value) do
    if Regex.match?(@field, value) and not looks_like_credential?(value),
      do: :ok,
      else: {:error, "credential_binding secret field must be a key name such as api_key"}
  end

  def secret_field(_), do: {:error, "credential_binding secret field must be a key name such as api_key"}

  @doc "Whether a value looks like a credential rather than a name for one."
  @spec looks_like_credential?(String.t()) :: boolean()
  def looks_like_credential?(value) when is_binary(value) do
    String.starts_with?(value, @credential_prefixes) or generated_token?(value)
  end

  defp valid_segment?(segment) do
    segment not in [".", ".."] and Regex.match?(@segment, segment) and not looks_like_credential?(segment)
  end

  # A generated secret is typically a long run of letters and digits with no
  # word separator. Human-chosen names either stay short or use `-`, `_`, `.`.
  defp generated_token?(value) do
    byte_size(value) >= 24 and Regex.match?(~r/^[A-Za-z0-9]+$/, value) and
      Regex.match?(~r/[0-9]/, value) and Regex.match?(~r/[A-Za-z]/, value)
  end

  defp uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)

  defp secret_reference_error do
    {:error,
     "credential_binding secret reference must be an absolute secret path such as /production/coding, " <>
       "not a secret value"}
  end
end
