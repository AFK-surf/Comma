defmodule SalixAgent.SubscriptionQuotaWorker do
  @moduledoc false
  use GenServer
  alias SalixAgent.{AccountPool, SubscriptionStore}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_), do: {:ok, schedule()}
  defp schedule, do: Process.send_after(self(), :poll, 30_000)

  def handle_info(:poll, _state) do
    if Application.get_env(:salix_agent, :subscription_storage_key) do
      # Each node claims at most four due rows. The claim skips rows another
      # worker holds; network work occurs after the short transaction commits.
      sql = """
      WITH due AS (
        SELECT tenant_id,id FROM subscription_accounts
        WHERE next_poll_at<=now() AND value->>'credential_kind'='subscription_oauth'
          AND value->>'disabled'='false' AND value->>'status'='active'
        ORDER BY next_poll_at,tenant_id,id LIMIT 4 FOR UPDATE SKIP LOCKED
      ) UPDATE subscription_accounts a SET next_poll_at=now()+interval '5 minutes'
        FROM due WHERE a.tenant_id=due.tenant_id AND a.id=due.id RETURNING a.tenant_id,a.id
      """

      case SubscriptionStore.query(sql, []) do
        {:ok, %{rows: rows}} ->
          Task.async_stream(
            rows,
            fn [tenant, id] ->
              case AccountPool.quota(tenant, id) do
                {:ok, _} ->
                  SubscriptionStore.query(
                    "UPDATE subscription_accounts SET poll_delay_seconds=0 WHERE tenant_id=$1 AND id=$2",
                    [tenant, id]
                  )

                _ ->
                  SubscriptionStore.query(
                    "UPDATE subscription_accounts SET poll_delay_seconds=LEAST(7200,GREATEST(900,poll_delay_seconds*2)), next_poll_at=now()+LEAST(7200,GREATEST(900,poll_delay_seconds*2))*interval '1 second' WHERE tenant_id=$1 AND id=$2",
                    [tenant, id]
                  )
              end
            end,
            max_concurrency: 4,
            timeout: 45_000,
            on_timeout: :kill_task
          )
          |> Stream.run()

        _ ->
          :ok
      end

      SubscriptionStore.query(
        "DELETE FROM subscription_oauth_attempts WHERE (tenant_id,id) IN (SELECT tenant_id,id FROM subscription_oauth_attempts WHERE expires_at<now() ORDER BY expires_at LIMIT 100)",
        []
      )
    end

    {:noreply, schedule()}
  end
end
