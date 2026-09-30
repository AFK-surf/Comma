defmodule SalixWeb.SubscriptionRuntimeWorker do
  @moduledoc false
  use GenServer
  alias SalixAgent.SubscriptionStore

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_), do: {:ok, schedule()}
  defp schedule, do: Process.send_after(self(), :deliver, 10_000)

  defp deliver([tenant, nil, nil, nil, workload]),
    do: SalixWeb.ComputeSubscriptionAuth.deliver(tenant, workload)

  defp deliver([tenant, group, device, runtime, nil]),
    do: SalixWeb.SubscriptionRuntimeAuth.deliver([tenant, group, device, runtime])

  def handle_info(:deliver, _) do
    # One timer per node, four indexed rows per batch, four concurrent deliveries.
    # The lease outlives the bounded task. Three failures require a new admission
    # or explicit operator retry instead of an unlimited delivery retry loop.
    case SubscriptionStore.query(
           """
           WITH due AS (
             SELECT id
             FROM runtime_subscription_bindings
             WHERE status IN ('pending','ready','account_unavailable') AND next_delivery_at<=now()
             ORDER BY next_delivery_at LIMIT 4 FOR UPDATE SKIP LOCKED
           ) UPDATE runtime_subscription_bindings b SET next_delivery_at=now()+interval '90 seconds', failures=b.failures+1,
             status=CASE WHEN b.failures>=2 THEN 'delivery_failed' ELSE b.status END
             FROM due WHERE b.id=due.id
             RETURNING b.tenant_id,b.group_id,b.device_id,b.device_runtime_id,b.workload_id
           """,
           []
         ) do
      {:ok, %{rows: rows}} ->
        Task.async_stream(rows, &deliver/1,
          max_concurrency: 4,
          timeout: 60_000,
          on_timeout: :kill_task
        )
        |> Stream.run()

      _ ->
        :ok
    end

    {:noreply, schedule()}
  end
end
