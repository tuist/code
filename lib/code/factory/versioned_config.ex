defmodule Code.Factory.VersionedConfig do
  @moduledoc false
  # The storage contract shared by account secret backends and inference
  # profiles: every change writes a new immutable version, and one mutable
  # `current.json` pointer names the version that is current.
  #
  #     accounts/<account>/factory/<collection>/<name>/current.json
  #     accounts/<account>/factory/<collection>/<name>/versions/<version>.json
  #
  # `publish/5` is the only writer, and it writes in this order on purpose:
  # the immutable version first, then the pointer with a conditional write. A
  # losing writer may leave an unreferenced immutable version behind, but can
  # never replace a version something has already pinned.

  alias Code.Factory.Shared
  alias Code.ObjectStore
  alias Code.ServiceError

  @enforce_keys [:kind, :article, :short, :collection, :version_prefix, :content_type]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          kind: String.t(),
          article: String.t(),
          short: String.t(),
          collection: String.t(),
          version_prefix: String.t(),
          content_type: String.t()
        }

  @spec validate_account(term()) :: :ok | {:error, String.t()}
  def validate_account(value) do
    if Shared.valid_identifier?(value), do: :ok, else: {:error, "account is invalid"}
  end

  @spec validate_name(t(), term()) :: :ok | {:error, String.t()}
  def validate_name(%__MODULE__{} = spec, value) do
    if Shared.valid_identifier?(value), do: :ok, else: {:error, "#{spec.kind} name is invalid"}
  end

  @spec validate_version(t(), term()) :: :ok | {:error, String.t()}
  def validate_version(%__MODULE__{} = spec, value) when is_binary(value) do
    if Regex.match?(~r/^#{spec.version_prefix}[A-Za-z0-9_-]{16,127}$/, value),
      do: :ok,
      else: {:error, "#{spec.kind} version is invalid"}
  end

  def validate_version(%__MODULE__{} = spec, _value), do: {:error, "#{spec.kind} version is invalid"}

  @doc "Reject attributes outside `allowed`, so an unexpected secret-bearing field is never persisted."
  @spec validate_attributes(t(), map(), [String.t()]) :: :ok | {:error, String.t()}
  def validate_attributes(%__MODULE__{} = spec, attrs, allowed) do
    if Enum.all?(Map.keys(attrs), &(to_string(&1) in allowed)),
      do: :ok,
      else: {:error, "#{spec.kind} contains an unsupported field"}
  end

  @doc "The current pointer and its entity tag, or `{nil, nil}` when the name is unused."
  @spec current(t(), String.t(), String.t()) ::
          {:ok, map() | nil, ObjectStore.etag() | nil} | {:error, String.t()}
  def current(%__MODULE__{} = spec, account, name) do
    key = current_key(spec, account, name)

    case ObjectStore.get(key) do
      {:ok, body, etag} ->
        with {:ok, pointer} <- Shared.decode(key, body, spec.kind), do: {:ok, pointer, etag}

      {:error, :not_found} ->
        {:ok, nil, nil}

      {:error, reason} ->
        {:error, ServiceError.unavailable("could not read #{spec.kind}: #{inspect(reason)}")}
    end
  end

  @doc """
  Check the caller's `previous_version` against the current pointer. Creating
  needs none; replacing needs the version the caller last read.
  """
  @spec expected_version(t(), term(), map() | nil) :: :ok | {:error, String.t()}
  def expected_version(_spec, nil, nil), do: :ok

  def expected_version(%__MODULE__{} = spec, nil, _current),
    do: {:error, "previous_version is required to replace #{spec.article}"}

  def expected_version(%__MODULE__{} = spec, expected, current) when is_binary(expected) do
    with {:ok, actual} <- pointer_version(spec, current),
         true <- expected == actual do
      :ok
    else
      false -> {:error, ServiceError.conflict("#{spec.kind} changed concurrently")}
      {:error, _} -> {:error, ServiceError.unavailable("#{spec.kind} pointer is malformed")}
    end
  end

  def expected_version(%__MODULE__{} = spec, _expected, _current),
    do: {:error, "previous_version must be a #{spec.short} version"}

  @spec new_version(t()) :: String.t()
  def new_version(%__MODULE__{} = spec), do: Shared.identifier(spec.version_prefix)

  @doc """
  Publish `record` as a new immutable version and move the pointer to it.
  `etag` is the pointer's entity tag from `current/3`, or `nil` to create.
  """
  @spec publish(t(), String.t(), String.t(), map(), ObjectStore.etag() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def publish(%__MODULE__{} = spec, account, name, %{"version" => version} = record, etag) do
    with {:ok, _} <-
           Shared.put_immutable(version_key(spec, account, name, version), record, spec.content_type),
         {:ok, _} <- put_pointer(spec, account, name, version, etag) do
      {:ok, record}
    else
      {:error, :precondition_failed} ->
        {:error, ServiceError.conflict("#{spec.kind} changed concurrently")}

      {:error, reason} ->
        {:error, ServiceError.unavailable("could not store #{spec.kind}: #{inspect(reason)}")}
    end
  end

  @doc "Read the current version of one named record."
  @spec get(t(), term(), term()) :: {:ok, map()} | {:error, String.t()}
  def get(%__MODULE__{} = spec, account, name) do
    with :ok <- validate_account(account),
         :ok <- validate_name(spec, name),
         {:ok, pointer, _etag} <- Shared.read_json_with_etag(current_key(spec, account, name), spec.kind),
         {:ok, version} <- pointer_version(spec, pointer),
         {:ok, record} <- Shared.read_json(version_key(spec, account, name, version), spec.kind) do
      {:ok, record}
    else
      {:error, :not_found} -> {:error, ServiceError.not_found("#{spec.kind} #{name} not found")}
      {:error, reason} -> {:error, message(spec, reason)}
    end
  end

  @doc "Read one exact immutable version."
  @spec get_version(t(), term(), term(), term()) :: {:ok, map()} | {:error, String.t()}
  def get_version(%__MODULE__{} = spec, account, name, version) do
    with :ok <- validate_account(account),
         :ok <- validate_name(spec, name),
         :ok <- validate_version(spec, version),
         {:ok, record} <- Shared.read_json(version_key(spec, account, name, version), spec.kind) do
      {:ok, record}
    else
      {:error, :not_found} ->
        {:error, ServiceError.not_found("#{spec.kind} #{name} version #{version} not found")}

      {:error, reason} ->
        {:error, message(spec, reason)}
    end
  end

  @doc "Every current record in an account, by name. Historical versions are not enumerated."
  @spec list(t(), term()) :: {:ok, [map()]} | {:error, String.t()}
  def list(%__MODULE__{} = spec, account) do
    with :ok <- validate_account(account),
         {:ok, entries} <- ObjectStore.list(prefix(spec, account)) do
      entries
      |> Enum.filter(&String.ends_with?(&1.key, "/current.json"))
      |> Enum.map(&name_from_current_key/1)
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, records} ->
        case get(spec, account, name) do
          {:ok, record} -> {:cont, {:ok, [record | records]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        error -> error
      end
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, %ServiceError{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, ServiceError.unavailable("could not list #{spec.kind}s: #{inspect(reason)}")}
    end
  end

  defp put_pointer(spec, account, name, version, nil) do
    ObjectStore.put(current_key(spec, account, name), JSON.encode!(%{"version" => version}),
      if_none_match: "*",
      content_type: spec.content_type
    )
  end

  defp put_pointer(spec, account, name, version, etag) do
    ObjectStore.put(current_key(spec, account, name), JSON.encode!(%{"version" => version}),
      if_match: etag,
      content_type: spec.content_type
    )
  end

  defp pointer_version(spec, %{"version" => version}) do
    with :ok <- validate_version(spec, version), do: {:ok, version}
  end

  defp pointer_version(spec, _pointer),
    do: {:error, ServiceError.unavailable("#{spec.kind} pointer is malformed")}

  # A validation failure on the caller's input stays a plain message (and so
  # `:invalid`); anything that went wrong reading storage is temporary.
  defp message(_spec, reason) when is_binary(reason), do: reason
  defp message(_spec, %ServiceError{} = error), do: error
  defp message(spec, reason), do: ServiceError.unavailable("could not read #{spec.kind}: #{inspect(reason)}")

  defp prefix(spec, account), do: "accounts/#{account}/factory/#{spec.collection}/"
  defp record_prefix(spec, account, name), do: prefix(spec, account) <> name <> "/"
  defp current_key(spec, account, name), do: record_prefix(spec, account, name) <> "current.json"

  defp version_key(spec, account, name, version),
    do: record_prefix(spec, account, name) <> "versions/#{version}.json"

  defp name_from_current_key(%{key: key}) do
    key
    |> String.replace_suffix("/current.json", "")
    |> Path.basename()
  end
end
