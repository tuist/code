defmodule Code.PromEx do
  @moduledoc """
  Prometheus metrics.

  Exposed at `/metrics` on the admin listener, which keeps it off the public
  port without needing a second process.

  These metrics are not only for dashboards. `code_git_requests_in_flight` is
  the signal the chart's HorizontalPodAutoscaler scales on, and
  `code_wal_read_duration` (in seconds, by outcome) shows how much catch-up the
  read path is doing: Git serving is bound by concurrent streams and by that
  catch-up, neither of which shows up cleanly in CPU until the node is already
  struggling.

  Duration names follow the metric definitions exactly; only the HTTP and
  object-store durations carry a `_seconds` suffix. `Code.PromExTest` pins the
  exported names against a real scrape.
  """

  use PromEx, otp_app: :code

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      Plugins.Application,
      Plugins.Beam,
      Code.PromEx.Plugin
    ]
  end

  @impl true
  def dashboard_assigns do
    [datasource_id: "prometheus", default_selected_interval: "30s"]
  end

  @impl true
  def dashboards, do: []
end
