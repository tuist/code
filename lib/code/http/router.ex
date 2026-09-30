defmodule Code.HTTP.Router do
  @moduledoc """
  The public listener: Git smart HTTP, MCP, and OAuth discovery on one port.

  They share a port because they share an identity model. A token that grants
  write on `acme/**` means the same thing whether it arrives on a `git push` or
  a `tools/call`, and putting them behind one ingress means one certificate,
  one hostname and one thing to reason about when granting access.

  Routing is by prefix, with Git last because repository ids are arbitrary
  paths and would otherwise swallow everything.
  """

  @behaviour Plug

  import Plug.Conn

  alias Code.HTTP.AuthPlug
  alias Code.HTTP.GitRouter
  alias Code.HTTP.MCPRouter
  alias Code.HTTP.WellKnownRouter

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Code.Telemetry.span(
      "code.http.public",
      %{
        "http.request.method" => conn.method
      },
      fn ->
        conn
        |> put_resp_header("x-code-node", Code.Config.node_id())
        |> route()
      end
    )
  end

  defp route(%{path_info: [".well-known" | rest]} = conn) do
    WellKnownRouter.call(%{conn | path_info: rest}, WellKnownRouter.init([]))
  end

  defp route(%{path_info: ["mcp" | _]} = conn) do
    conn
    |> AuthPlug.call([])
    |> MCPRouter.call(MCPRouter.init([]))
  end

  defp route(%{path_info: []} = conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, banner())
  end

  defp route(%{path_info: ["health"]} = conn), do: send_resp(conn, 200, "ok")

  defp route(conn) do
    conn
    |> AuthPlug.call([])
    |> GitRouter.call(GitRouter.init([]))
  end

  defp banner do
    """
    code #{Code.Application.version()} on #{Code.Config.node_id()}

    git:  git clone #{Code.Config.public_url()}/<account>/<repository>.git
    mcp:  POST #{Code.Config.public_url()}/mcp
    auth: #{Code.Config.public_url()}/.well-known/oauth-protected-resource
    """
  end
end
