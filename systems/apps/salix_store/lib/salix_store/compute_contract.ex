defmodule SalixStore.ComputeContract do
  @moduledoc """
  Provider-neutral contracts shared by Compute, local projections, and clients.

  This module is a pure contract boundary. `SalixStore.Compute` remains the
  authority for persisted Node/Workload facts; this module only validates the
  small public vocabulary and derives user-facing results from observations.
  """

  @node_results ~w(not_set processing ready stopped action_required removed)
  @operation_outcomes ~w(pending succeeded failed unknown)
  @workload_kinds ~w(shell external_worker meeting_runtime service)
  @capabilities ~w(runtime_exec runtime_process service_private service_public_http)

  @type node_result :: String.t()
  @type operation_outcome :: String.t()

  def node_results, do: @node_results
  def operation_outcomes, do: @operation_outcomes
  def workload_kinds, do: @workload_kinds
  def capabilities, do: @capabilities

  @doc "Derive one of the six user results without turning unreadability into absence."
  @spec node_result(map()) :: node_result()
  def node_result(observation) when is_map(observation) do
    cond do
      value(observation, :readable, true) != true -> "action_required"
      value(observation, :removed, false) -> "removed"
      value(observation, :operation_outcome) == "pending" -> "processing"
      ready?(observation) -> "ready"
      value(observation, :desired) == "absent" and not installed?(observation) -> "not_set"
      value(observation, :desired) == "absent" -> "stopped"
      value(observation, :runtime) == "stopped" -> "stopped"
      value(observation, :desired) == "present" -> "action_required"
      true -> "not_set"
    end
  end

  def node_result(_), do: "action_required"

  @doc "Ready requires every independent observation and the current admission fence."
  @spec ready?(map()) :: boolean()
  def ready?(observation) when is_map(observation) do
    value(observation, :readable, true) == true and
      value(observation, :desired) == "present" and
      value(observation, :removed, false) == false and
      value(observation, :artifact_verified, false) == true and
      value(observation, :host_healthy, false) == true and
      value(observation, :controller_current, false) == true and
      value(observation, :registration_active, false) == true and
      value(observation, :admission) == "accepting"
  end

  def ready?(_), do: false

  @doc "Validate the typed operation correlation contract used by each authority."
  @spec operation(map()) :: {:ok, map()} | {:error, atom()}
  def operation(attrs) when is_map(attrs) do
    with {:ok, operation_id} <- required_string(attrs, :operation_id),
         {:ok, request_id} <- required_string(attrs, :request_id),
         {:ok, target_ref} <- required_string(attrs, :target_ref),
         {:ok, target_revision_or_generation} <-
           positive_integer(attrs, :target_revision_or_generation),
         {:ok, connection_epoch} <- epoch(attrs[:connection_epoch] || attrs["connection_epoch"]),
         {:ok, outcome} <- outcome(attrs[:outcome] || attrs["outcome"]) do
      {:ok,
       %{
         operation_id: operation_id,
         request_id: request_id,
         target_ref: target_ref,
         target_revision_or_generation: target_revision_or_generation,
         connection_epoch: connection_epoch,
         outcome: outcome
       }}
    end
  end

  def operation(_), do: {:error, :invalid_operation}

  @doc "Validate the final Workload kind/capability vocabulary at the provider boundary."
  def validate_workload(kind, capabilities)
      when kind in @workload_kinds and is_list(capabilities) do
    if Enum.all?(capabilities, &(&1 in @capabilities)) and
         length(capabilities) == length(Enum.uniq(capabilities)) do
      :ok
    else
      {:error, :invalid_capability}
    end
  end

  def validate_workload(_, _), do: {:error, :invalid_workload}

  @doc "Project a Node while retaining last-known observation and explicit readability."
  def project_node(observation) when is_map(observation) do
    %{
      result: node_result(observation),
      readable: value(observation, :readable, true),
      last_known: value(observation, :last_known),
      desired: value(observation, :desired),
      ready: ready?(observation),
      facets: %{
        installation: value(observation, :installation, "unreadable"),
        runtime: value(observation, :runtime, "unknown"),
        controller: value(observation, :controller, "unknown"),
        admission: value(observation, :admission, "closed")
      }
    }
  end

  @doc "Project a Workload without exposing provider-native identity."
  def project_workload(observation) when is_map(observation) do
    %{
      id: value(observation, :id),
      kind: value(observation, :kind),
      desired: value(observation, :desired),
      generation: value(observation, :generation),
      observed: value(observation, :observed, "unknown"),
      runtime_ready: value(observation, :runtime_ready, false),
      work_activity: value(observation, :work_activity, "unknown")
    }
  end

  defp installed?(observation),
    do: value(observation, :installation) in ["verified", "unreadable"]

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp required_string(map, key) do
    case value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp positive_integer(map, key) do
    case value(map, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid, key}}
    end
  end

  defp epoch(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, value}
      _ -> {:error, {:invalid, :connection_epoch}}
    end
  end

  defp epoch(_), do: {:error, {:invalid, :connection_epoch}}

  defp outcome(value) when value in @operation_outcomes, do: {:ok, value}
  defp outcome(:unknown_outcome), do: {:ok, "unknown"}
  defp outcome("unknown_outcome"), do: {:ok, "unknown"}
  defp outcome(_), do: {:error, {:invalid, :outcome}}
end
