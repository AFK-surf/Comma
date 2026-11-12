defmodule SalixStore.Repo.Migrations.CreateSalixOnlineState do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE salix_agents (
      agent_id text PRIMARY KEY,
      tenant_id text NOT NULL, group_id text NOT NULL, role text NOT NULL,
      archived_at timestamptz, router_session_id text,
      config_revision bigint NOT NULL, config_payload bytea NOT NULL,
      owner_node text, owner_epoch bigint NOT NULL, lease_until timestamptz,
      root_revision bigint NOT NULL, root_payload bytea
    )
    """)

    execute("CREATE INDEX salix_agents_group ON salix_agents (group_id, agent_id)")
    execute("CREATE INDEX salix_agents_owner ON salix_agents (owner_node, agent_id)")

    execute("""
    CREATE INDEX salix_agents_lease ON salix_agents (lease_until, agent_id)
      WHERE owner_node IS NOT NULL
    """)

    execute("""
    CREATE TABLE salix_sessions (
      agent_id text NOT NULL REFERENCES salix_agents (agent_id),
      session_id text NOT NULL, birth_kind text NOT NULL,
      name text, hidden boolean,
      created_at timestamptz, last_activity_at timestamptz,
      revision bigint NOT NULL, storage_revision text,
      runtime_epoch bigint, control_payload bytea,
      context_revision bigint,
      last_seq bigint, compacted_seq bigint,
      queue_ack_id bigint, next_queue_id bigint,
      next_message_id bigint, archived_through bigint,
      next_run_at timestamptz, work_reasons text[],
      dispatch_after timestamptz, archive_target_seq bigint,
      deleted_at timestamptz,
      PRIMARY KEY (agent_id, session_id)
    )
    """)

    execute("""
    CREATE INDEX salix_sessions_due ON salix_sessions (next_run_at, agent_id, session_id)
      WHERE next_run_at IS NOT NULL AND deleted_at IS NULL
    """)

    execute("""
    CREATE INDEX salix_sessions_archive_due
      ON salix_sessions (agent_id, session_id)
      WHERE archive_target_seq IS NOT NULL AND deleted_at IS NULL
    """)

    execute("""
    CREATE TABLE salix_session_inputs (
      agent_id text NOT NULL, session_id text NOT NULL, queue_id bigint NOT NULL,
      kind text NOT NULL, dedupe_key bytea, payload bytea NOT NULL,
      accepted_revision bigint NOT NULL,
      PRIMARY KEY (agent_id, session_id, queue_id),
      FOREIGN KEY (agent_id, session_id) REFERENCES salix_sessions
    )
    """)

    execute("""
    CREATE TABLE salix_session_input_dedupe (
      agent_id text NOT NULL, session_id text NOT NULL, dedupe_key bytea NOT NULL,
      queue_id bigint, accepted_revision bigint,
      PRIMARY KEY (agent_id, session_id, dedupe_key),
      FOREIGN KEY (agent_id, session_id) REFERENCES salix_sessions
    )
    """)

    execute("""
    CREATE TABLE salix_session_sources (
      agent_id text NOT NULL, session_id text NOT NULL, participant_id text NOT NULL,
      conversation_id text NOT NULL, generation text NOT NULL,
      start_seq bigint NOT NULL, seq bigint NOT NULL, last_rejection bytea,
      PRIMARY KEY (agent_id, session_id, participant_id),
      FOREIGN KEY (agent_id, session_id) REFERENCES salix_sessions
    )
    """)

    execute("""
    CREATE TABLE salix_session_records (
      agent_id text NOT NULL, session_id text NOT NULL, seq bigint NOT NULL,
      kind text NOT NULL, record_id bytea, payload bytea NOT NULL,
      PRIMARY KEY (agent_id, session_id, seq),
      FOREIGN KEY (agent_id, session_id) REFERENCES salix_sessions
    )
    """)

    execute("""
    CREATE UNIQUE INDEX salix_session_records_result_identity
      ON salix_session_records (agent_id, session_id, kind, record_id)
      WHERE kind IN ('tool_result', 'async_result') AND record_id IS NOT NULL
    """)

    execute("""
    CREATE TABLE salix_session_contexts (
      agent_id text NOT NULL, session_id text NOT NULL, context_revision bigint NOT NULL,
      payload bytea NOT NULL,
      PRIMARY KEY (agent_id, session_id, context_revision),
      FOREIGN KEY (agent_id, session_id) REFERENCES salix_sessions
    )
    """)

    execute("""
    ALTER TABLE salix_sessions ADD CONSTRAINT salix_sessions_context
      FOREIGN KEY (agent_id, session_id, context_revision)
      REFERENCES salix_session_contexts (agent_id, session_id, context_revision)
      DEFERRABLE INITIALLY DEFERRED
    """)

    execute("""
    CREATE TABLE salix_session_archives (
      agent_id text NOT NULL, session_id text NOT NULL, first_seq bigint NOT NULL,
      last_seq bigint NOT NULL, object_key text NOT NULL, encoding text NOT NULL,
      record_count bigint NOT NULL, message_count bigint NOT NULL,
      uncompressed_bytes bigint NOT NULL, source_session bytea,
      byte_offset bigint, byte_length bigint,
      PRIMARY KEY (agent_id, session_id, first_seq),
      FOREIGN KEY (agent_id, session_id) REFERENCES salix_sessions
    )
    """)

    execute("""
    CREATE TABLE salix_conversation_create_requests (
      group_id text NOT NULL, request_identity text NOT NULL,
      conversation_id text NOT NULL, request_fingerprint text NOT NULL,
      created_at bigint, task_placement bytea,
      PRIMARY KEY (group_id, request_identity)
    )
    """)

    execute("""
    CREATE TABLE salix_conversations (
      group_id text NOT NULL, conversation_id text NOT NULL,
      revision bigint NOT NULL, metadata bytea, kind text, status text,
      list_timestamp bigint,
      updated_at timestamptz,
      message_tail_seq bigint, message_head_seq bigint,
      log_start_seq bigint, provider_status_version bigint,
      membership_revision bigint, deleted_at timestamptz,
      PRIMARY KEY (group_id, conversation_id)
    )
    """)

    execute("""
    CREATE INDEX salix_conversations_group
      ON salix_conversations
        (group_id, COALESCE(list_timestamp, 0) DESC, conversation_id COLLATE "C" ASC)
    """)

    execute("""
    CREATE INDEX salix_conversations_group_kind
      ON salix_conversations
        (group_id, kind, COALESCE(list_timestamp, 0) DESC, conversation_id COLLATE "C" ASC)
    """)

    execute("""
    CREATE INDEX salix_conversations_activity
      ON salix_conversations
        (group_id, COALESCE(updated_at, to_timestamp(0)) DESC,
         conversation_id COLLATE "C" DESC)
      WHERE revision > 0 AND deleted_at IS NULL AND kind = 'agent_task'
        AND status IN ('active', 'in_progress', 'running', 'working', 'needs_review',
                       'ready_for_review', 'escalated', 'review', 'waiting_for_review')
    """)

    execute("""
    CREATE TABLE salix_conversation_messages (
      group_id text NOT NULL, conversation_id text NOT NULL, seq bigint,
      message_id text NOT NULL, request_identity text, request_fingerprint text, revision bigint NOT NULL,
      payload bytea, tombstone boolean NOT NULL DEFAULT false, archive_first_seq bigint,
      PRIMARY KEY (group_id, conversation_id, message_id),
      FOREIGN KEY (group_id, conversation_id) REFERENCES salix_conversations,
      UNIQUE (group_id, conversation_id, seq)
    )
    """)

    execute("""
    CREATE UNIQUE INDEX salix_conversation_messages_request
      ON salix_conversation_messages (group_id, conversation_id, request_identity)
      WHERE request_identity IS NOT NULL
    """)

    execute("""
    CREATE TABLE salix_conversation_participants (
      group_id text NOT NULL, conversation_id text NOT NULL, participant_id text NOT NULL,
      revision bigint NOT NULL, payload bytea NOT NULL, delivery_log_cursor_seq bigint NOT NULL,
      actor_type text, agent_id text, session_id text, state text,
      source_start_seq bigint, receives_messages boolean,
      incarnation text, delivery_fence text, cutoff_seq bigint, deleted_at timestamptz,
      PRIMARY KEY (group_id, conversation_id, participant_id),
      FOREIGN KEY (group_id, conversation_id) REFERENCES salix_conversations
    )
    """)

    execute("""
    CREATE TABLE salix_conversation_deliveries (
      group_id text NOT NULL, conversation_id text NOT NULL,
      participant_id text NOT NULL, delivery_id text NOT NULL,
      revision bigint NOT NULL, status text NOT NULL, payload bytea NOT NULL,
      PRIMARY KEY (group_id, conversation_id, participant_id, delivery_id),
      FOREIGN KEY (group_id, conversation_id, participant_id)
        REFERENCES salix_conversation_participants
    )
    """)

    execute("""
    CREATE TABLE salix_conversation_archives (
      group_id text NOT NULL, conversation_id text NOT NULL, first_seq bigint NOT NULL,
      last_seq bigint NOT NULL, object_key text NOT NULL, encoding text NOT NULL,
      PRIMARY KEY (group_id, conversation_id, first_seq),
      FOREIGN KEY (group_id, conversation_id) REFERENCES salix_conversations
    )
    """)

    execute("""
    CREATE TABLE salix_capability_requests (
      group_id text NOT NULL, request_id text NOT NULL, revision bigint NOT NULL,
      tenant_id text NOT NULL, request_type text NOT NULL, status text NOT NULL,
      expires_at timestamptz NOT NULL, source_agent_id text NOT NULL,
      source_session_id text NOT NULL, tool_call_id text NOT NULL,
      surface_kind text, surface_ref jsonb NOT NULL, payload bytea NOT NULL,
      created_at bigint, updated_at bigint,
      result_delivery_due_at timestamptz, result_delivered_at timestamptz,
      PRIMARY KEY (group_id, request_id)
    )
    """)

    execute("""
    CREATE INDEX salix_capability_requests_status
      ON salix_capability_requests
        (group_id, status, COALESCE(updated_at, 0) DESC, COALESCE(created_at, 0) DESC,
         request_id COLLATE "C" DESC)
    """)

    execute("""
    CREATE INDEX salix_capability_requests_group_order
      ON salix_capability_requests
        (group_id, COALESCE(updated_at, 0) DESC, COALESCE(created_at, 0) DESC,
         request_id COLLATE "C" DESC)
    """)

    execute("""
    CREATE INDEX salix_capability_requests_tool
      ON salix_capability_requests
        (group_id, source_agent_id, source_session_id, tool_call_id, request_type)
    """)

    execute("""
    CREATE INDEX salix_capability_requests_surface
      ON salix_capability_requests
        (group_id, surface_kind, (surface_ref->>'conversation_id'),
         COALESCE(updated_at, 0) DESC, COALESCE(created_at, 0) DESC,
         request_id COLLATE "C" DESC)
    """)

    execute("""
    CREATE INDEX salix_capability_requests_surface_pending
      ON salix_capability_requests
        (group_id, surface_kind, (surface_ref->>'conversation_id'),
         COALESCE(updated_at, 0) DESC, COALESCE(created_at, 0) DESC,
         request_id COLLATE "C" DESC)
      WHERE status = 'pending'
    """)

    execute("""
    CREATE INDEX salix_capability_requests_expiry
      ON salix_capability_requests (expires_at, group_id, request_id)
      WHERE status = 'pending' AND request_type = 'location'
    """)

    execute("""
    CREATE INDEX salix_capability_requests_delivery_due
      ON salix_capability_requests (result_delivery_due_at, group_id, request_id)
      WHERE result_delivery_due_at IS NOT NULL AND result_delivered_at IS NULL
    """)

    alter table(:conversation_log_recovery) do
      add(:membership_revision, :bigint, null: false, default: 0)
    end

    alter table(:agent_session_history_states) do
      add(:target_seq, :bigint, null: false, default: 0)
    end

    execute("""
    UPDATE agent_session_history_states SET target_seq = indexed_through
    """)

    execute("""
    CREATE INDEX agent_session_history_pending
      ON agent_session_history_states (agent_id, session_id)
      WHERE target_seq > indexed_through OR cold_through < GREATEST(indexed_through - 256, 0)
    """)

    execute("""
    ALTER TABLE conversation_search_backfill_runs
      DROP CONSTRAINT conversation_search_backfill_runs_shape,
      DROP COLUMN required_discovery_cycle,
      ADD COLUMN scan_upper_group_id text,
      ADD COLUMN scan_upper_conversation_id text,
      ADD COLUMN scan_group_id text,
      ADD COLUMN scan_conversation_id text,
      ADD COLUMN scan_completed_at timestamptz,
      ADD CONSTRAINT conversation_search_backfill_runs_shape CHECK (
        btrim(writer_generation) <> '' AND
        ((writer_barrier_authority IS NULL AND writer_barrier_at IS NULL) OR
         (btrim(writer_barrier_authority) <> '' AND writer_barrier_at IS NOT NULL))
      )
    """)

    drop(table(:conversation_search_discovery_cursors))
  end

  def down do
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

    execute("""
    ALTER TABLE conversation_search_backfill_runs
      DROP CONSTRAINT conversation_search_backfill_runs_shape,
      DROP COLUMN scan_upper_group_id,
      DROP COLUMN scan_upper_conversation_id,
      DROP COLUMN scan_group_id,
      DROP COLUMN scan_conversation_id,
      DROP COLUMN scan_completed_at,
      ADD COLUMN required_discovery_cycle bigint,
      ADD CONSTRAINT conversation_search_backfill_runs_shape CHECK (
        btrim(writer_generation) <> '' AND
        ((writer_barrier_authority IS NULL AND writer_barrier_at IS NULL) OR
         (btrim(writer_barrier_authority) <> '' AND writer_barrier_at IS NOT NULL)) AND
        (required_discovery_cycle IS NULL OR required_discovery_cycle > 0)
      )
    """)

    drop(
      index(:agent_session_history_states, [:agent_id, :session_id],
        name: :agent_session_history_pending
      )
    )

    alter table(:agent_session_history_states) do
      remove(:target_seq)
    end

    alter table(:conversation_log_recovery) do
      remove(:membership_revision)
    end

    for table_name <- [
          :salix_capability_requests,
          :salix_conversation_create_requests,
          :salix_conversation_archives,
          :salix_conversation_deliveries,
          :salix_conversation_participants,
          :salix_conversation_messages,
          :salix_conversations,
          :salix_session_archives
        ] do
      drop(table(table_name))
    end

    execute("ALTER TABLE salix_sessions DROP CONSTRAINT salix_sessions_context")

    for table_name <- [
          :salix_session_contexts,
          :salix_session_records,
          :salix_session_sources,
          :salix_session_input_dedupe,
          :salix_session_inputs,
          :salix_sessions,
          :salix_agents
        ] do
      drop(table(table_name))
    end
  end
end
