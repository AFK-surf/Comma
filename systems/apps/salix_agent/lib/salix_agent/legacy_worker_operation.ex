defmodule SalixAgent.LegacyWorkerOperation do
  @moduledoc """
  Finish already accepted Compute placement operations; never accepts new ones.
  Preserves the existing reservation format and collision/claim semantics in
  tla/salix/ExternalWorkerProvisioning.tla. Remove after these obligations drain.
  """
  alias SalixAgent.AgentControl
  alias SalixStore.{Compute, Ids, Keys, RuntimeIds, S3}

  def finish(%Compute.ExternalWorkerOperation{state: "placement_ready"} = operation) do
    with {:ok, agent_id} <- worker(operation, 5),
         {:ok, _} <-
           Compute.complete_external_worker_operation(
             operation.id,
             agent_id,
             operation.claim_token
           ) do
      {:ok, agent_id}
    end
  rescue
    error -> {:error, {:worker_creation_failed, Exception.message(error)}}
  end

  def finish(%Compute.ExternalWorkerOperation{state: "worker_ready"}),
    do: {:ok, :already_complete}

  def finish(_), do: {:error, :placement_pending}

  defp worker(_, 0), do: raise("agent.create_worker id collision")

  defp worker(operation, attempts) do
    with {:ok, reservation} <- reservation(operation) do
      result =
        case AgentControl.get(reservation.agent_id, operation.tenant_id) do
          {:error, :not_found} ->
            AgentControl.create_preallocated(
              %{
                "group_id" => operation.group_id,
                "role" => "worker",
                "name" => "External compute worker " <> operation.tool_call_id,
                "source_worker_tool_idempotency_hash" => operation.operation_hash,
                "runtime_config" => %{
                  "kind" => "compute_workload",
                  "workload_id" => operation.workload_id,
                  "runtime_spec" => %{"provider" => operation.provider}
                }
              },
              operation.tenant_id,
              reservation.agent_id
            )

          result ->
            result
        end

      with {:ok, record} <- result do
        if reserved_worker?(record, operation) do
          with {:ok, owned} <-
                 AgentControl.claim_configuration(record["agent_id"], operation.tenant_id),
               do: {:ok, owned["agent_id"]}
        else
          with :ok <- rotate(reservation, operation), do: worker(operation, attempts - 1)
        end
      end
    end
  end

  defp reservation(operation) do
    key = Keys.ctl_agent_worker_tool_idempotency(operation.group_id, operation.operation_hash)

    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        with {:ok, record} <- Jason.decode(body),
             true <-
               record["group_id"] == operation.group_id and record["worker_type"] == "external" and
                 record["idempotency_hash"] == operation.operation_hash and
                 Ids.valid_agent_id_for_group?(record["agent_id"], operation.group_id) do
          {:ok, %{agent_id: record["agent_id"], key: key, etag: etag}}
        else
          _ -> {:error, :invalid_worker_idempotency_reservation}
        end

      {:error, :not_found} ->
        record = reservation_record(operation)

        case S3.put(key, Jason.encode!(record), if_none_match: "*") do
          {:ok, %{etag: etag}} -> {:ok, %{agent_id: record["agent_id"], key: key, etag: etag}}
          {:ok, _} -> reservation(operation)
          {:error, :precondition_failed} -> reservation(operation)
          {:error, {:ambiguous, _}} -> reservation(operation)
          error -> error
        end

      error ->
        error
    end
  end

  defp rotate(reservation, operation) do
    case S3.put(reservation.key, Jason.encode!(reservation_record(operation)),
           if_match: reservation.etag
         ) do
      {:ok, _} -> :ok
      {:error, :precondition_failed} -> :ok
      {:error, {:ambiguous, _}} -> :ok
      error -> error
    end
  end

  defp reservation_record(operation) do
    %{
      "agent_id" => Ids.new_agent_id(operation.group_id),
      "group_id" => operation.group_id,
      "worker_type" => "external",
      "idempotency_hash" => operation.operation_hash,
      "created_at" => System.system_time(:second)
    }
  end

  defp reserved_worker?(record, operation) do
    runtime = record["runtime_config"] || %{}

    record["group_id"] == operation.group_id and record["role"] == "worker" and
      record["source_worker_tool_idempotency_hash"] == operation.operation_hash and
      (runtime["kind"] == "compute_workload" or
         (runtime["kind"] == "external" and
            RuntimeIds.external_runtime_provider?(runtime["provider"])))
  end
end
