defmodule SalixStore.Repo.Migrations.IndexTriageChannelTimeline do
  use Ecto.Migration

  # The dashboard timeline can filter one Slack channel. Both reads stay index
  # ordered, so a quiet channel does not scan the Agent's whole history.
  def up do
    execute("""
    CREATE INDEX triage_product_obligations_channel_timeline_idx
    ON triage_product_obligations (
      (payload #>> '{product_identity,project_id}'),
      (payload #>> '{product_identity,project_salix_group_id}'),
      (payload #>> '{product_identity,agent_id}'),
      (payload #>> '{target,channel_id}'),
      inserted_at DESC, obligation_id DESC
    )
    """)

    execute("""
    CREATE INDEX triage_intake_events_channel_recent_idx
    ON triage_intake_events (
      group_id,
      (receipt #>> '{triage_event,bucket,channel_id}'),
      received_at_ms DESC, receipt_ref DESC
    )
    """)
  end

  def down do
    execute("DROP INDEX triage_intake_events_channel_recent_idx")
    execute("DROP INDEX triage_product_obligations_channel_timeline_idx")
  end
end
