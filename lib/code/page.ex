defmodule Code.Page do
  @moduledoc """
  Cursor pagination options shared by the forge's list operations.

  A list call without `:limit` or `:cursor` keeps its historical behaviour and
  returns everything, so existing clients see no change. Supplying either one
  pages the result: at most `:limit` items (default 100, maximum 500),
  starting after `:cursor`, with a `next_cursor` to pass back for the next
  page, or `nil` when there is none.
  """

  @default_limit 100
  @max_limit 500

  @type t :: :all | %{limit: pos_integer(), cursor: term()}

  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc """
  Validate `:limit` and `:cursor` from `opts`. `cursor_valid?` decides what a
  cursor looks like for the collection being paged.
  """
  @spec options(keyword(), (term() -> boolean())) :: {:ok, t()} | {:error, String.t()}
  def options(opts, cursor_valid?) do
    case {Keyword.get(opts, :limit), Keyword.get(opts, :cursor)} do
      {nil, nil} ->
        {:ok, :all}

      {limit, cursor} ->
        with :ok <- validate_limit(limit),
             :ok <- validate_cursor(cursor, cursor_valid?) do
          {:ok, %{limit: limit || @default_limit, cursor: cursor}}
        end
    end
  end

  @doc "Validate an optional page size."
  @spec validate_limit(term()) :: :ok | {:error, String.t()}
  def validate_limit(nil), do: :ok
  def validate_limit(limit) when is_integer(limit) and limit in 1..@max_limit, do: :ok
  def validate_limit(_limit), do: {:error, limit_error()}

  defp validate_cursor(nil, _cursor_valid?), do: :ok

  defp validate_cursor(cursor, cursor_valid?),
    do: if(cursor_valid?.(cursor), do: :ok, else: {:error, "cursor is invalid"})

  @spec limit_error() :: String.t()
  def limit_error, do: "limit must be an integer between 1 and #{@max_limit}"
end
