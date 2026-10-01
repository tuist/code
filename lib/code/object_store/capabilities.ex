defmodule Code.ObjectStore.Capabilities do
  @moduledoc "Runtime proofs of object-store semantics required by recovery."
  alias Code.ObjectStore

  @spec verify_conditional_deletes() :: :ok | {:error, term()}
  def verify_conditional_deletes do
    key = "probes/conditional-delete-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    with {:ok, original} <- ObjectStore.put(key, "first", if_none_match: "*"),
         {:ok, replacement} <- ObjectStore.put(key, "replacement", if_match: original) do
      try do
        with {:error, :precondition_failed} <- ObjectStore.delete_if_match(key, original),
             {:ok, "replacement", ^replacement} <- ObjectStore.get(key, []),
             :ok <- ObjectStore.delete_if_match(key, replacement),
             {:error, :not_found} <- ObjectStore.get(key, []) do
          :ok
        else
          _ -> {:error, :conditional_delete_unsupported}
        end
      after
        ObjectStore.delete_if_match(key, replacement)
      end
    end
  end
end
