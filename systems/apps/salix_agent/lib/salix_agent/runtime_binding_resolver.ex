defmodule SalixAgent.RuntimeBindingResolver do
  @moduledoc """
  Resolves the two provider-neutral External Worker binding variants.

  Stable target identity and live transport epoch are deliberately separate.
  An External Session persists only the tagged stable binding; a session
  capability pins the stable target. Connected Runtime keeps that bearer while
  each request is fenced by the current connector run; Compute Workload rotates
  the bearer after a new RuntimeInstance epoch catches up and revokes the old
  bearer. RuntimeInstance reconnect becomes dispatchable only after its exact
  epoch has caught up. This is the implementation anchor for
  `tla/salix/ExternalRuntimeBinding.tla`.
  """

  alias SalixAgent.RuntimeEnvironment
  alias SalixStore.{Compute, ExecutionTarget, ExternalWorkerTargets, Repo}
  require Ecto.Query

  @type result :: {:ok, map()} | {:error, term()}

  @spec resolve(map(), String.t(), String.t()) :: result()
  def resolve(binding, tenant_id, group_id) when is_map(binding) do
    case ExecutionTarget.binding(binding) do
      {:ok, {:device_runtime, _id}} -> resolve_connected(binding, tenant_id, group_id)
      {:ok, {:compute_workload, _id}} -> resolve_compute(binding, tenant_id, group_id)
      _ -> {:error, {:bad_request, "unsupported external worker binding"}}
    end
  end

  def resolve(_, _, _), do: {:error, {:bad_request, "runtime binding must be an object"}}

  @spec status(map(), String.t(), String.t()) :: result()
  def status(binding, tenant_id, group_id) when is_map(binding) do
    case ExecutionTarget.binding(binding) do
      {:ok, {:device_runtime, _id}} ->
        RuntimeEnvironment.connected_status(binding, tenant_id, group_id)

      {:ok, {:compute_workload, _id}} ->
        compute_status(binding, tenant_id, group_id)

      _ ->
        {:ok, %{"status" => "missing", "issue" => "binding_not_found"}}
    end
  end

  def status(_, _, _), do: {:ok, %{"status" => "missing", "issue" => "binding_not_found"}}

  defp resolve_connected(binding, tenant_id, group_id) do
    with {:ok, required_carrier} <- group_provider_dispatch(binding, tenant_id, group_id),
         {:ok, resolved} <- RuntimeEnvironment.connected_resolve(binding, tenant_id, group_id),
         :ok <- require_carrier(resolved, required_carrier) do
      {:ok,
       resolved
       |> Map.put("kind", "connected_runtime")
       |> Map.put("provider", binding["provider"])
       |> Map.put("stable_target_id", binding["device_runtime_id"])
       |> Map.put("connection_epoch", resolved["connection_generation"] || 1)}
    end
  end

  # Group provider cutover has closed source execution. The Group projection is
  # indexed by owner; ordinary connected Devices have no Group Workload.
  defp group_provider_dispatch(binding, tenant_id, group_id) do
    case Compute.group_provider_ownership(tenant_id, group_id) do
      {:managed,
       %{
         "device_id" => device_id,
         "provider_migration" => %{"phase" => phase}
       }}
      when phase in ~w(preparing exported restored retired) ->
        if device_id == binding["device_id"],
          do: {:error, :provider_migration_in_progress},
          else: {:ok, nil}

      {:managed,
       %{
         "device_id" => device_id,
         "provider" => "cloudflare",
         "provider_migration" => %{
           "phase" => "committed",
           "archive_hold" => "awaiting_durable_archive"
         }
       }} ->
        if device_id == binding["device_id"],
          do: {:error, :provider_cutover_archive_pending},
          else: {:ok, nil}

      {:managed,
       %{
         "device_id" => device_id,
         "provider" => "cloudflare",
         "provider_migration" => %{"phase" => "committed"}
       }} ->
        {:ok, if(device_id == binding["device_id"], do: "cloudflare", else: nil)}

      {:managed, _} ->
        {:ok, nil}

      :unmanaged ->
        {:ok, nil}

      {:error, _} ->
        {:error, :group_workload_unavailable}
    end
  end

  defp require_carrier(_resolved, nil), do: :ok

  defp require_carrier(%{"carrier_provider" => carrier}, required) when carrier == required,
    do: :ok

  defp require_carrier(_, _), do: {:error, :provider_migration_target_not_connected}

  defp resolve_compute(binding, tenant_id, group_id) do
    with {:ok, %{runtime: runtime} = facts} <- compute_facts(binding, tenant_id, group_id) do
      container_id = Map.get(facts, :container_id)
      container_instance_id = Map.get(facts, :container_instance_id)

      cond do
        runtime.readiness != "ready" or runtime.connection_epoch != runtime.caught_up_epoch ->
          {:error, :runtime_catching_up}

        not (is_binary(container_id) and container_id != "" and
               is_binary(container_instance_id) and container_instance_id != "") ->
          {:error, :runtime_not_running}

        true ->
          {:ok,
           %{
             "kind" => "compute_workload",
             "stable_target_id" => facts.workload.id,
             "workload_id" => facts.workload.id,
             "runtime_instance_id" => runtime.id,
             "runtime_generation" => runtime.generation,
             "connection_epoch" => runtime.connection_epoch,
             "container_id" => container_id,
             "container_instance_id" => container_instance_id,
             "runtime_spec" => binding["runtime_spec"] || %{}
           }}
      end
    end
  end

  defp compute_status(binding, tenant_id, group_id) do
    case compute_facts(binding, tenant_id, group_id) do
      {:ok, %{runtime: runtime, workload: workload}} ->
        ready =
          runtime.readiness == "ready" and runtime.connection_epoch == runtime.caught_up_epoch

        {:ok,
         %{
           "status" => if(ready, do: "ready", else: "connecting"),
           "workload_id" => workload.id,
           "runtime_instance_id" => runtime.id,
           "connection_epoch" => runtime.connection_epoch,
           "caught_up_epoch" => runtime.caught_up_epoch,
           "generation" => workload.generation
         }}

      {:error, :not_found} ->
        {:ok, %{"status" => "missing", "issue" => "runtime_not_found"}}

      {:error, reason} ->
        {:ok, %{"status" => "unavailable", "issue" => to_string(reason)}}
    end
  end

  # Expand compatibility: a legacy binding without owner_scope retains its
  # tenant-only reader until the RFC25 backfill audit reaches zero. Any record
  # that has entered the scoped revision contract is enforced immediately.
  defp compute_facts(%{"owner_scope" => owner_scope} = binding, tenant_id, group_id)
       when is_map(owner_scope) do
    provider = get_in(binding, ["runtime_spec", "provider"])
    owner_type = owner_scope["type"] || owner_scope[:type]
    owner_id = owner_scope["id"] || owner_scope[:id]

    scope = %{
      tenant_id: tenant_id,
      owner_type: owner_type,
      owner_id: owner_id,
      group_id: group_id,
      provider: provider
    }

    case ExternalWorkerTargets.current(scope, binding["workload_id"]) do
      {:ok, %{row: row, item: %{selectable: true}}} ->
        {:ok,
         %{
           environment:
             struct(Compute.Environment, %{
               id: row.environment_id,
               generation: row.environment_generation
             }),
           allocation:
             struct(Compute.Allocation, %{
               id: row.allocation_id,
               generation: row.allocation_generation
             }),
           workload:
             struct(Compute.Workload, %{
               id: row.workload_id,
               generation: row.workload_generation
             }),
           runtime:
             struct(Compute.RuntimeInstance, %{
               id: row.runtime_instance_id,
               generation: row.runtime_generation,
               readiness: row.runtime_readiness,
               connection_epoch: row.runtime_connection_epoch,
               caught_up_epoch: row.runtime_caught_up_epoch
             }),
           container_id: row.current_container_id,
           container_instance_id: row.current_container_instance_id
         }}

      {:ok, %{item: %{reason: reason}}} ->
        {:error, reason_atom(reason)}

      {:error, :invalid_query} ->
        {:error, :binding_scope_mismatch}

      {:error, :scope_mismatch} ->
        {:error, :binding_scope_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp compute_facts(%{"owner_scope" => _}, _tenant_id, _group_id),
    do: {:error, :binding_scope_mismatch}

  defp compute_facts(binding, tenant_id, _group_id) do
    workload_id = binding["workload_id"]
    workload = is_binary(workload_id) && Repo.get(Compute.Workload, workload_id)
    environment = workload && Repo.get(Compute.Environment, workload.environment_id)
    allocation = workload && Repo.get(Compute.Allocation, workload.allocation_id)

    runtime =
      workload &&
        Repo.one(
          Ecto.Query.from(r in Compute.RuntimeInstance,
            where: r.workload_id == ^workload.id and r.generation == ^workload.generation,
            limit: 1
          )
        )

    cond do
      is_nil(workload) or is_nil(environment) or is_nil(allocation) or is_nil(runtime) ->
        {:error, :not_found}

      environment.tenant_id != tenant_id ->
        {:error, :scope_mismatch}

      environment.desired_state != "ready" or workload.desired_state != "ready" ->
        {:error, :revoked}

      allocation.environment_id != environment.id or
        allocation.generation != environment.generation or
        runtime.allocation_id != allocation.id or
          runtime.generation != workload.generation ->
        {:error, :stale_generation}

      true ->
        current_container = allocation.provider_observation["current_container"] || %{}

        {:ok,
         %{
           environment: environment,
           allocation: allocation,
           workload: workload,
           runtime: runtime,
           container_id: current_container["id"],
           container_instance_id: current_container["instance_id"]
         }}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp reason_atom("registration_unavailable"), do: :registration_unavailable
  defp reason_atom("binding_unavailable"), do: :binding_unavailable
  defp reason_atom("environment_not_ready"), do: :environment_not_ready
  defp reason_atom("allocation_not_ready"), do: :allocation_not_ready
  defp reason_atom("lease_expired"), do: :lease_expired
  defp reason_atom("workload_not_ready"), do: :workload_not_ready
  defp reason_atom("runtime_missing"), do: :runtime_missing
  defp reason_atom("runtime_generation_mismatch"), do: :runtime_generation_mismatch
  defp reason_atom("runtime_not_connected"), do: :runtime_not_connected
  defp reason_atom("runtime_not_ready"), do: :runtime_not_ready
  defp reason_atom("runtime_catching_up"), do: :runtime_catching_up
  defp reason_atom("scope_mismatch"), do: :binding_scope_mismatch
  defp reason_atom(_), do: :unavailable
end
