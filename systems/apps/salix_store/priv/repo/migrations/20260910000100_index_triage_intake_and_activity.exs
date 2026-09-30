defmodule SalixStore.Repo.Migrations.IndexTriageIntakeAndActivity do
  use Ecto.Migration

  def up do
    create table(:triage_intake_events, primary_key: false) do
      add(:receipt_ref, :text, primary_key: true)
      add(:group_id, :text, null: false)
      add(:connect_id, :text, null: false)
      add(:received_at_ms, :bigint, null: false)
      add(:receipt, :map, null: false)
    end

    execute("""
    CREATE INDEX triage_intake_events_recent_idx
    ON triage_intake_events (group_id, received_at_ms DESC, receipt_ref DESC)
    """)

    execute("""
    CREATE INDEX triage_product_obligations_timeline_idx
    ON triage_product_obligations (
      (payload #>> '{product_identity,project_id}'),
      (payload #>> '{product_identity,project_salix_group_id}'),
      (payload #>> '{product_identity,agent_id}'),
      inserted_at DESC, obligation_id DESC
    )
    """)

    execute("""
    CREATE INDEX triage_product_obligations_kind_timeline_idx
    ON triage_product_obligations (
      (payload #>> '{product_identity,project_id}'),
      (payload #>> '{product_identity,project_salix_group_id}'),
      (payload #>> '{product_identity,agent_id}'),
      (payload #>> '{communication,kind}'),
      inserted_at DESC, obligation_id DESC
    )
    """)

    execute("""
    CREATE INDEX triage_product_obligations_investigation_timeline_idx
    ON triage_product_obligations (
      (payload #>> '{product_identity,project_id}'),
      (payload #>> '{product_identity,project_salix_group_id}'),
      (payload #>> '{product_identity,agent_id}'),
      inserted_at DESC, obligation_id DESC
    ) WHERE jsonb_array_length(payload->'delegations') > 0
    """)

    execute("""
    CREATE INDEX triage_context_entries_agent_kind_recent_idx
    ON triage_context_entries (project_id, agent_id, kind, updated_at DESC, entry_id DESC)
    """)
  end

  def down do
    execute("DROP INDEX triage_context_entries_agent_kind_recent_idx")
    execute("DROP INDEX triage_product_obligations_investigation_timeline_idx")
    execute("DROP INDEX triage_product_obligations_kind_timeline_idx")
    execute("DROP INDEX triage_product_obligations_timeline_idx")
    drop(table(:triage_intake_events))
  end
end
