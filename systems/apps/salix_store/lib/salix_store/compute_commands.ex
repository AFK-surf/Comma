defmodule SalixStore.ComputeCommands do
  @moduledoc """
  Postgres storage for the provider command queue of `SalixStore.Compute`.

  `SalixStore.Compute` owns the queue's rules: which generation and revision
  a command may target, when a request id may be reissued, which states a
  result may leave. This module only reads and writes the rows those rules
  name.
  Every function except `transaction/1` runs inside the caller's transaction
  where the rules need one; store faults raise, and `SalixStore.Compute`
  answers them as `{:error, :unavailable}`.
  """

  import Ecto.Query

  alias SalixStore.Compute.{Allocation, Command, Environment, ProviderBinding}
  alias SalixStore.Repo

  @doc "Runs `fun` in one transaction, as `Repo.transaction/1`."
  def transaction(fun), do: Repo.transaction(fun)

  @doc "Ends the current transaction with `{:error, reason}`."
  def rollback(reason), do: Repo.rollback(reason)

  @doc "The allocation, locked for the rest of the transaction, or nil."
  def lock_allocation(id),
    do: Repo.one(from(a in Allocation, where: a.id == ^id, lock: "FOR UPDATE"))

  def get_environment(id), do: Repo.get(Environment, id)

  @doc "Inserts `row` unless its `(allocation_id, request_id)` exists: `:created` or `:exists`."
  def insert(row) do
    case Repo.insert_all(Command, [row],
           on_conflict: :nothing,
           conflict_target: [:allocation_id, :request_id]
         ) do
      {1, _} -> :created
      {0, _} -> :exists
    end
  end

  def get(id), do: Repo.get(Command, id)
  def get!(id), do: Repo.get!(Command, id)

  @doc "The command of one request, locked."
  def lock_by_request!(allocation_id, request_id) do
    Repo.one!(
      from(c in Command,
        where: c.allocation_id == ^allocation_id and c.request_id == ^request_id,
        lock: "FOR UPDATE"
      )
    )
  end

  @doc "Sets `fields` on the command `id`, which must exist."
  def update!(id, fields) do
    {1, _} = Repo.update_all(from(c in Command, where: c.id == ^id), set: fields)
    :ok
  end

  @doc """
  Pending commands of one binding's current allocations, oldest first,
  locked and skipped when another transaction holds them.
  """
  def claimable(provider_binding_id, generation, now, limit) do
    Repo.all(
      from(c in Command,
        join: a in Allocation,
        on: a.id == c.allocation_id,
        where:
          a.provider_binding_id == ^provider_binding_id and a.generation == ^generation and
            a.status != "released" and
            c.target_generation == a.generation and c.target_revision == a.revision and
            c.status == "pending" and c.deadline_at > ^now,
        order_by: [asc: c.created_at, asc: c.id],
        limit: ^limit,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  def set_status(ids, status, now) do
    Repo.update_all(from(c in Command, where: c.id in ^ids),
      set: [status: status, updated_at: now]
    )

    :ok
  end

  @doc """
  Sets `fields` on command `id` when it is not an allocation release and is in
  one of `from_states`. Returns the number of rows written.
  """
  def transition(id, from_states, fields) do
    {count, _} =
      Repo.update_all(
        from(c in Command,
          where: c.id == ^id and c.kind != "allocation.release" and c.status in ^from_states
        ),
        set: fields
      )

    count
  end

  @doc """
  Sets `fields` on the admitted or executing commands of the current
  generation of every allocation `scope` names (`{:binding, id}` or
  `{:provider, provider, provider_ref}`), in `classifications`. Returns the
  number of rows written.
  """
  def update_in_flight(scope, classifications, fields) do
    {count, _} =
      scope
      |> in_flight()
      |> where([c], c.classification in ^classifications)
      |> Repo.update_all(set: fields)

    count
  end

  defp in_flight({:binding, provider_binding_id}) do
    from(c in Command,
      join: a in Allocation,
      on: a.id == c.allocation_id,
      where:
        a.provider_binding_id == ^provider_binding_id and
          c.target_generation == a.generation and c.status in ["admitted", "executing"]
    )
  end

  defp in_flight({:provider, provider, provider_ref}) do
    from(c in Command,
      join: a in Allocation,
      on: a.id == c.allocation_id,
      join: b in ProviderBinding,
      on: b.id == a.provider_binding_id,
      where:
        b.provider == ^provider and b.provider_ref == ^provider_ref and
          c.target_generation == a.generation and c.status in ["admitted", "executing"]
    )
  end
end
