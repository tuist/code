defmodule Code.Config.Runtime do
  @moduledoc """
  Validation for values read from the environment at boot.

  `config/runtime.exs` calls these so that configuration a node cannot honour
  safely stops it from starting, with a message that says which variable to
  fix. They live here rather than inline so they can be tested; a check that
  only runs inside a release boot is a check nobody has ever seen fail.

  Messages never include the offending value. Several of these variables are
  secrets, and a boot failure is exactly what gets pasted into an issue.
  """

  @backends ~w(oidc webhook static none)

  @doc """
  The authentication backend named by `CODE_AUTH_BACKEND`.

  `none` grants everything to everyone. It is refused in production, as
  `Code.Auth.Allow` promises: an open Git server that happens to work is the
  kind of thing that survives to deployment.
  """
  @spec auth_backend!(String.t(), atom()) :: :oidc | :webhook | :static | :none
  def auth_backend!("none", :prod) do
    raise ArgumentError, """
    CODE_AUTH_BACKEND=none is refused in production.

    It authorises every request as an administrator. Use oidc, webhook or
    static instead.
    """
  end

  def auth_backend!("oidc", _env), do: :oidc
  def auth_backend!("webhook", _env), do: :webhook
  def auth_backend!("static", _env), do: :static
  def auth_backend!("none", _env), do: :none

  def auth_backend!(_backend, _env) do
    raise ArgumentError, "CODE_AUTH_BACKEND must be one of #{Enum.join(@backends, ", ")}"
  end

  @doc """
  A required secret, which must not be blank.

  An empty or whitespace-only secret is treated as absent. Accepting one would
  make "no credential" and "the credential" indistinguishable to anything that
  trims its input, which is most things.
  """
  @spec secret!(String.t(), String.t() | nil) :: String.t()
  def secret!(variable, value) do
    if Code.Auth.blank?(value) do
      raise ArgumentError, "#{variable} must be set to a non-empty value"
    else
      value
    end
  end

  @doc """
  An optional IP address to bind a listener to, or `nil` for all interfaces.
  """
  @spec ip!(String.t(), String.t() | nil) :: :inet.ip_address() | nil
  def ip!(variable, value) do
    if Code.Auth.blank?(value) do
      nil
    else
      case :inet.parse_address(value |> String.trim() |> String.to_charlist()) do
        {:ok, address} -> address
        {:error, _} -> raise ArgumentError, "#{variable} must be an IPv4 or IPv6 address"
      end
    end
  end

  @doc "A non-negative integer, such as a duration in milliseconds."
  @spec non_neg_integer!(String.t(), String.t()) :: non_neg_integer()
  def non_neg_integer!(variable, value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> raise ArgumentError, "#{variable} must be a non-negative integer"
    end
  end
end
