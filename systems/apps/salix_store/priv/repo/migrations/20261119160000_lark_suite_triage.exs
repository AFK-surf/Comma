defmodule SalixStore.Repo.Migrations.LarkSuiteTriage do
  use Ecto.Migration

  # Feishu and Lark group triage (SalixStore.LarkSuiteTriage). Expand-only:
  # three new tables that old runtimes ignore. Slack triage keeps its own
  # tables; nothing here is shared with it.
  #
  # A source is one Feishu or Lark connect of a Group with its monitoring
  # switch. A chat is one group chat a source watches. At most one source of a
  # tenant watches one chat at a time: the partial unique index on enabled
  # chats keeps two Agent Swarms from both answering in a shared group.
  #
  # A batch collects the ambient messages of one chat thread during the
  # debounce window. At most one batch per chat thread collects at a time; the
  # worker claims due batches with FOR UPDATE SKIP LOCKED.
  def up do
    create table(:lark_suite_triage_sources, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:provider, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:group_id, :text, null: false)
      add(:router_agent_id, :text, null: false)
      add(:enabled, :boolean, null: false, default: false)
      add(:updated_by, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:lark_suite_triage_sources, :lark_suite_triage_sources_provider_valid,
        check: "provider IN ('feishu', 'lark')"
      )
    )

    create(index(:lark_suite_triage_sources, [:tenant_id, :group_id]))

    create table(:lark_suite_triage_chats, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:provider, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:chat_id, :text, primary_key: true)
      add(:group_id, :text, null: false)
      add(:chat_name, :text, null: false, default: "")
      add(:enabled, :boolean, null: false, default: true)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:lark_suite_triage_chats, :lark_suite_triage_chats_provider_valid,
        check: "provider IN ('feishu', 'lark')"
      )
    )

    execute(
      "CREATE UNIQUE INDEX lark_suite_triage_chats_active_owner_idx ON lark_suite_triage_chats (tenant_id, provider, chat_id) WHERE enabled = true"
    )

    create table(:lark_suite_triage_batches, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, :text, null: false)
      add(:provider, :text, null: false)
      add(:group_id, :text, null: false)
      add(:connect_id, :text, null: false)
      add(:router_agent_id, :text, null: false)
      add(:chat_id, :text, null: false)
      add(:chat_name, :text, null: false, default: "")
      add(:thread_key, :text, null: false)
      add(:state, :text, null: false)
      add(:due_at, :utc_datetime_usec, null: false)
      add(:lease_holder, :text)
      add(:lease_until, :utc_datetime_usec)
      add(:target_message_id, :text, null: false)
      add(:latest_message_at_ms, :bigint, null: false)
      add(:message_ids, {:array, :text}, null: false, default: [])
      add(:messages_json, :jsonb, null: false, default: fragment("'[]'::jsonb"))
      add(:decision_kind, :text)
      add(:reason_code, :text)
      add(:reply_text, :text)
      add(:reaction_emoji, :text)
      add(:task_title, :text)
      add(:task_conversation_id, :text)
      add(:error_code, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
      add(:settled_at, :utc_datetime_usec)
    end

    create(
      constraint(:lark_suite_triage_batches, :lark_suite_triage_batches_provider_valid,
        check: "provider IN ('feishu', 'lark')"
      )
    )

    create(
      constraint(:lark_suite_triage_batches, :lark_suite_triage_batches_state_valid,
        check: "state IN ('collecting', 'claimed', 'applied', 'stale', 'failed')"
      )
    )

    execute(
      "CREATE UNIQUE INDEX lark_suite_triage_batches_collecting_idx ON lark_suite_triage_batches (tenant_id, provider, connect_id, chat_id, thread_key) WHERE state = 'collecting'"
    )

    execute(
      "CREATE INDEX lark_suite_triage_batches_due_idx ON lark_suite_triage_batches (state, due_at)"
    )

    execute(
      "CREATE INDEX lark_suite_triage_batches_agent_idx ON lark_suite_triage_batches (tenant_id, router_agent_id, inserted_at DESC)"
    )

    execute(
      "CREATE INDEX lark_suite_triage_batches_chat_idx ON lark_suite_triage_batches (tenant_id, provider, connect_id, chat_id, inserted_at DESC)"
    )
  end

  def down do
    drop(table(:lark_suite_triage_batches))
    drop(table(:lark_suite_triage_chats))
    drop(table(:lark_suite_triage_sources))
  end
end
