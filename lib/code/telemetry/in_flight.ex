defmodule Code.Telemetry.InFlight do
  @moduledoc """
  Counts Git protocol requests currently being served.

  This is the number that matters for scaling a Git server. A clone occupies a
  connection, a process and a `git upload-pack` for its whole duration, which
  can be minutes; CPU stays unremarkable while the node runs out of capacity to
  accept anything else. Scaling on CPU alone therefore reacts far too late.

  Only Git smart-HTTP requests on the public listener count: reference
  advertisement (`/info/refs`), `git-upload-pack` and `git-receive-pack`.
  Admin probes and metric scrapes arrive every few seconds on every pod, and
  MCP, API and hook callbacks are short; counting them would make the
  autoscaling signal track the scraper rather than the clones.

  Implemented with `:counters` rather than a process, so incrementing it on
  every request costs an atomic add and can never become a bottleneck or a
  single point of failure. Whether a request was counted is remembered in the
  handling process, so its end is matched against its start exactly once
  however the request finishes.
  """

  @key {__MODULE__, :counter}
  @counted {__MODULE__, :counted}

  @doc "Attach to Bandit's request lifecycle. Safe to call more than once."
  @spec attach() :: :ok
  def attach do
    :persistent_term.put(@key, :counters.new(1, [:write_concurrency]))

    :telemetry.detach("code-in-flight")

    :telemetry.attach_many(
      "code-in-flight",
      [
        [:bandit, :request, :start],
        [:bandit, :request, :stop],
        [:bandit, :request, :exception]
      ],
      &__MODULE__.handle_event/4,
      nil
    )

    :ok
  end

  @doc false
  def handle_event([:bandit, :request, :start], _measurements, meta, _config) do
    if git_request?(meta) do
      Process.put(@counted, true)
      add(1)
    end

    :ok
  end

  def handle_event([:bandit, :request, event], _measurements, _meta, _config)
      when event in [:stop, :exception] do
    if Process.delete(@counted), do: add(-1)
    :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @doc """
  Whether a request is Git protocol traffic on the public listener.

  Decided from the path alone, before routing, because the start of a request
  is the only moment the count can be incremented.
  """
  @spec git_request?(map()) :: boolean()
  def git_request?(%{plug: {Code.HTTP.Router, _opts}, conn: %Plug.Conn{path_info: path}}), do: git_path?(path)
  def git_request?(_meta), do: false

  defp git_path?([reserved | _]) when reserved in ["mcp", "api", ".well-known"], do: false

  defp git_path?(path) do
    case Enum.reverse(path) do
      ["refs", "info", _repo | _] -> true
      [service, _repo | _] when service in ["git-upload-pack", "git-receive-pack"] -> true
      _ -> false
    end
  end

  @doc "Git protocol requests currently in flight on this node."
  @spec count() :: non_neg_integer()
  def count do
    case :persistent_term.get(@key, nil) do
      nil -> 0
      counter -> max(:counters.get(counter, 1), 0)
    end
  end

  defp add(delta) do
    case :persistent_term.get(@key, nil) do
      nil -> :ok
      counter -> :counters.add(counter, 1, delta)
    end
  end
end
