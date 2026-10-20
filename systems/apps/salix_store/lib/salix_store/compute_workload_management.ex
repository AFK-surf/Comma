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

  def rename(tenant, project, id, revision, value, authorize) do
    with {:ok, normalized} when not is_nil(normalized) <- name(value) do
      Repo.transaction(fn ->
        workload =
          Repo.one(from(w in owned_query(tenant, project, id), lock: "FOR UPDATE OF c0")) ||
            Repo.rollback(:not_found)

        if authorize.() != :ok, do: Repo.rollback(:not_found)
        if workload.revision != revision, do: Repo.rollback(:revision_conflict)

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

  def retry(tenant, project, id, revision, generation, authorize) do
    Repo.transaction(fn ->
      workload =
        Repo.one(from(w in owned_query(tenant, project, id), lock: "FOR UPDATE OF c0")) ||
          Repo.rollback(:not_found)

      if authorize.() != :ok, do: Repo.rollback(:not_found)

      if workload.revision != revision or workload.generation != generation,
        do: Repo.rollback(:revision_conflict)

      if workload.kind != "shell", do: Repo.rollback(:business_owner_required)
      allocation = Repo.get!(Compute.Allocation, workload.allocation_id)
      binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)
      if binding.provider != "agent_vmm", do: Repo.rollback(:unsupported_provider)

      if SalixStore.ComputeWorkloadUpdate.active?(workload),
        do: Repo.rollback(:update_in_progress)

      if workload.deletion || workload.desired_state != "ready",
        do: Repo.rollback(:deletion_in_progress)

      if Repo.exists?(
           from(c in Compute.Command,
             where:
               c.workload_id == ^id and c.target_generation == ^generation and
                 c.status == "unknown_outcome"
           )
         ),
         do: Repo.rollback(:unknown_outcome)

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

      # Reopen observation of the same desired operation. No command, credential,
      # allocation, or execution identity is replaced by a foreground retry.
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
    end)
  end
end
