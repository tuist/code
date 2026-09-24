defmodule Code.HTTP.QueryParams do
  @moduledoc false
  # Query-string parsing for the forge service routers.

  import Plug.Conn

  @doc """
  Read an optional non-negative integer query parameter. An absent parameter
  is `nil`; a present one that is not a non-negative integer is an error
  naming it.
  """
  @spec integer(Plug.Conn.t(), String.t()) :: {:ok, non_neg_integer() | nil} | {:error, String.t()}
  def integer(conn, name) do
    conn = fetch_query_params(conn)

    case conn.query_params[name] do
      nil ->
        {:ok, nil}

      raw ->
        case Integer.parse(raw) do
          {value, ""} when value >= 0 -> {:ok, value}
          _ -> {:error, "#{name} must be a non-negative integer"}
        end
    end
  end

  @doc "Read an optional string query parameter."
  @spec string(Plug.Conn.t(), String.t()) :: String.t() | nil
  def string(conn, name), do: fetch_query_params(conn).query_params[name]
end
