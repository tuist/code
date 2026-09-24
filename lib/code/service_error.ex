defmodule Code.ServiceError do
  @moduledoc """
  A typed failure from a forge service (issues, work runs, account
  configuration), so transports map it to a status by its kind rather than by
  matching words in its message.

  | Kind | Meaning | HTTP |
  |---|---|---|
  | `:invalid` | The request itself is malformed or names something unusable | `422` |
  | `:not_found` | The repository, issue, run, node, attempt or record does not exist | `404` |
  | `:conflict` | The request conflicts with the current durable state; re-read before retrying | `409` |
  | `:unavailable` | A temporary failure (storage, writer overload, exhausted optimistic retries); the same request may succeed later | `503` |

  Validation helpers deep inside a service still return a bare message
  string. `normalize/1` treats such a string as `:invalid` at the service
  boundary, so only the failures that mean something else need tagging.
  """

  defexception [:kind, :message]

  @type kind :: :invalid | :not_found | :conflict | :unavailable
  @type t :: %__MODULE__{kind: kind(), message: String.t()}

  @doc "Seconds a client should wait before retrying an `:unavailable` failure."
  @spec retry_after_seconds() :: pos_integer()
  def retry_after_seconds, do: 1

  @spec invalid(String.t()) :: t()
  def invalid(message), do: %__MODULE__{kind: :invalid, message: message}

  @spec not_found(String.t()) :: t()
  def not_found(message), do: %__MODULE__{kind: :not_found, message: message}

  @spec conflict(String.t()) :: t()
  def conflict(message), do: %__MODULE__{kind: :conflict, message: message}

  @spec unavailable(String.t()) :: t()
  def unavailable(message), do: %__MODULE__{kind: :unavailable, message: message}

  @doc """
  Normalize a service result at its boundary. A typed error passes through, a
  bare message is a validation failure, and any other reason is an internal
  temporary failure described by `inspect/1`.
  """
  @spec normalize(term()) :: term()
  def normalize({:error, %__MODULE__{}} = error), do: error
  def normalize({:error, message}) when is_binary(message), do: {:error, invalid(message)}
  def normalize({:error, reason}), do: {:error, unavailable(inspect(reason))}
  def normalize(result), do: result

  @doc "The Hypertext Transfer Protocol status for an error."
  @spec http_status(t()) :: 404 | 409 | 422 | 503
  def http_status(%__MODULE__{kind: :not_found}), do: 404
  def http_status(%__MODULE__{kind: :conflict}), do: 409
  def http_status(%__MODULE__{kind: :unavailable}), do: 503
  def http_status(%__MODULE__{kind: :invalid}), do: 422

  @doc "Whether repeating the same request later may succeed."
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{kind: kind}), do: kind == :unavailable

  defimpl String.Chars do
    def to_string(%{message: message}), do: message
  end
end
