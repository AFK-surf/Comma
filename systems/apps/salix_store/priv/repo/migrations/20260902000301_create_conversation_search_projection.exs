defmodule SalixStore.Repo.Migrations.CreateConversationSearchProjection do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS btree_gin")

    create table(:conversation_search_states, primary_key: false) do
      add(:writer_generation, :text, null: false, primary_key: true)
      add(:agent_group_id, :text, null: false, primary_key: true)
      add(:conversation_id, :text, null: false, primary_key: true)
      add(:conversation_kind, :text, null: false)
      add(:title, :text, null: false, default: "")
      add(:source_version, :bigint, null: false)
      add(:message_head_seq, :bigint, null: false, default: 0)
      add(:message_tail_seq, :bigint, null: false, default: 0)
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      constraint(:conversation_search_states, :conversation_search_states_shape,
        check:
          "btrim(writer_generation) <> '' AND btrim(agent_group_id) <> '' AND " <>
            "btrim(conversation_id) <> '' AND " <>
            "conversation_kind = 'agent_task' AND source_version >= 0 AND " <>
            "message_head_seq >= 0 AND message_tail_seq >= message_head_seq AND " <>
            "octet_length(title) <= 16384"
      )
    )

    create(
      index(
        :conversation_search_states,
        [:writer_generation, :agent_group_id, :conversation_kind],
        name: :conversation_search_states_scope_idx
      )
    )

    create table(:conversation_search_documents, primary_key: false) do
      add(:writer_generation, :text, null: false, primary_key: true)
      add(:agent_group_id, :text, null: false, primary_key: true)
      add(:conversation_id, :text, null: false, primary_key: true)
      add(:document_type, :text, null: false, primary_key: true)
      add(:document_id, :text, null: false, primary_key: true)
      add(:source_id, :text, null: false)
      add(:source_seq, :bigint)
      add(:source_created_at, :bigint)
      add(:content, :text, null: false)
      add(:folded_content, :text, null: false)

      add(:weight_bytes, :integer,
        null: false,
        generated:
          "ALWAYS AS (greatest(octet_length(content), octet_length(folded_content))) STORED"
      )

      add(:short_grams, {:array, :text}, null: false, default: [])
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      constraint(:conversation_search_documents, :conversation_search_documents_shape,
        check:
          "btrim(writer_generation) <> '' AND btrim(agent_group_id) <> '' AND " <>
            "btrim(conversation_id) <> '' AND " <>
            "document_type IN ('title', 'message') AND btrim(document_id) <> '' AND " <>
            "btrim(source_id) <> '' AND cardinality(short_grams) <= 32768 AND " <>
            "weight_bytes = greatest(octet_length(content), octet_length(folded_content)) AND " <>
            "((document_type = 'title' AND source_seq IS NULL AND " <>
            "octet_length(content) <= 16384 AND octet_length(folded_content) <= 16384) OR " <>
            "(document_type = 'message' AND source_seq IS NOT NULL AND source_seq > 0 AND " <>
            "octet_length(content) <= 32768 AND octet_length(folded_content) <= 32768))"
      )
    )

    execute("""
    ALTER TABLE conversation_search_documents
      ADD CONSTRAINT conversation_search_documents_state_fkey
      FOREIGN KEY (writer_generation, agent_group_id, conversation_id)
      REFERENCES conversation_search_states(writer_generation, agent_group_id, conversation_id)
      ON DELETE CASCADE
    """)

    execute("""
    CREATE INDEX conversation_search_documents_group_short_grams_idx
      ON conversation_search_documents USING gin
        (writer_generation, agent_group_id, short_grams)
    """)

    create(
      index(
        :conversation_search_documents,
        [
          :writer_generation,
          :agent_group_id,
          :conversation_id,
          :document_type,
          :source_created_at
        ],
        name: :conversation_search_documents_scope_idx
      )
    )

    create table(:conversation_search_jobs, primary_key: false) do
      add(:id, :bigserial, primary_key: true)
      add(:writer_generation, :text, null: false)
      add(:agent_group_id, :text, null: false)
      add(:conversation_id, :text, null: false)
      add(:operation, :text, null: false)
      add(:source_id, :text, null: false, default: "")
      add(:source_seq, :bigint)
      add(:generation, :bigint, null: false, default: 1)
      add(:cursor_seq, :bigint, null: false, default: 0)
      add(:attempt_count, :integer, null: false, default: 0)
      add(:available_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:claim_token, :text)
      add(:claim_until, :utc_datetime_usec)
      add(:last_error, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:conversation_search_jobs, :conversation_search_jobs_shape,
        check:
          "btrim(writer_generation) <> '' AND btrim(agent_group_id) <> '' AND " <>
            "btrim(conversation_id) <> '' AND " <>
            "operation IN ('rebuild', 'message', 'delete') AND generation > 0 AND " <>
            "cursor_seq >= 0 AND attempt_count >= 0 AND " <>
            "((claim_token IS NULL AND claim_until IS NULL) OR " <>
            "(btrim(claim_token) <> '' AND claim_until IS NOT NULL)) AND " <>
            "((operation = 'message' AND btrim(source_id) <> '' AND source_seq > 0) OR " <>
            "(operation IN ('rebuild', 'delete') AND source_id = '' AND source_seq IS NULL))"
      )
    )

    create(
      unique_index(
        :conversation_search_jobs,
        [:writer_generation, :agent_group_id, :conversation_id],
        name: :conversation_search_jobs_identity_idx
      )
    )

    create(
      index(:conversation_search_jobs, [:writer_generation, :available_at, :id],
        where: "claim_token IS NULL",
        name: :conversation_search_jobs_available_idx
      )
    )

    create(
      index(:conversation_search_jobs, [:writer_generation, :claim_until, :id],
        where: "claim_token IS NOT NULL",
        name: :conversation_search_jobs_expired_claim_idx
      )
    )

    create table(:conversation_search_discovery_cursors, primary_key: false) do
      add(:id, :text, null: false, primary_key: true)
      add(:writer_generation, :text, null: false)
      add(:group_start_after, :text)
      add(:current_group_id, :text)
      add(:conversation_start_after, :text)
      add(:completed_cycles, :bigint, null: false, default: 0)
      add(:cycle_started_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:last_cycle_completed_at, :utc_datetime_usec)
      add(:claim_token, :text)
      add(:claim_until, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(
        :conversation_search_discovery_cursors,
        :conversation_search_discovery_cursors_shape,
        check:
          "btrim(id) <> '' AND btrim(writer_generation) <> '' AND completed_cycles >= 0 AND " <>
            "((claim_token IS NULL AND claim_until IS NULL) OR " <>
            "(btrim(claim_token) <> '' AND claim_until IS NOT NULL))"
      )
    )

    create table(:conversation_search_backfill_runs, primary_key: false) do
      add(:writer_generation, :text, null: false, primary_key: true)
      add(:writer_barrier_authority, :text)
      add(:writer_barrier_at, :utc_datetime_usec)
      add(:required_discovery_cycle, :bigint)
      add(:sealed_at, :utc_datetime_usec)
      add(:retired_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:conversation_search_backfill_runs, :conversation_search_backfill_runs_shape,
        check:
          "btrim(writer_generation) <> '' AND " <>
            "((writer_barrier_authority IS NULL AND writer_barrier_at IS NULL) OR " <>
            "(btrim(writer_barrier_authority) <> '' AND writer_barrier_at IS NOT NULL)) AND " <>
            "(required_discovery_cycle IS NULL OR required_discovery_cycle > 0)"
      )
    )

    create table(:conversation_search_gc_runs, primary_key: false) do
      add(:writer_generation, :text, null: false, primary_key: true)
      add(:phase, :text, null: false, default: "documents")
      add(:cursor, :map, null: false, default: %{})
      add(:deleted_documents, :bigint, null: false, default: 0)
      add(:deleted_states, :bigint, null: false, default: 0)
      add(:deleted_jobs, :bigint, null: false, default: 0)
      add(:finished_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:conversation_search_gc_runs, :conversation_search_gc_runs_shape,
        check:
          "btrim(writer_generation) <> '' AND " <>
            "phase IN ('documents', 'states', 'jobs', 'metadata', 'done') AND " <>
            "deleted_documents >= 0 AND deleted_states >= 0 AND deleted_jobs >= 0"
      )
    )
  end

  def down do
    drop_if_exists(table(:conversation_search_gc_runs))
    drop(table(:conversation_search_backfill_runs))
    drop(table(:conversation_search_discovery_cursors))
    drop(table(:conversation_search_jobs))
    drop(table(:conversation_search_documents))
    drop(table(:conversation_search_states))
  end
end
