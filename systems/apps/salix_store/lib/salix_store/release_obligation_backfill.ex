defmodule SalixStore.ReleaseObligationBackfill do
  @moduledoc """
  One-time keyset backfill and final audit for allocation-owned release Commands.

  This module has no timer or runtime registration. Operators advance the
  returned immutable Allocation id cursor until completion and remove the
  rollout step after the final zero-issue audit.
  """

  import Ecto.Query

  alias SalixStore.{Compute, Repo}

  @max_page 500

  def backfill_page(after_id \\ nil, limit \\ 100)
      when (is_nil(after_id) or is_binary(after_id)) and limit in 1..@max_page do
    page = allocation_page(after_id, limit)
    allocations = page
    now = DateTime.utc_now()

    results =
      Enum.map(allocations, fn allocation ->
        {allocation.id, Compute.backfill_release_obligation(allocation.id, now)}
      end)

    %{
      cursor: cursor(page, after_id),
      done?: length(page) < limit,
      scanned: length(page),
      processed: length(allocations),
      inserted: Enum.count(results, &match?({_id, {:ok, :inserted}}, &1)),
      adopted: Enum.count(results, &match?({_id, {:ok, :adopted}}, &1)),
      restored: Enum.count(results, &match?({_id, {:ok, :restored}}, &1)),
      present: Enum.count(results, &match?({_id, {:ok, :present}}, &1)),
      not_required: Enum.count(results, &match?({_id, {:ok, :not_required}}, &1)),
      issues: for({id, {:error, reason}} <- results, do: %{allocation_id: id, reason: reason})
    }
  end

  def audit_page(after_id \\ nil, limit \\ 100)
      when (is_nil(after_id) or is_binary(after_id)) and limit in 1..@max_page do
    page = allocation_page(after_id, limit)
    allocations = page

    issues =
      Enum.flat_map(allocations, fn allocation ->
        binding = Repo.get!(Compute.ProviderBinding, allocation.provider_binding_id)
        release_required? = release_required?(allocation, binding)
        incarnation = Compute.release_incarnation(allocation.id, allocation.generation)

        commands =
          Repo.all(
            from(c in Compute.Command,
              where: c.allocation_id == ^allocation.id and c.kind == "allocation.release",
              order_by: [asc: c.id]
            )
          )

        case {binding.provider, commands} do
          {provider, [_ | _]} when provider != "agent_vmm" ->
            [%{allocation_id: allocation.id, reason: :unsupported_provider_release_obligation}]

          {_provider,
           [
             %Compute.Command{
               workload_id: nil,
               target_generation: generation,
               target_revision: _target_revision,
               status: status,
               release_incarnation: ^incarnation
             }
           ]}
          when generation == allocation.generation and
                 status != "cancelled" and
                 not (status == "succeeded" and allocation.status not in ["released", "failed"]) ->
            []

          {_provider, []} when release_required? ->
            [%{allocation_id: allocation.id, reason: :missing_release_obligation}]

          {_provider, []} ->
            []

          {_provider, [_]} ->
            [%{allocation_id: allocation.id, reason: :invalid_release_obligation}]

          {_provider, _} ->
            [%{allocation_id: allocation.id, reason: :duplicate_release_obligations}]
        end
      end)

    %{
      cursor: cursor(page, after_id),
      done?: length(page) < limit,
      scanned: length(page),
      audited: length(allocations),
      issues: issues
    }
  end

  # Page the authoritative table by its primary key before filtering. This
  # bounds database work even when release candidates are sparse and avoids a
  # rollout-only partial index that would survive after the backfill is gone.
  defp allocation_page(after_id, limit) do
    query =
      from(a in Compute.Allocation,
        order_by: [asc: a.id],
        limit: ^limit
      )

    query = if is_nil(after_id), do: query, else: where(query, [a], a.id > ^after_id)
    Repo.all(query)
  end

  defp release_required?(allocation, binding) do
    binding.provider == "agent_vmm" and
      (allocation.status == "draining" or
         (allocation.status == "ready" and
            Map.get(allocation.provider_observation || %{}, "allocation_state") == "retained"))
  end

  defp cursor([], fallback), do: fallback
  defp cursor(allocations, _fallback), do: List.last(allocations).id
end
