defmodule SalixAgent.AgentManagement.Targets do
  @moduledoc false
  alias SalixAgent.AgentManagement.Ports
  alias SalixStore.{ExternalWorkerTargets, RuntimeIds}

  def resolve(_scope, %{"kind" => "internal"} = input) when map_size(input) == 1,
    do: {:ok, %{"kind" => "internal"}}

  def resolve(scope, %{"kind" => "connected", "device_runtime_id" => id} = input)
      when map_size(input) == 2 and is_binary(id) and id != "" do
    with {:ok, target} <- Ports.connected_target(id, scope),
         true <- RuntimeIds.external_runtime_provider?(target["provider"]) do
      {:ok,
       Map.take(target, ~w(provider device_id runtime_id device_runtime_id))
       |> Map.put("kind", "connected_runtime")
       |> Map.put("owner_scope", %{"type" => "group", "id" => scope.group_id})}
    else
      false -> {:error, :target_not_found}
      error -> error
    end
  end

  def resolve(
        scope,
        %{"kind" => "compute", "workload_id" => id, "selection_fence" => fence} = input
      )
      when map_size(input) == 3 and is_binary(id) and id != "" and is_map(fence) do
    with {:ok, project_id} <- Ports.project_id(scope),
         {:ok, target} <-
           ExternalWorkerTargets.select(scope.tenant_id, scope.group_id, project_id, id, fence) do
      {:ok,
       %{
         "kind" => "compute_workload",
         "workload_id" => id,
         "runtime_spec" => %{"provider" => target.provider},
         "owner_scope" => %{"type" => "project", "id" => project_id}
       }}
    else
      nil -> {:error, :target_not_found}
      error -> error
    end
  end

  def resolve(_, _), do: {:error, :invalid_arguments}

  def with_revision(%{"kind" => "internal"} = binding, _), do: binding
  def with_revision(binding, revision), do: Map.put(binding, "binding_revision", revision)
end
