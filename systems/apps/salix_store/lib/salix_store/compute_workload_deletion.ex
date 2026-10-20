defmodule SalixStore.ComputeWorkloadDeletion do
  @moduledoc false
  import Ecto.Query
  alias SalixStore.{Compute, ComputeRuntimeCarrier, ComputeWorkloadUpdate, Repo, ServiceRoutes}

  # external_worker: stored Workloads of the retired External Worker templates.
  @deletable_kinds ["shell", "external_worker"]

  def start(tenant, project, id, revision, generation, request_id, authorize)
      when is_integer(revision) and is_integer(generation) and is_binary(request_id) and
             byte_size(request_id) in 1..64 and is_function(authorize, 0) do
    Repo.transaction(fn ->
      workload = owned!(tenant, project, id)
      if authorize.() != :ok, do: Repo.rollback(:not_found)
      previous = workload.deletion || %{}

      cond do
        previous["request_id"] == request_id ->
          if previous["generation"] != generation, do: Repo.rollback(:stale_generation)
          workload

        previous != %{} ->
          Repo.rollback(:deletion_in_progress)

        workload.revision != revision or workload.generation != generation ->
          Repo.rollback(:revision_conflict)

        workload.kind not in @deletable_kinds or business_reference?(workload) ->
          Repo.rollback(:business_owner_required)

        ComputeWorkloadUpdate.active?(workload) ->
          Repo.rollback(:update_in_progress)

        true ->
          allocation =
            Repo.one!(
              from(a in Compute.Allocation,
                where: a.id == ^workload.allocation_id,
                lock: "FOR UPDATE"
              )
            )

          binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)
          if binding.provider != "agent_vmm", do: Repo.rollback(:unsupported_provider)
          if allocation.generation != generation, do: Repo.rollback(:stale_generation)

          if Repo.exists?(
               from(w in Compute.Workload,
                 where: w.allocation_id == ^allocation.id and w.id != ^id
               )
             ),
             do: Repo.rollback(:shared_allocation)

          deletion = %{
            "request_id" => request_id,
            "host_request_id" => "dispose:" <> SystemsRuntime.Proc.uuid(),
            "generation" => generation,
            "allocation_id" => allocation.id,
            "registration_id" => binding.provider_ref,
            "provider_binding_id" => binding.id,
            "phase" => "settling_work",
            "requested_at" => DateTime.to_iso8601(SystemsClock.utc_now())
          }

          Repo.update_all(from(w in Compute.Workload, where: w.id == ^id),
            set: [
              deletion: deletion,
              desired_state: "draining",
              updated_at: SystemsClock.timestamp(:utc_datetime_usec)
            ],
            inc: [revision: 1]
          )

          Repo.update_all(from(c in Compute.ReconcilerClaim, where: c.workload_id == ^id),
            set: [last_error: %{}, next_retry_at: SystemsClock.utc_now()]
          )

          # External Workers are retired; nothing reads their bindings or
          # operations, so a deleted external_worker Workload takes them along.
          if workload.kind == "external_worker" do
            Repo.delete_all(from(b in Compute.ExternalWorkerBinding, where: b.workload_id == ^id))

            Repo.delete_all(from(o in "external_worker_operations", where: o.workload_id == ^id))
          end

          # The Workload lock serializes this admission fence with runtime input acceptance.
          Repo.update_all(
            from(c in Compute.Command,
              where:
                c.workload_id == ^id and c.status == "pending" and
                  c.classification == "desired_state"
            ),
            set: [
              status: "cancelled",
              outcome: "failed",
              updated_at: SystemsClock.timestamp(:utc_datetime_usec)
            ]
          )

          Repo.get!(Compute.Workload, id)
      end
    end)
  end

  def start(_, _, _, _, _, _, _), do: {:error, :invalid_deletion_request}

  defp owned!(tenant, project, id) do
    Repo.one(
      from(w in Compute.Workload,
        join: e in Compute.Environment,
        on: e.id == w.environment_id,
        where:
          w.id == ^id and e.tenant_id == ^tenant and e.owner_type == "project" and
            e.owner_id == ^project,
        lock: "FOR UPDATE OF c0",
        select: w
      )
    ) || Repo.rollback(:not_found)
  end

  # A retired External Worker's leftover binding does not own its Workload.
  defp business_reference?(workload) do
    (workload.kind != "external_worker" and
       Repo.exists?(
         from(b in Compute.ExternalWorkerBinding, where: b.workload_id == ^workload.id)
       )) or
      Repo.exists?(from(e in ServiceRoutes.Export, where: e.workload_id == ^workload.id)) or
      Repo.exists?(
        from(i in ServiceRoutes.Import, where: i.destination_workload_id == ^workload.id)
      )
  end

  # Revocation ends cloud authority. It is not a receipt for local disk disposal.
  # Keep commands and runtime inputs with unknown outcomes under their existing owners.
  def retire_revoked(limit \\ 32, after_id \\ "") when limit in 1..32 do
    {targets, cursor} = retirement_page(limit, retirement_cursor(after_id), [])

    Enum.each(targets, fn
      {:allocation, id} ->
        retire_empty_allocation(id)

      id ->
        ComputeWorkloadUpdate.with_lock(id, fn ->
          workload =
            Repo.one!(from(w in Compute.Workload, where: w.id == ^id, lock: "FOR UPDATE"))

          allocation =
            Repo.one!(
              from(a in Compute.Allocation,
                where: a.id == ^workload.allocation_id,
                lock: "FOR UPDATE"
              )
            )

          binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)
          registration = Repo.get!(SalixStore.AgentVMM.Registration, binding.provider_ref)

          if registration.status == "revoked" do
            cancel_undelivered_page!(allocation.id)

            retire_cloud!(allocation, workload, registration)
          end
        end)
    end)

    # Advance even past a busy owner; retry it on the next pass, without a hot loop.
    {:ok, %{after_id: cursor}}
  end

  defp retirement_cursor(""), do: %{level: :registration, r: "", b: "", a: "", w: ""}
  defp retirement_cursor(cursor) when is_map(cursor), do: cursor

  # Empty branches consume the same budget as populated branches. Each seek fixes
  # its parent and uses the corresponding (parent_id, id) index; no global join/sort.
  defp retirement_page(0, cursor, targets), do: {Enum.reverse(targets), cursor}

  defp retirement_page(budget, %{level: :registration} = cursor, targets) do
    id =
      Repo.one(
        from(r in SalixStore.AgentVMM.Registration,
          where: r.status == "revoked" and r.id > ^cursor.r,
          order_by: r.id,
          limit: 1,
          select: r.id
        )
      )

    if id do
      retirement_page(
        budget - 1,
        %{cursor | level: :binding, r: id, b: "", a: "", w: ""},
        targets
      )
    else
      {Enum.reverse(targets), ""}
    end
  end

  defp retirement_page(budget, %{level: :binding} = cursor, targets) do
    id =
      Repo.one(
        from(b in Compute.ProviderBinding,
          where: b.provider == "agent_vmm" and b.provider_ref == ^cursor.r and b.id > ^cursor.b,
          order_by: b.id,
          limit: 1,
          select: b.id
        )
      )

    next =
      if id,
        do: %{cursor | level: :allocation, b: id, a: "", w: ""},
        else: %{cursor | level: :registration}

    retirement_page(budget - 1, next, targets)
  end

  defp retirement_page(budget, %{level: :allocation} = cursor, targets) do
    id =
      Repo.one(
        from(a in Compute.Allocation,
          where: a.provider_binding_id == ^cursor.b and a.id > ^cursor.a,
          order_by: a.id,
          limit: 1,
          select: a.id
        )
      )

    next =
      if id,
        do: %{cursor | level: :workload, a: id, w: ""},
        else: %{cursor | level: :binding}

    retirement_page(budget - 1, next, targets)
  end

  defp retirement_page(budget, %{level: :workload} = cursor, targets) do
    id =
      Repo.one(
        from(w in Compute.Workload,
          where: w.allocation_id == ^cursor.a and w.id > ^cursor.w,
          order_by: w.id,
          limit: 1,
          select: w.id
        )
      )

    if id do
      retirement_page(budget - 1, %{cursor | w: id}, [id | targets])
    else
      targets = if cursor.w == "", do: [{:allocation, cursor.a} | targets], else: targets
      retirement_page(budget - 1, %{cursor | level: :allocation}, targets)
    end
  end

  defp retire_empty_allocation(id) do
    Repo.transaction(fn ->
      allocation =
        Repo.one!(from(a in Compute.Allocation, where: a.id == ^id, lock: "FOR UPDATE"))

      binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)
      registration = Repo.get!(SalixStore.AgentVMM.Registration, binding.provider_ref)

      if binding.provider == "agent_vmm" and registration.status == "revoked" and
           not Repo.exists?(from(w in Compute.Workload, where: w.allocation_id == ^id)) do
        cancel_undelivered_page!(id)
        retire_allocation!(allocation)
      end
    end)
  end

  defp cancel_undelivered_page!(allocation_id) do
    ids =
      from(c in Compute.Command,
        where:
          c.allocation_id == ^allocation_id and c.status == "pending" and
            is_nil(c.delivery_started_at),
        order_by: c.id,
        limit: 32,
        select: c.id
      )

    Repo.update_all(from(c in Compute.Command, where: c.id in subquery(ids)),
      set: [
        status: "cancelled",
        outcome: "failed",
        updated_at: SystemsClock.timestamp(:utc_datetime_usec)
      ]
    )
  end

  defp retire_allocation!(allocation) do
    now = SystemsClock.utc_now()

    Repo.update_all(
      from(a in Compute.Allocation,
        where:
          a.id == ^allocation.id and
            fragment("COALESCE(?->>'cloud_retired', 'false') <> 'true'", a.provider_observation)
      ),
      set: [
        status: "released",
        provider_observation:
          Map.put(allocation.provider_observation || %{}, "cloud_retired", true),
        updated_at: now
      ],
      inc: [revision: 1]
    )
  end

  defp retire_cloud!(allocation, workload, registration) do
    now = SystemsClock.utc_now()

    retire_allocation!(allocation)

    Repo.update_all(
      from(r in Compute.RuntimeInstance,
        where:
          r.workload_id == ^workload.id and r.generation == ^workload.generation and
            (r.status != "closed" or r.readiness != "pending")
      ),
      set: [status: "closed", readiness: "pending", updated_at: now],
      inc: [revision: 1]
    )

    deletion =
      if workload.kind == "shell" and not business_reference?(workload) and
           (workload.deletion || %{})["phase"] not in ["complete", "cloud_retired"] do
        Map.merge(
          workload.deletion ||
            %{
              "request_id" => "retire:" <> registration.id,
              "generation" => workload.generation,
              "allocation_id" => allocation.id,
              "provider_binding_id" => allocation.provider_binding_id,
              "registration_id" => registration.id,
              "requested_at" => DateTime.to_iso8601(now)
            },
          %{
            "phase" => "cloud_retired",
            "proof" => "registration_retired",
            "local_data_deleted" => false,
            "completed_at" => DateTime.to_iso8601(now),
            "error" => nil
          }
        )
      else
        workload.deletion
      end

    # Business owners and update/result records survive loss of this provider.
    # desired_state stops cloud reconciliation; observed_state is not a Host stop receipt.
    update =
      if ComputeWorkloadUpdate.active?(workload),
        do:
          Map.merge(workload.runtime_update, %{
            "phase" => "cancelled",
            "error" => "registration_revoked"
          }),
        else: workload.runtime_update

    if deletion != workload.deletion or workload.desired_state != "stopped" or
         update != workload.runtime_update,
       do: save(workload, deletion, desired_state: "stopped", runtime_update: update)
  end

  def advance(allocation, workload) do
    ComputeWorkloadUpdate.with_lock(workload.id, fn ->
      current =
        Repo.one!(from(w in Compute.Workload, where: w.id == ^workload.id, lock: "FOR UPDATE"))

      allocation = Repo.get!(Compute.Allocation, allocation.id)

      cond do
        current.deletion["phase"] in ["complete", "cloud_retired"] ->
          {:ok, %{outcome: :succeeded}}

        accepted_work?(current) ->
          waiting(current, "settling_work", "accepted_work_pending")

        allocation.id != current.deletion["allocation_id"] or
            allocation.generation != current.deletion["generation"] ->
          waiting(current, "locating_data", "allocation_scope_changed")

        never_dispatched?(allocation) ->
          settle_allocation!(allocation, current)
          finish(current, "never_dispatched")
          {:ok, %{outcome: :succeeded}}

        true ->
          enqueue(allocation, current)
      end
    end)
  end

  defp accepted_work?(workload) do
    Repo.exists?(
      from(c in Compute.Command,
        where:
          c.allocation_id == ^workload.allocation_id and c.kind != "allocation.dispose" and
            c.status in ["pending", "admitted", "executing", "unknown_outcome"]
      )
    ) or
      Repo.exists?(
        from(i in ComputeRuntimeCarrier.Input,
          where: i.workload_id == ^workload.id and i.status in ["pending", "in_flight"]
        )
      )
  end

  defp waiting(workload, phase, error) do
    save(workload, Map.merge(workload.deletion, %{"phase" => phase, "error" => error}))
    {:ok, %{outcome: :pending}}
  end

  defp never_dispatched?(allocation) do
    allocation.dispatch_protocol == "registration_commands" and
      allocation.status in ["pending", "allocating"] and
      (allocation.provider_observation || %{}) == %{} and
      not Repo.exists?(
        from(c in Compute.Command,
          where:
            c.allocation_id == ^allocation.id and
              (c.kind != "allocation.ensure" or c.status != "cancelled" or
                 not is_nil(c.delivery_started_at))
        )
      )
  end

  defp enqueue(allocation, workload) do
    observation = allocation.provider_observation || %{}
    deletion = workload.deletion
    previous = Repo.get(Compute.Command, deletion["host_request_id"])

    binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)

    connection =
      Repo.get(SalixStore.AgentVMM.RegistrationObservation, deletion["registration_id"])

    current_connection =
      connection && is_nil(connection.disconnected_at) &&
        connection.connection_epoch == (binding.observation || %{})["connection_epoch"]

    unsupported =
      current_connection &&
        "allocation-disposal-v1" not in (connection.supported_features || [])

    if unsupported ||
         (!current_connection && previous && previous.status == "failed" &&
            get_in(previous.evidence, ["result", "reason"]) == "ERROR_REASON_FEATURE_MISMATCH") do
      waiting(workload, "cleaning", "host_update_required")
    else
      enqueue_supported(allocation, workload, observation, deletion, previous, current_connection)
    end
  end

  defp enqueue_supported(
         allocation,
         workload,
         observation,
         deletion,
         previous,
         current_connection
       ) do
    rejected =
      if previous, do: get_in(previous.evidence, ["result", "allocation"]) || %{}, else: %{}

    rejected_before_acceptance? =
      previous && previous.status == "failed" &&
        get_in(previous.evidence, ["result", "reason"]) ==
          "ERROR_REASON_DISPOSAL_REVISION_NOT_ACCEPTED" &&
        rejected["allocationId"] == allocation.id &&
        to_string(rejected["generation"]) == to_string(allocation.generation)

    revision =
      if rejected_before_acceptance?,
        do: integer_revision(rejected["revision"]),
        else: deletion["host_revision"] || observation["allocation_revision"]

    binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)

    if binding.id != deletion["provider_binding_id"] or
         binding.provider_ref != deletion["registration_id"],
       do: Repo.rollback(:allocation_scope_changed)

    if not is_integer(revision) or revision <= 0 do
      waiting(workload, "locating_data", "host_inventory_required")
    else
      request = deletion["host_request_id"]
      id = request
      deadline = DateTime.add(SystemsClock.utc_now(), 60, :second)

      with {:ok, command} <-
             Compute.enqueue_command(%{
               id: id,
               allocation_id: allocation.id,
               workload_id: workload.id,
               request_id: request,
               operation_id: deletion["request_id"],
               kind: "allocation.dispose",
               classification: "desired_state",
               target_generation: allocation.generation,
               target_revision: allocation.revision,
               deadline_at: deadline,
               payload: %{
                 "workload_generation" => workload.generation,
                 "command_json" => %{
                   "commandId" => id,
                   "deadlineUnixMillis" => DateTime.to_unix(deadline, :millisecond),
                   "targetRevision" => revision,
                   "disposeAllocation" => %{
                     "allocationId" => allocation.id,
                     "expectedRevision" => revision,
                     "expectedGeneration" => allocation.generation,
                     "requestId" => request
                   }
                 }
               }
             }) do
        save(
          workload,
          Map.merge(deletion, %{
            "phase" => "cleaning",
            "host_revision" => revision,
            "error" => if(current_connection, do: nil, else: "original_device_offline")
          })
        )

        {:ok, %{outcome: :pending, command: command}}
      end
    end
  end

  defp integer_revision(value) when is_integer(value), do: value

  defp integer_revision(value) when is_binary(value) do
    case Integer.parse(value) do
      {revision, ""} -> revision
      _ -> nil
    end
  end

  defp integer_revision(_), do: nil

  def complete(command, evidence) do
    result = get_in(evidence, ["result", "allocation"]) || %{}

    workload =
      Repo.one!(
        from(w in Compute.Workload, where: w.id == ^command.workload_id, lock: "FOR UPDATE")
      )

    allocation =
      Repo.one!(
        from(a in Compute.Allocation, where: a.id == ^command.allocation_id, lock: "FOR UPDATE")
      )

    deletion = workload.deletion || %{}

    if deletion["request_id"] != command.operation_id or
         deletion["allocation_id"] != command.allocation_id or
         deletion["generation"] != workload.generation or
         result["allocationId"] != command.allocation_id or
         to_string(result["generation"]) != to_string(command.target_generation) or
         to_string(result["revision"]) != to_string(deletion["host_revision"]) or
         result["state"] != "ALLOCATION_STATE_DISCARDED" or
         allocation.revision != command.target_revision do
      {:error, :invalid_host_result}
    else
      settle_allocation!(allocation, workload)
      finish(workload, "host_disposal")
      :ok
    end
  end

  defp settle_allocation!(allocation, workload) do
    binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)
    deletion = workload.deletion

    if allocation.id != deletion["allocation_id"] or
         allocation.generation != deletion["generation"] or
         binding.id != deletion["provider_binding_id"] or
         binding.provider_ref != deletion["registration_id"],
       do: Repo.rollback(:allocation_scope_changed)

    Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        status: "released",
        operation_outcome: "succeeded",
        provider_observation:
          Map.put(allocation.provider_observation || %{}, "data_deleted", true),
        updated_at: SystemsClock.timestamp(:utc_datetime_usec)
      ],
      inc: [revision: 1]
    )

    Repo.update_all(from(r in Compute.RuntimeInstance, where: r.workload_id == ^workload.id),
      set: [
        status: "closed",
        readiness: "pending",
        updated_at: SystemsClock.timestamp(:utc_datetime_usec)
      ],
      inc: [revision: 1]
    )
  end

  defp finish(workload, proof) do
    save(
      workload,
      Map.merge(workload.deletion, %{
        "phase" => "complete",
        "proof" => proof,
        "completed_at" => DateTime.to_iso8601(SystemsClock.utc_now()),
        "error" => nil
      }),
      desired_state: "stopped",
      observed_state: "stopped"
    )
  end

  defp save(workload, deletion, extra \\ []) do
    if deletion != workload.deletion or extra != [] do
      Repo.update_all(from(w in Compute.Workload, where: w.id == ^workload.id),
        set:
          [deletion: deletion, updated_at: SystemsClock.timestamp(:utc_datetime_usec)] ++ extra,
        inc: [revision: 1]
      )
    end
  end
end
