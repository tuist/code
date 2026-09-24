defmodule Code.Telemetry.DiskUsageTest do
  @moduledoc """
  Disk usage is measured in the background and at most once per interval, so
  the metrics poller never walks the cache itself.
  """

  use ExUnit.Case, async: true

  alias Code.Telemetry.DiskUsage

  @moduletag :tmp_dir

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  test "measures regular files under the directory", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "a/b"))
    File.write!(Path.join(dir, "a/b/one"), String.duplicate("x", 100))
    File.write!(Path.join(dir, ".hidden"), String.duplicate("x", 20))

    assert DiskUsage.measure(dir) == 120
  end

  test "answers from the cache at once, and refreshes it in the background", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "pack"), String.duplicate("x", 64))
    state = DiskUsage.new()

    # The first read starts a measurement and returns without waiting for it.
    assert DiskUsage.bytes(state, dir, :timer.hours(1)) == 0
    eventually(fn -> DiskUsage.bytes(state, dir, :timer.hours(1)) == 64 end)

    # Inside the refresh interval, growth is not re-measured.
    File.write!(Path.join(dir, "another"), String.duplicate("x", 36))
    Process.sleep(20)
    assert DiskUsage.bytes(state, dir, :timer.hours(1)) == 64

    # Once the interval has passed, it is.
    eventually(fn -> DiskUsage.bytes(state, dir, 0) == 100 end)
  end
end
