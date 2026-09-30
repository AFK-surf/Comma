defmodule SalixStore.Repo.Migrations.AddSlackTriageProviderMessageRef do
  use Ecto.Migration

  def up do
    drop(
      constraint(
        :slack_triage_thread_subscriptions,
        :slack_triage_thread_subscriptions_shape
      )
    )

    alter table(:slack_triage_thread_subscriptions) do
      modify(:activated_by_message_id, :text, null: true)
      add(:activated_by_provider_message_ref, :text, null: true)
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
        num_nonnulls(activated_by_message_id, activated_by_provider_message_ref) = 1 AND
        (activated_by_message_id IS NULL OR btrim(activated_by_message_id) <> '') AND
        (activated_by_provider_message_ref IS NULL OR
          activated_by_provider_message_ref ~ '^slack:[0-9]{1,12}\\.[0-9]{6}$')
        """
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM slack_triage_thread_subscriptions
        WHERE activated_by_provider_message_ref IS NOT NULL
      ) THEN
        RAISE EXCEPTION
          'cannot remove direct Slack Triage provenance while direct admissions exist';
      END IF;
    END
    $$
    """)

    drop(
      constraint(
        :slack_triage_thread_subscriptions,
        :slack_triage_thread_subscriptions_shape
      )
    )

    alter table(:slack_triage_thread_subscriptions) do
      remove(:activated_by_provider_message_ref)
      modify(:activated_by_message_id, :text, null: false)
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
