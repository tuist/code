defmodule Code.HTTP.ServiceResponse do
  @moduledoc false
  # JSON responses for the forge service routers (issues, work runs, account
  # configuration). The status comes from the error's kind, never from words in
  # its message, and a temporary failure carries `Retry-After`.

  import Plug.Conn

  alias Code.ServiceError

  @spec send_result(Plug.Conn.t(), {:ok, term()} | {:error, ServiceError.t() | String.t()}, pos_integer()) ::
          Plug.Conn.t()
  def send_result(conn, {:ok, payload}, status), do: json(conn, status, payload)

  def send_result(conn, {:error, %ServiceError{} = error}, _status) do
    conn =
      if ServiceError.retryable?(error),
        do: put_resp_header(conn, "retry-after", Integer.to_string(ServiceError.retry_after_seconds())),
        else: conn

    error(conn, ServiceError.http_status(error), "code: #{error.message}")
  end

  def send_result(conn, {:error, message}, status) when is_binary(message),
    do: send_result(conn, {:error, ServiceError.invalid(message)}, status)

  @spec error(Plug.Conn.t(), pos_integer(), String.t()) :: Plug.Conn.t()
  def error(conn, status, message), do: json(conn, status, %{error: message})

  @spec json(Plug.Conn.t(), pos_integer(), term()) :: Plug.Conn.t()
  def json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(payload))
  end
end
