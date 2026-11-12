defmodule SalixStore.ComputeWorkloadManagement do
  @moduledoc false
  import Ecto.Query
  alias SalixStore.{Compute, Repo}

  def name(nil), do: {:ok, nil}

  def name(value) when is_binary(value) do
    value = String.trim(value)

    if String.valid?(value) and String.length(value) in 1..80 and
         not Regex.match?(~r/[\x00-\x1f\x7f]/u, value),
       do: {:ok, value},
       else: {:error, :invalid_name}
  end

  def name(_), do: {:error, :invalid_name}

  def owned_query(tenant, project, id) do
    from(w in Compute.Workload,
      join: e in Compute.Environment,
      on: e.id == w.environment_id,
      where:
        w.id == ^id and e.tenant_id == ^tenant and e.owner_type == "project" and
          e.owner_id == ^project,
      select: w
    )
  end

  # Last writer wins: a name has no ordering with other Workload facts.
  def rename(tenant, project, id, value, authorize) do
    with {:ok, normalized} when not is_nil(normalized) <- name(value) do
      Repo.transaction(fn ->
        _workload =
          Repo.one(from(w in owned_query(tenant, project, id), lock: "FOR UPDATE OF c0")) ||
            Repo.rollback(:not_found)

        if authorize.() != :ok, do: Repo.rollback(:not_found)

        Repo.update_all(from(w in Compute.Workload, where: w.id == ^id),
          set: [name: normalized, updated_at: SystemsClock.timestamp(:utc_datetime_usec)],
          inc: [revision: 1]
        )

        Repo.get!(Compute.Workload, id)
      end)
    else
      _ -> {:error, :invalid_name}
    end
  end

  @doc """
  Whether a member's Retry may reopen this Workload: a Shell, or the Group's
  own Station (`SalixStore.ComputeGroupStation`), which no other owner brings
  back from `action_required`. Other business owners recover their own.
  """
  def member_retryable?(workload), do: workload.kind == "shell" or group_station?(workload)

  defp group_station?(workload),
    do:
      workload.kind == "service" and workload.template_key == "station.default" and
        match?(%{"kind" => "group"}, workload.owner_ref)

  def retry(tenant, project, id, generation, authorize) do
    Repo.transaction(fn ->
      workload =
        Repo.one(from(w in owned_query(tenant, project, id), lock: "FOR UPDATE OF c0")) ||
          Repo.rollback(:not_found)

      if authorize.() != :ok, do: Repo.rollback(:not_found)

      if workload.generation != generation, do: Repo.rollback(:revision_conflict)

      if not member_retryable?(workload), do: Repo.rollback(:business_owner_required)

      reopen!(workload)
    end)
  end

  # Host-side failures that a new Host connection can clear. Other parked
  # errors need a person to look first.
  @healable_codes ~w(provider_command_failed provider_command_outcome_unknown)

  @doc """
  Reopens the Group Station once its Host connects again, when its current
  generation is parked on a Host-side failure. Answers `:ok` when nothing
  needs reopening.
  """
  def heal_group_station(workload_id) do
    Repo.transaction(fn ->
      workload =
        Repo.one(from(w in Compute.Workload, where: w.id == ^workload_id, lock: "FOR UPDATE")) ||
          Repo.rollback(:not_found)

      parked =
        Repo.one(
          from(c in Compute.ReconcilerClaim,
            where: c.workload_id == ^workload.id and c.generation == ^workload.generation,
            select: c.last_error
          )
        ) || %{}

      if group_station?(workload) and parked["kind"] == "action_required" and parked["code"] in @healable_codes,
         do: reopen!(workload),
         else: :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:ok, %Compute.Workload{}} -> :ok
      {:error, _} = error -> error
    end
  end

  # The reopen preserves commands and their outcomes. A parked allocation
  # projection can authorize one new desired-state attempt on the same target.
  defp reopen!(workload) do
    id = workload.id
    generation = workload.generation

    allocation =
      Repo.one!(
        from(a in Compute.Allocation,
          where: a.id == ^workload.allocation_id,
          lock: "FOR UPDATE"
        )
      )

    environment = Repo.get!(Compute.Environment, allocation.environment_id)
    binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)
    if binding.provider != "agent_vmm", do: Repo.rollback(:unsupported_provider)

    if SalixStore.ComputeWorkloadUpdate.active?(workload),
      do: Repo.rollback(:update_in_progress)

    if workload.deletion || workload.desired_state != "ready",
      do: Repo.rollback(:deletion_in_progress)

    if allocation.status == "released" or allocation.generation != environment.generation or
         environment.desired_state != "ready" or binding.status == "revoked" or
         (allocation.provider_observation || %{})["allocation_state"] in [
           "retained",
           "discarded"
         ] or
         Compute.allocation_release_requested?(allocation),
       do: Repo.rollback(:allocation_scope_changed)

    now = SystemsClock.utc_now()

    claim =
      Repo.one(
        from(c in Compute.ReconcilerClaim,
          where: c.workload_id == ^id and c.generation == ^generation,
          lock: "FOR UPDATE"
        )
      )

    if claim && claim.lease_expires_at && DateTime.compare(claim.lease_expires_at, now) == :gt,
      do: Repo.rollback(:update_in_progress)

    retry_allocation_projection!(allocation, workload, claim, now)

    # Reopen observation without replacing the allocation or execution identity.
    Repo.update_all(
      from(c in Compute.ReconcilerClaim,
        where: c.workload_id == ^id and c.generation == ^generation
      ),
      set: [last_error: %{}, next_retry_at: now, updated_at: now]
    )

    Repo.update_all(from(w in Compute.Workload, where: w.id == ^id),
      set: [observed_state: "pending", updated_at: now],
      inc: [revision: 1]
    )

    Repo.get!(Compute.Workload, id)
  end

  defp retry_allocation_projection!(allocation, workload, claim, now) do
    error = (claim && claim.last_error) || %{}

    if allocation.status != "ready" and error["kind"] == "action_required" and
         error["resource"] == "storage_headroom" do
      command =
        Repo.one(
          from(c in Compute.Command,
            where:
              c.allocation_id == ^allocation.id and c.workload_id == ^workload.id and
                c.kind == "allocation.ensure" and c.target_generation == ^allocation.generation,
            order_by: [desc: c.target_revision, desc: c.created_at, desc: c.id],
            limit: 1,
            lock: "FOR UPDATE"
          )
        )

      if command && command.status == "unknown_outcome" do
        ensure = get_in(command.payload || %{}, ["command_json", "ensureAllocation"])
        resources = (workload.spec || %{})["resources"] || %{}
        binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)
        pool = Repo.get!(Compute.Pool, binding.pool_id)
        intent = Map.merge(pool.provider_policy || %{}, workload.spec || %{})

        egress =
          if intent["egress_mode"] == "deny_all",
            do: "EGRESS_MODE_DENY_ALL",
            else: "EGRESS_MODE_PUBLIC_INTERNET"

        unless command.classification == "desired_state" and
                 (allocation.provider_observation || %{})["allocation_state"] == "draining" and
                 get_in(command.evidence || %{}, ["result", "capacityDimension"]) ==
                   "CAPACITY_DIMENSION_STORAGE_HEADROOM" and is_map(ensure) and
                 ensure["allocationId"] == allocation.id and
                 ensure["generation"] == allocation.generation and
                 ensure["egressMode"] == egress and
                 ensure["limits"] == %{
                   "pids" => resources["pid_max"],
                   "diskBytes" => resources["writable_quota_bytes"]
                 },
               do: Repo.rollback(:allocation_scope_changed)

        # Model anchor: ComputeCapacityAction.OperatorRetries. The new revision
        # changes only desired-state command deduplication. Old UNKNOWN evidence
        # and allocation generation remain intact.
        Repo.update_all(from(a in Compute.Allocation, where: a.id == ^allocation.id),
          set: [status: "allocating", operation_outcome: "pending", updated_at: now],
          inc: [revision: 1]
        )
      end
    end
  end
end
