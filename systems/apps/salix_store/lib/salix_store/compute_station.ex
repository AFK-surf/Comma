defmodule SalixStore.ComputeStation do
  @moduledoc """
  The Station connection projected from an existing Compute Workload.

  This module adds no stored identity or lifecycle. Group and coding Task owners retain placement,
  generation changes, wake and cleanup. Authenticated connections carry the
  Workload generation they proved; a current Device alone cannot prove it.
  """
  import Ecto.Query
  alias SalixStore.{Compute, ComputeGroupStation, Repo}

  def record(%Compute.Workload{kind: "coding_sandbox", spec: spec} = workload) do
    with %Compute.Environment{owner_type: "task", owner_id: conversation, tenant_id: tenant} <-
           Repo.get(Compute.Environment, workload.environment_id),
         %Compute.Allocation{} = allocation <-
           Repo.get(Compute.Allocation, workload.allocation_id),
         %Compute.ProviderBinding{provider: "l4es"} <-
           Repo.get(Compute.ProviderBinding, allocation.provider_binding_id),
         true <-
           spec["tenant_id"] == tenant and spec["conversation_id"] == conversation and
             workload.owner_ref == %{
               "kind" => "task",
               "group_id" => spec["group_id"],
               "conversation_id" => conversation
             } do
      {:ok,
       %{
         "tenant_id" => tenant,
         "group_id" => spec["group_id"],
         "workload_id" => workload.id,
         "generation" => workload.generation,
         "provider" => "l4es",
         "owner" => "coding_task",
         "account_id" => spec["account_id"],
         "device_id" => spec["device_id"],
         "connector_id" => spec["connector_id"],
         "env_id" => spec["transport_id"],
         "name" => "Coding sandbox",
         "alias" => "sandbox"
       }}
    else
      _ -> {:error, :managed_station_not_authorized}
    end
  end

  def record(%Compute.Workload{} = workload) do
    with {:ok, record} <- ComputeGroupStation.record(workload) do
      {:ok,
       Map.put(
         record,
         "owner",
         if(workload.spec["group_default"] == true, do: "group_default", else: "group_station")
       )}
    end
  end

  def device_owner(tenant, group, "dev-sbx-" <> _ = device) do
    with {:ok, workload} <- SalixStore.CodingSandboxes.get_by_device(tenant, device),
         {:ok, %{"tenant_id" => ^tenant, "group_id" => ^group, "device_id" => ^device} = record} <-
           record(workload) do
      {:workload, record}
    else
      _ -> {:error, :managed_station_not_authorized}
    end
  rescue
    _ -> {:error, :managed_station_not_authorized}
  end

  def device_owner(tenant, group, device) do
    case ComputeGroupStation.device_owner(tenant, group, device) do
      {:group_default, record} -> {:group_default, Map.put(record, "owner", "group_default")}
      {:workload, record} -> {:workload, Map.put(record, "owner", "group_station")}
      other -> other
    end
  end

  def admit_device(tenant, group, device) do
    case device_owner(tenant, group, device) do
      {:workload, %{"owner" => "coding_task"} = record} ->
        admit_coding(record)

      {kind, record} when kind in [:group_default, :workload] ->
        ComputeGroupStation.admit_record(record)

      :unmanaged ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc "Authorize one proved Workload generation and return its fixed owner/account snapshot."
  def authorize(%{tenant_id: tenant, group_id: group, device_id: device} = context) do
    owner = device_owner(tenant, group, device)

    with :ok <- connection_generation(owner, context) do
      case owner do
        {_kind, %{"owner" => "coding_task"} = record} ->
          with :ok <- admit_coding(record), do: {:ok, record}

        {_kind, %{} = record} ->
          with :ok <- ComputeGroupStation.admit_record(record), do: {:ok, record}

        :unmanaged ->
          {:ok, :unmanaged}
      end
    else
      {:error, _} = error -> error
    end
  end

  defp connection_generation({:error, _} = error, _context), do: error

  defp connection_generation(:unmanaged, context) do
    if is_binary(context[:workload_id]) or is_integer(context[:workload_generation]),
      do: {:error, :managed_station_not_authorized},
      else: :ok
  end

  defp connection_generation({_kind, %{"workload_id" => _, "generation" => _} = record}, context) do
    if context[:workload_id] == record["workload_id"] and
         context[:workload_generation] == record["generation"],
       do: :ok,
       else: {:error, :managed_station_not_authorized}
  end

  defp connection_generation(_owner, _context), do: :ok

  @doc "Attach the Workload proof already stored on a Device's authenticated connection."
  def connection(tenant, group, %{} = device) do
    meta = device["meta"] || %{}

    %{
      tenant_id: tenant,
      group_id: group,
      device_id: device["device_id"],
      connector_run_id: device["connector_run_id"],
      workload_id: meta["workload_id"],
      workload_generation: meta["workload_generation"]
    }
  end

  def managed_device?(tenant, group, device) do
    case device_owner(tenant, group, device) do
      {:workload, _} -> true
      {:group_default, _} -> true
      _ -> ComputeGroupStation.managed_device?(tenant, group, device)
    end
  end

  def with_connection(workload_id, generation, connect) do
    with %Compute.Workload{} = workload <- Repo.get(Compute.Workload, workload_id),
         {:ok, record} <- record(workload) do
      case record do
        %{"provider" => "agent_vmm"} ->
          ComputeGroupStation.with_connection(workload_id, generation, connect)

        %{"owner" => "coding_task"} ->
          with_coding_connection(workload_id, generation, connect)

        %{"owner" => "group_default"} ->
          Compute.with_group_provider(
            record["group_id"],
            record["provider"],
            %{
              "name" => record["provider_resource_name"],
              "profile_key" => get_in(record, ["provider_spec", "profile_key"])
            },
            fn ->
              if Repo.get!(Compute.Workload, workload_id).generation == generation,
                do: connect.(),
                else: {:error, :managed_provider_changed}
            end
          )
      end
    else
      _ -> {:error, :managed_provider_changed}
    end
  end

  @doc "Remember a roster Station key only under its exact authenticated Workload generation."
  def remember(
        %{workload_id: id, workload_generation: generation, connector_id: connector},
        station
      ) do
    with_connection(id, generation, fn -> ComputeGroupStation.remember(id, connector, station) end)
  end

  defp with_coding_connection(id, generation, connect) do
    Repo.transaction(fn ->
      # The coding owner advances Workload then Environment. Take the same
      # locks so a checked credential cannot outlive a concurrent replacement.
      workload = Repo.one!(from(w in Compute.Workload, where: w.id == ^id, lock: "FOR UPDATE"))

      Repo.one!(
        from(e in Compute.Environment,
          where: e.id == ^workload.environment_id,
          lock: "FOR UPDATE"
        )
      )

      Repo.one!(
        from(a in Compute.Allocation, where: a.id == ^workload.allocation_id, lock: "FOR UPDATE")
      )

      with true <- workload.generation == generation,
           {:ok, record} <- record(workload),
           :ok <- admit_coding(record) do
        connect.()
      else
        _ -> Repo.rollback(:managed_provider_changed)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_coding(record) do
    with %Compute.Workload{} = w <- Repo.get(Compute.Workload, record["workload_id"]),
         %Compute.Environment{} = e <- Repo.get(Compute.Environment, w.environment_id),
         %Compute.Allocation{} = a <- Repo.get(Compute.Allocation, w.allocation_id),
         true <-
           w.generation == record["generation"] and w.desired_state == "ready" and
             is_nil(w.deletion) and
             w.spec["state"] in ["starting", "ready"] and e.desired_state == "ready" and
             w.generation == e.generation and a.generation == w.generation and
             a.environment_id == e.id and a.status in ["allocating", "ready"] do
      :ok
    else
      _ -> {:error, :managed_station_not_authorized}
    end
  end
end
