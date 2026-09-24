defmodule Code.Telemetry.InFlightTest do
  @moduledoc """
  The autoscaling signal counts Git protocol requests and nothing else, and
  every request it counts is uncounted exactly once.

  The node-wide counter is shared with every concurrently running test, so
  these assert the classification and the per-process bookkeeping rather than
  absolute counts.
  """

  use ExUnit.Case, async: true

  alias Code.Telemetry.InFlight

  defp meta(plug, path), do: %{plug: {plug, []}, conn: Plug.Test.conn("GET", path)}

  test "counts Git smart-HTTP requests on the public listener" do
    assert InFlight.git_request?(meta(Code.HTTP.Router, "/acme/app.git/info/refs"))
    assert InFlight.git_request?(meta(Code.HTTP.Router, "/acme/ios/app/git-upload-pack"))
    assert InFlight.git_request?(meta(Code.HTTP.Router, "/acme/app/git-receive-pack"))
  end

  test "ignores admin, hook, MCP and API traffic" do
    refute InFlight.git_request?(meta(Code.HTTP.AdminRouter, "/metrics"))
    refute InFlight.git_request?(meta(Code.HTTP.AdminRouter, "/ready"))
    refute InFlight.git_request?(meta(Code.HTTP.HookRouter, "/acme/app/git-receive-pack"))
    refute InFlight.git_request?(meta(Code.HTTP.Router, "/mcp"))
    refute InFlight.git_request?(meta(Code.HTTP.Router, "/api/issues/acme/app"))
    refute InFlight.git_request?(meta(Code.HTTP.Router, "/.well-known/oauth-protected-resource"))
    refute InFlight.git_request?(meta(Code.HTTP.Router, "/health"))
    refute InFlight.git_request?(%{plug: {Code.HTTP.Router, []}})
  end

  test "a counted request is released once, however it ends" do
    git = meta(Code.HTTP.Router, "/acme/app/git-upload-pack")

    InFlight.handle_event([:bandit, :request, :start], %{}, git, nil)
    assert Process.get({InFlight, :counted})

    InFlight.handle_event([:bandit, :request, :exception], %{}, git, nil)
    refute Process.get({InFlight, :counted})

    # A later stop for the same request, or one for a request never counted,
    # must not decrement again.
    InFlight.handle_event([:bandit, :request, :stop], %{}, git, nil)
    refute Process.get({InFlight, :counted})
  end

  test "an uncounted request leaves no bookkeeping behind" do
    InFlight.handle_event([:bandit, :request, :start], %{}, meta(Code.HTTP.AdminRouter, "/metrics"), nil)
    refute Process.get({InFlight, :counted})
  end
end
