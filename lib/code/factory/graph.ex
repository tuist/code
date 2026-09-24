defmodule Code.Factory.Graph do
  @moduledoc """
  Validation and initial state for a work run's dependency graph.

  Pure functions over the submitted graph: node shape, supported kinds, the
  optional Condukt execution contract, unique ids, known dependencies and the
  absence of cycles. Nothing here touches storage; `Code.Factory` persists
  the normalized graph in the run's immutable specification.
  """

  import Code.Factory.Shared, only: [maybe_put: 3, valid_identifier?: 1]

  @type node_id :: String.t()
  @type dependency_graph :: %{optional(node_id()) => [node_id()]}
  @type visited_nodes :: %{optional(node_id()) => true}

  @doc "Validate a work graph and return its normalized nodes, in the order given."
  @spec normalize(term()) :: {:ok, [map()]} | {:error, String.t()}
  def normalize(%{"nodes" => nodes}), do: normalize_nodes(nodes)
  def normalize(%{nodes: nodes}), do: normalize_nodes(nodes)
  def normalize(_), do: {:error, "work graph must contain a nodes array"}

  defp normalize_nodes(nodes) when is_list(nodes) and nodes != [] do
    with {:ok, nodes} <- Enum.reduce_while(nodes, {:ok, []}, &normalize_node/2),
         :ok <- unique_node_ids(nodes),
         :ok <- known_dependencies(nodes),
         :ok <- acyclic(nodes) do
      {:ok, nodes}
    end
  end

  defp normalize_nodes(_), do: {:error, "work graph nodes must be a non-empty array"}

  defp normalize_node(raw, {:ok, acc}) when is_map(raw) do
    id = raw["id"] || raw[:id]
    kind = raw["kind"] || raw[:kind] || "agent"
    title = raw["title"] || raw[:title] || id
    depends_on = raw["depends_on"] || raw[:depends_on] || []
    execution = raw["execution"] || raw[:execution]

    with :ok <- node_id_valid?(id),
         :ok <- node_kind_valid?(kind),
         :ok <- node_title_valid?(title),
         :ok <- dependencies_valid?(id, depends_on),
         {:ok, execution} <- normalize_node_execution(id, execution) do
      node =
        %{"id" => id, "kind" => kind, "title" => title, "depends_on" => depends_on}
        |> maybe_put("execution", execution)

      {:cont, {:ok, acc ++ [node]}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp normalize_node(_raw, _acc), do: {:halt, {:error, "every work node must be an object"}}

  defp node_id_valid?(id),
    do: if(valid_identifier?(id), do: :ok, else: {:error, "every work node needs a simple id"})

  defp node_kind_valid?(kind) when kind in ["agent", "command", "evaluate", "approval"], do: :ok
  defp node_kind_valid?(kind), do: {:error, "unknown work node kind #{inspect(kind)}"}

  defp node_title_valid?(title) when is_binary(title) and title != "", do: :ok
  defp node_title_valid?(_title), do: {:error, "every work node needs a title"}

  defp dependencies_valid?(id, dependencies) when is_list(dependencies) do
    if Enum.all?(dependencies, &valid_identifier?/1),
      do: :ok,
      else: {:error, "node #{id} has invalid dependencies"}
  end

  defp dependencies_valid?(id, _dependencies), do: {:error, "node #{id} has invalid dependencies"}

  defp normalize_node_execution(id, execution) do
    case normalize_execution(execution) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, "node #{id} #{reason}"}
    end
  end

  # The factory carries a portable operation contract, not an agent session,
  # provider credential, or model selection. A worker maps `operation` to a
  # locally configured Condukt operation and creates the session inside its
  # sandbox. The same contract therefore works with a mocked worker in tests.
  defp normalize_execution(nil), do: {:ok, nil}

  defp normalize_execution(raw) when is_map(raw) do
    type = raw["type"] || raw[:type]
    operation = raw["operation"] || raw[:operation]
    input = raw["input"] || raw[:input] || %{}
    output_schema = raw["output_schema"] || raw[:output_schema]
    inference_profile = raw["inference_profile"] || raw[:inference_profile]

    with :ok <- execution_type_valid?(type),
         :ok <- execution_operation_valid?(operation),
         :ok <- execution_input_valid?(input),
         :ok <- optional_output_schema_valid?(output_schema),
         :ok <- optional_inference_profile_valid?(inference_profile) do
      {:ok,
       %{"type" => type, "operation" => operation, "input" => input}
       |> maybe_put("output_schema", output_schema)
       |> maybe_put("inference_profile", inference_profile)}
    end
  end

  defp normalize_execution(_), do: {:error, "has an execution that is not an object"}

  defp execution_type_valid?("condukt_operation"), do: :ok
  defp execution_type_valid?(_type), do: {:error, "has an unknown execution type"}

  defp execution_operation_valid?(operation) do
    if valid_operation?(operation), do: :ok, else: {:error, "needs a Condukt operation name"}
  end

  defp execution_input_valid?(input) when is_map(input), do: :ok
  defp execution_input_valid?(_input), do: {:error, "has a Condukt operation input that is not an object"}

  defp optional_output_schema_valid?(nil), do: :ok
  defp optional_output_schema_valid?(value) when is_map(value), do: :ok

  defp optional_output_schema_valid?(_value),
    do: {:error, "has a Condukt operation output schema that is not an object"}

  defp optional_inference_profile_valid?(nil), do: :ok

  defp optional_inference_profile_valid?(value) do
    if valid_identifier?(value), do: :ok, else: {:error, "has an invalid inference profile name"}
  end

  defp unique_node_ids(nodes) do
    if length(nodes) == length(Enum.uniq_by(nodes, & &1["id"])),
      do: :ok,
      else: {:error, "work node ids must be unique"}
  end

  defp known_dependencies(nodes) do
    ids = MapSet.new(nodes, & &1["id"])

    if Enum.all?(nodes, fn node -> Enum.all?(node["depends_on"], &MapSet.member?(ids, &1)) end),
      do: :ok,
      else: {:error, "every work-node dependency must exist"}
  end

  @spec acyclic([map()]) :: :ok | {:error, String.t()}
  defp acyclic(nodes) do
    graph = dependency_graph(nodes)

    case Enum.reduce_while(Map.keys(graph), %{}, fn id, done ->
           case visit(id, graph, done, %{}) do
             {:ok, done} -> {:cont, done}
             :cycle -> {:halt, :cycle}
           end
         end) do
      :cycle -> {:error, "work graph must not contain a cycle"}
      _ -> :ok
    end
  end

  @spec dependency_graph([map()]) :: dependency_graph()
  defp dependency_graph(nodes), do: Map.new(nodes, &{&1["id"], &1["depends_on"]})

  @spec visit(node_id(), dependency_graph(), visited_nodes(), visited_nodes()) ::
          {:ok, visited_nodes()} | :cycle
  defp visit(id, graph, done, visiting) do
    cond do
      Map.has_key?(done, id) ->
        {:ok, done}

      Map.has_key?(visiting, id) ->
        :cycle

      true ->
        visiting = Map.put(visiting, id, true)

        Enum.reduce_while(Map.fetch!(graph, id), {:ok, done}, fn dependency, {:ok, done} ->
          case visit(dependency, graph, done, visiting) do
            {:ok, next} -> {:cont, {:ok, next}}
            :cycle -> {:halt, :cycle}
          end
        end)
        |> case do
          {:ok, done} -> {:ok, Map.put(done, id, true)}
          :cycle -> :cycle
        end
    end
  end

  @doc "The initial state of every node: ready or waiting without dependencies, otherwise pending."
  @spec initial_nodes([map()]) :: %{optional(node_id()) => map()}
  def initial_nodes(nodes) do
    Map.new(nodes, fn node ->
      status =
        if node["depends_on"] == [] do
          if node["kind"] == "approval", do: "waiting", else: "ready"
        else
          "pending"
        end

      {node["id"], Map.merge(node, %{"status" => status, "attempts" => 0})}
    end)
  end

  defp valid_operation?(value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/, value)
end
