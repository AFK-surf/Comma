defmodule SalixStore.ComputeGroupStation do
  @moduledoc "Group VMM placement through the Host's existing Compute Environment and Workload."

  import Ecto.Query
  require Logger
  alias SalixStore.{AgentVMM, Compute, Repo}

  def environment(tenant, group) do
    with {:ok, {_registration, environment, _binding}} <- placement(tenant, group),
         do: {:ok, environment}
  end

  def placement(tenant, group) do
    now = SystemsClock.utc_now()

    registrations =
      Repo.all(
        from(r in AgentVMM.Registration,
          where:
            r.tenant_id == ^tenant and r.group_id == ^group and r.desired_enabled and
              r.status == "ready" and r.authorization_expires_at > ^now,
          limit: 2
        )
      )

    case registrations do
      [registration] ->
        if AgentVMM.connected?(registration.id),
          do: environment_for_registration(registration),
          else: {:error, :not_found}

      [] ->
        {:error, :not_found}

      _ ->
        {:error, :ambiguous_vmm_hosts}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp environment_for_registration(registration) do
    query =
      from(e in Compute.Environment,
        join: b in Compute.ProviderBinding,
        on: b.environment_id == e.id and b.pool_id == e.pool_id,
        where:
          e.tenant_id == ^registration.tenant_id and e.desired_state == "ready" and
            b.provider == "agent_vmm" and b.provider_ref == ^registration.id and
            b.generation == e.generation and b.status == "available",
        select: {e, b},
        limit: 2
      )

    # Installations already own a Project Environment. A legacy Group Cloud VM
    # may have another binding to the same Host; preserve that VM's identity.
    projects = Repo.all(from([e, _b] in query, where: e.owner_type != "group"))

    rows =
      if projects == [],
        do:
          Repo.all(
            from([e, _b] in query,
              where: e.owner_type == "group" and e.owner_id == ^registration.group_id
            )
          ),
        else: projects

    case rows do
      [{environment, binding}] -> {:ok, {registration, environment, binding}}
      [] -> {:error, :not_found}
      _ -> {:error, :ambiguous_vmm_environments}
    end
  end

  def ensure(tenant, group) do
    with {:ok, {registration, environment, binding}} <- placement(tenant, group) do
      Repo.transaction(fn ->
        # Registration authorization and Environment generation are the existing
        # owners. A replaced registration never reuses the old Station Workload.
        current =
          Repo.one!(
            from(r in AgentVMM.Registration, where: r.id == ^registration.id, lock: "FOR UPDATE")
          )

        if not current.desired_enabled or current.status != "ready" or
             AgentVMM.authorization_expired?(current),
           do: Repo.rollback(:provider_unavailable)

        current_environment =
          Repo.one!(
            from(e in Compute.Environment, where: e.id == ^environment.id, lock: "FOR UPDATE")
          )

        if current_environment.generation != environment.generation,
          do: Repo.rollback(:stale_generation)

        case legacy_station(group, registration.id) ||
               station_workload(environment, binding, group) do
          %Compute.Workload{} = workload ->
            workload

          nil ->
            case Compute.place_workload(%{
                   tenant_id: tenant,
                   environment_id: environment.id,
                   provider_binding_id: binding.id,
                   allocation_id: "allocation_" <> SystemsRuntime.Proc.uuid(),
                   workload_id: "workload_" <> SystemsRuntime.Proc.uuid(),
                   kind: "service",
                   template_key: "station.default",
                   owner_ref: %{"kind" => "group", "id" => group},
                   capability_requirements: ["runtime_exec", "runtime_process"]
                 }) do
              {:ok, %{workload: workload}} -> workload
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)
    end
  end

  def get(tenant, group) do
    with {:ok, {registration, environment, binding}} <- placement(tenant, group),
         %Compute.Workload{} = workload <-
           legacy_station(group, registration.id) || station_workload(environment, binding, group) do
      record(workload)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp station_workload(environment, binding, group) do
    Repo.one(
      from(w in Compute.Workload,
        join: a in Compute.Allocation,
        on: a.id == w.allocation_id,
        where:
          w.environment_id == ^environment.id and a.provider_binding_id == ^binding.id and
            w.generation == ^environment.generation and a.generation == ^environment.generation and
            w.template_key == "station.default" and
            fragment("?->>'kind' = 'group' AND ?->>'id' = ?", w.owner_ref, w.owner_ref, ^group),
        limit: 1
      )
    )
  end

  defp legacy_station(group, registration_id) do
    case Compute.group_workload(group) do
      {:ok,
       %{
         "provider" => "agent_vmm",
         "provider_resource_id" => ^registration_id,
         "workload_id" => id
       }} ->
        Repo.get(Compute.Workload, id)

      _ ->
        nil
    end
  end

  # A Workload credential resolves only its own device, including when a Group
  # also owns a Cloudflare VM. The existing Group default keeps its stored ids.
  def record(%Compute.Workload{
        id: id,
        spec: %{"group_default" => true},
        environment_id: environment_id
      }) do
    case Repo.get(Compute.Environment, environment_id) do
      %Compute.Environment{owner_type: "group", owner_id: group} ->
        case Compute.group_workload(group) do
          {:ok, %{"workload_id" => ^id}} = result -> result
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  def record(%Compute.Workload{template_key: "station.default"} = workload) do
    with %Compute.Environment{} = environment <-
           Repo.get(Compute.Environment, workload.environment_id),
         %Compute.Allocation{} = allocation <-
           Repo.get(Compute.Allocation, workload.allocation_id),
         %Compute.ProviderBinding{provider: "agent_vmm"} = binding <-
           Repo.get(Compute.ProviderBinding, allocation.provider_binding_id),
         %AgentVMM.Registration{tenant_id: tenant, group_id: group} <-
           Repo.get(AgentVMM.Registration, binding.provider_ref),
         true <-
           tenant == environment.tenant_id and
             workload.owner_ref == %{"kind" => "group", "id" => group} do
      device = workload.spec["device"] || %{}

      {:ok,
       Map.merge(device, %{
         "tenant_id" => tenant,
         "group_id" => group,
         "workload_id" => workload.id,
         "generation" => workload.generation,
         "provider" => "agent_vmm",
         "provider_resource_name" => workload.id,
         "provider_resource_id" => binding.provider_ref,
         "env_id" => "station-" <> workload.id,
         "device_id" => "dev-station-" <> workload.id,
         "connector_id" => "conn-station-" <> workload.id,
         "name" => "VMM Station",
         "alias" => "vmm-station",
         "status" =>
           if(workload.desired_state == "ready" and is_nil(workload.deletion),
             do: workload.observed_state,
             else: "stopped"
           )
       })}
    else
      _ -> {:error, :not_found}
    end
  end

  def record(_), do: {:error, :not_found}

  def remember(workload_id, connector_id, station) do
    case Repo.get(Compute.Workload, workload_id) do
      %Compute.Workload{spec: %{"group_default" => true}} = workload ->
        with {:ok, record} <- record(workload),
             true <- record["connector_id"] == connector_id,
             {:ok, _, _} <-
               Compute.update_group_workload(
                 record["group_id"],
                 &Map.put(&1, "station_id", station)
               ),
             do: {:ok, :ok}

      _ ->
        remember_station(workload_id, connector_id, station)
    end
  end

  defp remember_station(workload_id, connector_id, station) do
    Repo.transaction(fn ->
      workload =
        Repo.one!(from(w in Compute.Workload, where: w.id == ^workload_id, lock: "FOR UPDATE"))

      with {:ok, record} <- record(workload),
           true <- record["connector_id"] == connector_id do
        spec =
          Map.put(
            workload.spec,
            "device",
            Map.put(workload.spec["device"] || %{}, "station_id", station)
          )

        Repo.update!(Ecto.Changeset.change(workload, spec: spec, revision: workload.revision + 1))
        :ok
      else
        _ -> Repo.rollback(:connector_replaced)
      end
    end)
  end

  @doc "Resolve only the selected device's existing Workload owner."
  def device_owner(tenant, group, "dev-station-" <> workload_id = device) do
    with %Compute.Workload{} = workload <- Repo.get(Compute.Workload, workload_id),
         {:ok, %{"tenant_id" => ^tenant, "group_id" => ^group, "device_id" => ^device} = record} <-
           record(workload) do
      {:workload, record}
    else
      _ -> {:error, :vmm_station_not_authorized}
    end
  end

  # Coding sandbox devices belong to the Task's L4ES lifecycle, independently
  # of this Group's reusable Station or default Cloud VM.
  def device_owner(_tenant, _group, "dev-sbx-" <> _), do: :unmanaged

  def device_owner(tenant, group, device) when is_binary(device) do
    case Compute.group_provider_ownership(tenant, group) do
      {:managed, %{"device_id" => ^device} = record} -> {:group_default, record}
      {:managed, _other_device} -> :unmanaged
      other -> other
    end
  end

  def device_owner(_, _, _), do: {:error, :group_workload_unavailable}

  def managed_device?(tenant, group, device) do
    case device_owner(tenant, group, device) do
      {kind, _record} when kind in [:group_default, :workload] -> true
      # The Group default has this identity before its first provisioning.
      :unmanaged -> device == SalixStore.RuntimeIds.cloud_vm_device_id(group)
      _ -> false
    end
  end

  @doc "Current command authority of one exact Group Station Workload; manager loss is not revocation."
  def admit_device(tenant, group, device) do
    case device_owner(tenant, group, device) do
      {kind, record} when kind in [:group_default, :workload] ->
        admit_record(record)

      :unmanaged ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc "Authorize the exact Workload generation of an already resolved Group Station."
  def admit_record(%{"provider" => "agent_vmm"} = record), do: admit_vmm(record)

  def admit_record(%{"workload_id" => id, "generation" => generation}) do
    if match?(%Compute.Workload{generation: ^generation}, Repo.get(Compute.Workload, id)),
      do: :ok,
      else: {:error, :managed_provider_changed}
  end

  defp admit_vmm(record) do
    with %Compute.Workload{} = workload <- Repo.get(Compute.Workload, record["workload_id"]),
         true <- workload.generation == record["generation"],
         %AgentVMM.Registration{} = registration <-
           Repo.get(AgentVMM.Registration, record["provider_resource_id"]),
         %Compute.Allocation{} = allocation <-
           Repo.get(Compute.Allocation, workload.allocation_id),
         %Compute.ProviderBinding{} = binding <-
           Repo.get(Compute.ProviderBinding, allocation.provider_binding_id),
         %Compute.Environment{} = environment <-
           Repo.get(Compute.Environment, workload.environment_id),
         true <- authorized?(registration, environment, workload, allocation, binding) do
      :ok
    else
      _ -> {:error, :vmm_station_not_authorized}
    end
  end

  defp authorized?(registration, environment, workload, allocation, binding) do
    registration.desired_enabled and registration.status != "revoked" and
      not AgentVMM.authorization_expired?(registration) and
      workload.desired_state == "ready" and is_nil(workload.deletion) and
      allocation.status == "ready" and allocation.generation == workload.generation and
      allocation.environment_id == environment.id and
      environment.generation == workload.generation and environment.desired_state == "ready" and
      binding.provider == "agent_vmm" and binding.provider_ref == registration.id and
      binding.environment_id == environment.id and binding.generation == environment.generation
  end

  def wake_device(tenant, group, device) do
    case device_owner(tenant, group, device) do
      {:group_default, _record} ->
        :group_default

      {:workload, record} ->
        with :ok <- admit_vmm(record),
             %Compute.Workload{} = workload <- Repo.get(Compute.Workload, record["workload_id"]),
             do:
               Compute.observe_workload(
                 workload.id,
                 workload.revision,
                 workload.generation,
                 "pending"
               )

      :unmanaged ->
        :none

      {:error, _} = error ->
        error
    end
  end

  def prepare_registration(registration_id, refresh? \\ false) do
    result =
      case Repo.get(AgentVMM.Registration, registration_id) do
        %AgentVMM.Registration{tenant_id: tenant, group_id: group} ->
          with {:ok, workload} <- ensure(tenant, group) do
            if refresh? and workload.desired_state == "ready" and is_nil(workload.deletion) and
                 workload.observed_state == "ready" and workload.spec["group_default"] != true do
              Compute.observe_workload(
                workload.id,
                workload.revision,
                workload.generation,
                "pending"
              )
            else
              {:ok, workload}
            end
          end

        _ ->
          {:error, :not_found}
      end

    case result do
      {:error, reason} when reason != :not_found ->
        Logger.warning("VMM Station preparation failed: #{inspect(reason)}")

      _ ->
        :ok
    end

    result
  rescue
    _ -> {:error, :unavailable}
  end

  def with_connection(workload_id, generation, connect) do
    Repo.transaction(fn ->
      workload = Repo.get(Compute.Workload, workload_id) || Repo.rollback(:not_found)
      allocation = Repo.get!(Compute.Allocation, workload.allocation_id)
      binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)

      registration =
        Repo.one!(
          from(r in AgentVMM.Registration,
            where: r.id == ^binding.provider_ref,
            lock: "FOR UPDATE"
          )
        )

      environment =
        Repo.one!(
          from(e in Compute.Environment,
            where: e.id == ^workload.environment_id,
            lock: "FOR UPDATE"
          )
        )

      current =
        Repo.one!(from(w in Compute.Workload, where: w.id == ^workload_id, lock: "FOR UPDATE"))

      # Release owns the Allocation row independently of the Workload. Re-read
      # it under its lock after the owner locks, and hold it through admission.
      allocation =
        Repo.one!(
          from(a in Compute.Allocation,
            where: a.id == ^current.allocation_id,
            lock: "FOR UPDATE"
          )
        )

      binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)

      if current.generation != generation or
           not authorized?(registration, environment, current, allocation, binding),
         do: Repo.rollback(:managed_provider_changed)

      connect.()
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
