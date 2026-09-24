defmodule Code.HTTP.WorkRunsRouter do
  @moduledoc false

  use Plug.Router

  import Plug.Conn

  alias Code.Factory
  alias Code.HTTP.AuthPlug
  alias Code.HTTP.ServiceResponse

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["application/json"])
  plug(:dispatch)

  get "/" do
    with_authorized(conn, :read, fn repo_id, _principal -> Factory.list(repo_id) end)
  end

  post "/" do
    with_authorized(
      conn,
      :write,
      fn repo_id, principal ->
        Factory.create(repo_id, conn.body_params["graph"], conn.body_params, principal)
      end,
      201
    )
  end

  get "/:run/events" do
    case after_revision(conn) do
      {:ok, after_revision} ->
        with_run(conn, run, :read, fn repo_id, _principal -> Factory.events(repo_id, run, after_revision) end)

      {:error, message} ->
        error(conn, 422, "code: #{message}")
    end
  end

  get "/:run/attempts/:attempt" do
    with_run(conn, run, :read, fn repo_id, _principal -> Factory.attempt(repo_id, run, attempt) end)
  end

  post "/:run/claim" do
    with_run(conn, run, :execute, fn repo_id, principal ->
      Factory.claim(repo_id, run, conn.body_params["executor"], principal)
    end)
  end

  post "/:run/nodes/:node/complete" do
    with_run(conn, run, :execute, fn repo_id, principal ->
      Factory.complete(
        repo_id,
        run,
        node,
        conn.body_params["attempt"],
        conn.body_params["outcome"],
        conn.body_params["artifacts"] || [],
        principal
      )
    end)
  end

  post "/:run/nodes/:node/approve" do
    with_run(conn, run, :admin, fn repo_id, principal -> Factory.approve(repo_id, run, node, principal) end)
  end

  post "/:run/nodes/:node/expire" do
    with_run(conn, run, :admin, fn repo_id, _principal -> Factory.expire(repo_id, run, node) end)
  end

  post "/:run/cancel" do
    with_run(conn, run, :admin, fn repo_id, principal -> Factory.cancel(repo_id, run, principal) end)
  end

  get "/:run" do
    with_run(conn, run, :read, fn repo_id, _principal -> Factory.get(repo_id, run) end)
  end

  match _ do
    error(conn, 404, "code: endpoint not found")
  end

  defp with_run(conn, _run, permission, fun, status \\ 200) do
    with {:ok, repo_id, conn} <- repository(conn),
         {:ok, conn} <- AuthPlug.authorize(conn, repo_id, permission) do
      respond(conn, fun.(repo_id, conn.assigns.principal), status)
    else
      {:halt, conn} -> conn
      {:error, conn} -> conn
    end
  end

  defp with_authorized(conn, permission, fun, status \\ 200) do
    with {:ok, repo_id, conn} <- repository(conn),
         {:ok, conn} <- AuthPlug.authorize(conn, repo_id, permission) do
      respond(conn, fun.(repo_id, conn.assigns.principal), status)
    else
      {:halt, conn} -> conn
      {:error, conn} -> conn
    end
  end

  defp repository(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params["repository"] do
      repo_id when is_binary(repo_id) and byte_size(repo_id) > 0 -> {:ok, repo_id, conn}
      _ -> {:error, error(conn, 422, "repository query parameter is required")}
    end
  end

  defp after_revision(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params["after"] do
      nil ->
        {:ok, 0}

      raw ->
        case Integer.parse(raw) do
          {value, ""} when value >= 0 -> {:ok, value}
          _ -> {:error, "after must be a non-negative integer"}
        end
    end
  end

  defp respond(conn, result, status), do: ServiceResponse.send_result(conn, result, status)

  defp error(conn, status, message), do: ServiceResponse.error(conn, status, message)
end
