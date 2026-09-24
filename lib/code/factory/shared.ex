defmodule Code.Factory.Shared do
  @moduledoc false
  # Primitives the factory modules share: JSON objects in the object store,
  # identifiers, the recorded actor, and operation telemetry.
  #
  # Only the primitives live here. The order of conditional writes (which
  # immutable object is written before which mutable pointer) stays spelled
  # out in the module that owns it, because that ordering is the durability
  # argument and should be auditable where it is made.

  alias Code.Auth.Principal
  alias Code.ObjectStore
  alias Code.Telemetry

  @identifier ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/

  @doc "A path-safe identifier: alphanumeric first, then up to 127 of `[A-Za-z0-9_-]`."
  @spec valid_identifier?(term()) :: boolean()
  def valid_identifier?(value), do: is_binary(value) and Regex.match?(@identifier, value)

  @doc "The verified principal as it is recorded in factory objects."
  @spec actor(Principal.t()) :: map()
  def actor(%Principal{} = principal), do: %{"subject" => principal.subject, "account" => principal.account}

  # URL-safe base64 can begin with `-` or `_`, while factory ids intentionally
  # begin with an alphanumeric prefix so they are safe in every path form.
  @doc "A random identifier with a one-letter alphanumeric prefix."
  @spec identifier(String.t()) :: String.t()
  def identifier(prefix), do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @spec now() :: integer()
  def now, do: System.system_time(:millisecond)

  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Read and decode a JSON object. `label` names the object kind in errors."
  @spec read_json(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_json(key, label) do
    with {:ok, body, _etag} <- ObjectStore.get(key), do: decode(key, body, label)
  end

  @spec read_json_with_etag(String.t(), String.t()) :: {:ok, map(), ObjectStore.etag()} | {:error, term()}
  def read_json_with_etag(key, label) do
    with {:ok, body, etag} <- ObjectStore.get(key),
         {:ok, value} <- decode(key, body, label) do
      {:ok, value, etag}
    end
  end

  @spec decode(String.t(), binary(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def decode(key, body, label) do
    case JSON.decode(body) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, "malformed #{label} object #{key}"}
    end
  end

  @doc "Write an object that must never be replaced (`If-None-Match: *`)."
  @spec put_immutable(String.t(), map(), String.t()) :: {:ok, ObjectStore.etag()} | {:error, term()}
  def put_immutable(key, value, content_type),
    do: ObjectStore.put(key, JSON.encode!(value), if_none_match: "*", content_type: content_type)

  @doc """
  Run one factory operation inside a trace span and emit its bounded
  `[:code, :factory, :operation]` event. The operation name is a fixed atom,
  never a tenant-supplied value.
  """
  @spec observe(atom(), (-> result)) :: result when result: term()
  def observe(operation, fun) when is_atom(operation) do
    started_at = System.monotonic_time()

    result =
      Telemetry.span(
        "factory.#{operation}",
        %{"code.factory.operation" => Atom.to_string(operation)},
        fn -> fun.() |> Telemetry.put_span_outcome() end
      )

    :telemetry.execute(
      [:code, :factory, :operation],
      %{duration_us: System.convert_time_unit(System.monotonic_time() - started_at, :native, :microsecond)},
      %{operation: operation, outcome: outcome(result)}
    )

    result
  end

  defp outcome({:ok, _}), do: :ok
  defp outcome(_), do: :error
end
