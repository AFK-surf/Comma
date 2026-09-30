defmodule SalixAgent.ExternalWorkerOperationReconciler do
  @moduledoc """
  Bounded recovery owner for compute external-worker operations.

  The retired tool committed placement before crossing into AgentControl. This
  process owns the durable retry path after a crash between those stores; it
  never scans workers to rediscover intent and never creates a worker without a
  committed Workload.
  """

  # Model anchor: tla/salix/ExternalWorkerProvisioning.tla.

  use GenServer

  import Ecto.Query

  alias SalixAgent.LegacyWorkerOperation
  alias SalixStore.{Compute, Repo}

  @batch_size 32
  @per_scope_batch 4
  @default_interval_ms 5_000
  @claim_lease_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    send(self(), :sweep)
    {:ok, interval_ms}
  end

  @impl true
  def handle_info(:sweep, interval_ms) do
    more? = sweep(@batch_size) == :more
    Process.send_after(self(), :sweep, if(more?, do: 0, else: interval_ms))
    {:noreply, interval_ms}
  end

  @doc "Run one bounded pass over durable operations that are not complete."
  def sweep(limit \\ @batch_size) when limit in 1..@batch_size do
    operations = claim_operations(limit)

    Enum.each(operations, fn operation ->
      _ = reconcile(operation)
    end)

    if length(operations) == limit, do: :more, else: :complete
  rescue
    _ -> :complete
  end

  defp reconcile(operation) do
    attrs = %{
      tenant_id: operation.tenant_id,
      group_id: operation.group_id,
      operation_hash: operation.operation_hash,
      tool_call_id: operation.tool_call_id,
      environment_id: operation.environment_id,
      provider: operation.provider,
      template_key: operation.template_key,
      allocation_id: operation.allocation_id || "allocation_" <> operation.operation_hash,
      workload_id: operation.workload_id || "workload_" <> operation.operation_hash
    }

    case Compute.ensure_external_worker_placement(attrs) do
      {:ok, %{operation: operation}} ->
        case LegacyWorkerOperation.finish(operation) do
          {:ok, _worker_id} ->
            :ok

          {:error, reason} = error ->
            _ =
              Compute.record_external_worker_operation_error(
                operation.id,
                reason,
                operation.claim_token
              )

            error
        end

      {:error, reason} = error ->
        _ =
          Compute.record_external_worker_operation_error(
            operation.id,
            reason,
            operation.claim_token
          )

        error
    end
  end

  defp claim_operations(limit) do
    now = DateTime.utc_now()
    lease_expires_at = DateTime.add(now, @claim_lease_ms, :millisecond)

    ranked =
      from(o in Compute.ExternalWorkerOperation,
        where:
          o.state != "worker_ready" and
            (is_nil(o.next_retry_at) or o.next_retry_at <= ^now) and
            (is_nil(o.lease_expires_at) or o.lease_expires_at <= ^now),
        select: %{
          id: o.id,
          tenant_id: o.tenant_id,
          provider: o.provider,
          updated_at: o.updated_at,
          scope_rank:
            fragment(
              "row_number() OVER (PARTITION BY ? , ? ORDER BY ? ASC, ? ASC)",
              o.tenant_id,
              o.provider,
              o.updated_at,
              o.id
            )
        }
      )

    ids =
      Repo.all(
        from(r in subquery(ranked),
          where: r.scope_rank <= ^@per_scope_batch,
          order_by: [asc: r.tenant_id, asc: r.provider, asc: r.updated_at, asc: r.id],
          limit: ^limit,
          select: r.id
        )
      )

    ids
    |> Enum.map(fn id -> claim_operation(id, now, lease_expires_at) end)
    |> Enum.reject(&is_nil/1)
  end

  defp claim_operation(id, now, lease_expires_at) do
    token = Ecto.UUID.generate()

    {count, _} =
      Repo.update_all(
        from(o in Compute.ExternalWorkerOperation,
          where:
            o.id == ^id and o.state != "worker_ready" and
              (is_nil(o.next_retry_at) or o.next_retry_at <= ^now) and
              (is_nil(o.lease_expires_at) or o.lease_expires_at <= ^now)
        ),
        set: [claim_token: token, lease_expires_at: lease_expires_at, updated_at: now]
      )

    if count == 1, do: Repo.get!(Compute.ExternalWorkerOperation, id)
  end
end
