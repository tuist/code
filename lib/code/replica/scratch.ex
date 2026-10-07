defmodule Code.Replica.Scratch do
  @moduledoc false
  require Logger

  # Serial application startup only, before replicas or recovery workers exist.
  # Never run this against a live node's data directory.
  @spec sweep() :: :ok
  def sweep do
    Code.Telemetry.span("code.replica.scratch_sweep", %{}, fn ->
      started = System.monotonic_time(:microsecond)
      root = Code.Config.data_dir()

      names =
        case File.ls(root) do
          {:ok, names} ->
            names

          {:error, :enoent} ->
            []

          {:error, reason} ->
            Logger.warning("Could not list abandoned cache scratch",
              operation: :scratch_sweep,
              reason: reason
            )

            []
        end

      for name <- names,
          Regex.match?(~r/^(?:code-packs-[A-Za-z0-9_-]{12}|\.code-init-[A-Za-z0-9_-]{16})$/, name) do
        remove(Path.join(root, name))
      end

      :telemetry.execute(
        [:code, :replica, :scratch_sweep_duration],
        %{duration_us: System.monotonic_time(:microsecond) - started},
        %{}
      )

      :ok
    end)
  end

  defp remove(path) do
    # Refuse symlinks and non-directories, even with a reserved name.
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        result = File.rm_rf(path)
        outcome = if match?({:ok, _}, result), do: :ok, else: :error
        :telemetry.execute([:code, :replica, :scratch_sweep], %{count: 1}, %{outcome: outcome})

        if outcome == :error,
          do:
            Logger.warning("Could not remove abandoned cache scratch",
              operation: :scratch_sweep,
              path: path,
              reason: inspect(result)
            )

      _ ->
        :ok
    end
  end
end
