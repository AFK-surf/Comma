defmodule SalixStore.Repo.Migrations.CreateSlackTriageThreadSubscriptions do
  use Ecto.Migration

  def change do
    create table(:slack_triage_thread_subscriptions, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:connect_generation, :text, primary_key: true)
      add(:workspace_id, :text, primary_key: true)
      add(:channel_id, :text, primary_key: true)
      add(:root_thread_ts, :text, primary_key: true)
      add(:agent_id, :text, primary_key: true)
      add(:activated_by_obligation_id, :text, null: false)
      add(:activated_by_message_id, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(
        :slack_triage_thread_subscriptions,
        :slack_triage_thread_subscriptions_shape,
        check: """
        btrim(tenant_id) <> '' AND
        btrim(group_id) <> '' AND
        btrim(connect_id) <> '' AND
        btrim(connect_generation) <> '' AND
        btrim(workspace_id) <> '' AND
        btrim(channel_id) <> '' AND
        root_thread_ts ~ '^[0-9]{1,12}\\.[0-9]{6}$' AND
        btrim(agent_id) <> '' AND
        activated_by_obligation_id ~ '^triage-product-[0-9a-f]{64}$' AND
        btrim(activated_by_message_id) <> ''
        """
      )
    )
  end
end
