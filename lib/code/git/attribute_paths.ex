defmodule Code.Git.AttributePaths do
  @moduledoc false
  # Cache installation/environment discovery only, not file contents or Git
  # configuration. Every native search still checks the discovered paths.
  # One slot bounds memory even if the executable/environment changes.
  @cache {__MODULE__, :paths}

  def cached do
    fingerprint = fingerprint()

    case :persistent_term.get(@cache, nil) do
      {^fingerprint, paths} when not is_nil(fingerprint) -> paths
      _ -> []
    end
  end

  def discover(repo, timeout) do
    fingerprint = fingerprint()

    with false <- is_nil(fingerprint),
         {:ok, output} <- Code.Git.run(repo, ["var", "-l"], timeout: timeout),
         parsed <- parse(output) do
      value =
        case parsed do
          {:ok, paths} -> paths
          :fallback_git -> :fallback_git
        end

      :persistent_term.put(@cache, {fingerprint, value})
      parsed
    else
      _ -> :fallback_git
    end
  end

  defp parse(output) do
    values =
      output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, ["GIT_ATTR_SYSTEM=", "GIT_ATTR_GLOBAL="]))

    paths = Enum.map(values, fn value -> value |> String.split("=", parts: 2) |> List.last() end)

    if length(paths) == 2 and Enum.all?(paths, &(Path.type(&1) == :absolute and byte_size(&1) <= 4096)),
      do: {:ok, paths},
      else: :fallback_git
  end

  defp fingerprint do
    with executable when is_binary(executable) <- Code.Git.executable(),
         {:ok, stat} <- File.stat(executable, time: :posix) do
      {executable, stat.inode, stat.size, stat.mtime, stat.ctime, System.tmp_dir!(),
       Enum.map(
         ~w(PATH HOME XDG_CONFIG_HOME GIT_EXEC_PATH GIT_ATTR_NOSYSTEM GIT_ATTR_SOURCE),
         &System.get_env/1
       )}
    else
      _ -> nil
    end
  end
end
