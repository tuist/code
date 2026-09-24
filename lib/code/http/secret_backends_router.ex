defmodule Code.HTTP.SecretBackendsRouter do
  @moduledoc false

  use Plug.Router

  import Plug.Conn

  alias Code.Factory.SecretBackend
  alias Code.HTTP.AuthPlug
  alias Code.HTTP.ServiceResponse
  alias Code.Policy

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["application/json"])
  plug(:dispatch)

  get "/" do
    with_account(conn, fn account -> SecretBackend.list(account) end)
  end

  get "/:backend" do
    with_account(conn, fn account -> SecretBackend.get(account, backend) end)
  end

  put "/:backend" do
    with_account(conn, fn account ->
      SecretBackend.put(account, backend, conn.body_params, conn.assigns.principal)
    end)
  end

  match _ do
    error(conn, 404, "code: endpoint not found")
  end

  defp with_account(conn, fun) do
    with {:ok, repository, conn} <- repository(conn),
         {:ok, conn} <- AuthPlug.authorize(conn, repository, :admin) do
      account = Policy.account_of(repository)

      case AuthPlug.authorize_account(conn, account, :admin) do
        {:ok, conn} -> respond(conn, fun.(account))
        {:halt, conn} -> conn
      end
    else
      {:halt, conn} -> conn
      {:error, conn} -> conn
    end
  end

  defp repository(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params["repository"] do
      repository when is_binary(repository) and byte_size(repository) > 0 -> {:ok, repository, conn}
      _ -> {:error, error(conn, 422, "repository query parameter is required")}
    end
  end

  defp respond(conn, result), do: ServiceResponse.send_result(conn, result, 200)

  defp error(conn, status, message), do: ServiceResponse.error(conn, status, message)
end
