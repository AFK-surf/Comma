defmodule SalixStore.Repo.Migrations.CreateTriageAndMeetingProjections do
  use Ecto.Migration

  def up do
    up_sql()
    |> statements(~r/;\n(?=\s*(?:ALTER|CREATE|REVOKE)\b)/)
    |> Enum.each(&execute/1)
  end

  def down do
    down_sql()
    |> statements(~r/;\n(?=\s*DROP\b)/)
    |> Enum.each(&execute/1)
  end

  defp statements(sql, separator) do
    separator
    |> Regex.split(sql)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp up_sql do
    """
    CREATE FUNCTION reject_triage_evidence_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      RAISE EXCEPTION 'native Triage evidence is append-only';
    END;
    $$;

    CREATE FUNCTION enforce_triage_fence_terminal_monotonicity()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF OLD.body -> 'terminal' IS DISTINCT FROM 'null'::jsonb AND
         NEW.body -> 'terminal' IS DISTINCT FROM OLD.body -> 'terminal' THEN
        RAISE EXCEPTION 'native Triage fence terminal is monotonic'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $$;

    CREATE TABLE triage_receipt_projections (
      record_key text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL,
      receipt_key text COLLATE "C" NOT NULL,
      receipt_ref text COLLATE "C" NOT NULL,
      body jsonb NOT NULL,
      revision bigint NOT NULL DEFAULT 1,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_receipt_projections_identity UNIQUE (namespace_key, receipt_key),
      CONSTRAINT triage_receipt_projections_reference
        UNIQUE (namespace_key, receipt_key, receipt_ref),
      CONSTRAINT triage_receipt_projections_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        receipt_key ~ '^[0-9a-f]{64}$' AND
        btrim(receipt_ref) <> '' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY['schema', 'receipt_ref', 'event_id'] AND
        body ->> 'schema' = 'comma.triage-receipt-projection.v1' AND
        body ->> 'receipt_ref' = receipt_ref AND
        revision = 1
      )
    );

    CREATE TABLE triage_ambient_aliases (
      record_key text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL,
      physical_source_key text COLLATE "C" NOT NULL,
      body jsonb NOT NULL,
      revision bigint NOT NULL DEFAULT 1,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_ambient_aliases_identity UNIQUE (namespace_key, physical_source_key),
      CONSTRAINT triage_ambient_aliases_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        physical_source_key ~ '^[0-9a-f]{64}$' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY['schema', 'source_message_ref', 'canonical_receipt_ref'] AND
        body ->> 'schema' = 'comma.triage-source-alias.v1' AND
        revision = 1
      )
    );

    CREATE TABLE triage_recipient_aliases (
      namespace_key text COLLATE "C" NOT NULL,
      physical_source_key text COLLATE "C" NOT NULL,
      recipient_key text COLLATE "C" NOT NULL,
      receipt_key text COLLATE "C" NOT NULL,
      canonical_receipt_ref text COLLATE "C" NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (namespace_key, physical_source_key, recipient_key),
      CONSTRAINT triage_recipient_aliases_reference
        UNIQUE (
          namespace_key, physical_source_key, recipient_key,
          canonical_receipt_ref
        ),
      CONSTRAINT triage_recipient_aliases_receipt_fkey
        FOREIGN KEY (namespace_key, receipt_key, canonical_receipt_ref)
        REFERENCES triage_receipt_projections(namespace_key, receipt_key, receipt_ref),
      CONSTRAINT triage_recipient_aliases_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        physical_source_key ~ '^[0-9a-f]{64}$' AND
        recipient_key ~ '^[0-9a-f]{64}$' AND
        receipt_key ~ '^[0-9a-f]{64}$' AND
        btrim(canonical_receipt_ref) <> ''
      )
    );

    CREATE TABLE triage_bucket_memberships (
      namespace_key text COLLATE "C" NOT NULL,
      physical_source_key text COLLATE "C" NOT NULL,
      recipient_key text COLLATE "C" NOT NULL,
      bucket_key text COLLATE "C" NOT NULL,
      canonical_receipt_ref text COLLATE "C" NOT NULL,
      lane text COLLATE "C" NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (namespace_key, physical_source_key, recipient_key),
      CONSTRAINT triage_bucket_memberships_recipient_alias_fkey
        FOREIGN KEY (
          namespace_key, physical_source_key, recipient_key,
          canonical_receipt_ref
        )
        REFERENCES triage_recipient_aliases(
          namespace_key, physical_source_key, recipient_key,
          canonical_receipt_ref
        ),
      CONSTRAINT triage_bucket_memberships_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        physical_source_key ~ '^[0-9a-f]{64}$' AND
        recipient_key ~ '^[0-9a-f]{64}$' AND
        bucket_key ~ '^[0-9a-f]{64}$' AND
        btrim(canonical_receipt_ref) <> '' AND
        lane IN ('ambient', 'directed', 'both')
      )
    );

    CREATE TABLE triage_buckets (
      record_key text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL,
      bucket_key text COLLATE "C" NOT NULL,
      body jsonb NOT NULL,
      revision bigint NOT NULL DEFAULT 1,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_buckets_identity UNIQUE (namespace_key, bucket_key),
      CONSTRAINT triage_buckets_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        bucket_key ~ '^[0-9a-f]{64}$' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY[
          'schema', 'bucket_scope', 'open_generation', 'open_first_at', 'open_last_at',
          'open_fast_path', 'open_receipts', 'sealed_generations'
        ] AND
        body ->> 'schema' = 'comma.triage-durable-bucket.v1' AND
        revision > 0
      )
    );

    ALTER TABLE triage_bucket_memberships
      ADD CONSTRAINT triage_bucket_memberships_bucket_fkey
      FOREIGN KEY (namespace_key, bucket_key)
      REFERENCES triage_buckets(namespace_key, bucket_key);

    CREATE TABLE triage_run_fences (
      record_key text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL,
      bucket_key text COLLATE "C" NOT NULL,
      generation_key text COLLATE "C" NOT NULL,
      body jsonb NOT NULL,
      revision bigint NOT NULL DEFAULT 1,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_run_fences_identity UNIQUE (namespace_key, bucket_key, generation_key),
      CONSTRAINT triage_run_fences_bucket_fkey
        FOREIGN KEY (namespace_key, bucket_key)
        REFERENCES triage_buckets(namespace_key, bucket_key),
      CONSTRAINT triage_run_fences_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        bucket_key ~ '^[0-9a-f]{64}$' AND
        generation_key ~ '^[0-9a-f]{64}$' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY['schema', 'run_id', 'terminal'] AND
        body ->> 'schema' IN ('comma.triage-bucket-fence.v1', 'comma.triage-bucket-fence.v2') AND
        revision > 0
      )
    );

    CREATE TABLE triage_runs (
      record_key text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL,
      run_id text COLLATE "C" NOT NULL,
      body jsonb NOT NULL,
      revision bigint NOT NULL DEFAULT 1,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_runs_identity UNIQUE (namespace_key, run_id),
      CONSTRAINT triage_runs_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        btrim(run_id) <> '' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY['schema', 'run_id', 'authoritative', 'created_at', 'status'] AND
        body ->> 'schema' IN ('comma.triage-run.v1', 'comma.triage-run.v2') AND
        body ->> 'run_id' = run_id AND
        revision = 1
      )
    );

    CREATE TABLE triage_replays (
      record_key text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL,
      run_id text COLLATE "C" NOT NULL,
      body jsonb NOT NULL,
      revision bigint NOT NULL DEFAULT 1,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_replays_identity UNIQUE (namespace_key, run_id),
      CONSTRAINT triage_replays_run_fkey
        FOREIGN KEY (namespace_key, run_id)
        REFERENCES triage_runs(namespace_key, run_id),
      CONSTRAINT triage_replays_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        btrim(run_id) <> '' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY['schema', 'run_id', 'ledger_ref', 'run_sha256'] AND
        body ->> 'schema' = 'comma.triage-replay.v1' AND
        body ->> 'run_id' = run_id AND
        revision = 1
      )
    );

    CREATE TABLE triage_projection_obligations (
      namespace_key text COLLATE "C" NOT NULL,
      run_id text COLLATE "C" NOT NULL,
      payload jsonb NOT NULL,
      state text COLLATE "C" NOT NULL DEFAULT 'pending',
      attempts integer NOT NULL DEFAULT 0,
      last_error text,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (namespace_key, run_id),
      CONSTRAINT triage_projection_obligations_run_fkey
        FOREIGN KEY (namespace_key, run_id)
        REFERENCES triage_runs(namespace_key, run_id),
      CONSTRAINT triage_projection_obligations_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        btrim(run_id) <> '' AND
        jsonb_typeof(payload) = 'object' AND
        payload ?& ARRAY[
          'schema', 'namespace', 'fence_key', 'run_id', 'correlations',
          'activity_required', 'time_required'
        ] AND
        payload ->> 'schema' = 'comma.triage-projection-obligation.v1' AND
        btrim(payload ->> 'namespace') <> '' AND
        btrim(payload ->> 'fence_key') <> '' AND
        payload ->> 'run_id' = run_id AND
        jsonb_typeof(payload -> 'correlations') = 'array' AND
        jsonb_typeof(payload -> 'activity_required') = 'boolean' AND
        payload -> 'time_required' = 'true'::jsonb AND
        state IN ('pending', 'applied') AND
        attempts >= 0
      )
    );

    CREATE INDEX triage_projection_obligations_pending_idx
      ON triage_projection_obligations (updated_at, namespace_key, run_id)
      WHERE state = 'pending';

    CREATE TABLE triage_correlation_entries (
      record_key text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL,
      selector_kind text COLLATE "C" NOT NULL,
      selector_key text COLLATE "C" NOT NULL,
      run_id text COLLATE "C" NOT NULL,
      body jsonb NOT NULL,
      revision bigint NOT NULL DEFAULT 1,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_correlation_entries_identity
        UNIQUE (namespace_key, selector_kind, selector_key, run_id),
      CONSTRAINT triage_correlation_entries_run_fkey
        FOREIGN KEY (namespace_key, run_id)
        REFERENCES triage_runs(namespace_key, run_id),
      CONSTRAINT triage_correlation_entries_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        selector_kind IN ('receipt_ref', 'slack_event_id', 'slack_message') AND
        selector_key ~ '^[0-9a-f]{64}$' AND
        btrim(run_id) <> '' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY[
          'schema', 'selector_kind', 'selector_sha256', 'run_id', 'run_sha256', 'created_at'
        ] AND
        body ->> 'schema' = 'comma.triage-run-correlation-index-entry.v1' AND
        revision = 1
      )
    );

    CREATE TABLE triage_time_index_entries (
      record_key text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL,
      created_at_ms bigint NOT NULL,
      run_id text COLLATE "C" NOT NULL,
      body jsonb NOT NULL,
      revision bigint NOT NULL DEFAULT 1,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_time_index_entries_identity UNIQUE (namespace_key, created_at_ms, run_id),
      CONSTRAINT triage_time_index_entries_run_fkey
        FOREIGN KEY (namespace_key, run_id)
        REFERENCES triage_runs(namespace_key, run_id),
      CONSTRAINT triage_time_index_entries_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        created_at_ms >= 0 AND
        btrim(run_id) <> '' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY['schema', 'run_id', 'run_sha256', 'created_at'] AND
        body ->> 'schema' = 'comma.triage-run-time-index-entry.v1' AND
        revision = 1
      )
    );

    CREATE TABLE triage_activity_index_entries (
      record_key text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL,
      identity_scope_key text COLLATE "C" NOT NULL,
      reverse_created_at_ms bigint NOT NULL,
      run_id text COLLATE "C" NOT NULL,
      body jsonb NOT NULL,
      revision bigint NOT NULL DEFAULT 1,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_activity_index_entries_identity
        UNIQUE (namespace_key, identity_scope_key, reverse_created_at_ms, run_id),
      CONSTRAINT triage_activity_index_entries_run_fkey
        FOREIGN KEY (namespace_key, run_id)
        REFERENCES triage_runs(namespace_key, run_id),
      CONSTRAINT triage_activity_index_entries_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        identity_scope_key ~ '^[0-9a-f]{64}$' AND
        reverse_created_at_ms >= 0 AND
        btrim(run_id) <> '' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY[
          'schema', 'identity_scope_sha256', 'identity_revision_sha256',
          'run_id', 'run_sha256', 'created_at'
        ] AND
        body ->> 'schema' = 'comma.triage-activity-index-entry.v1' AND
        revision = 1
      )
    );

    CREATE TABLE triage_lifecycle_events (
      record_key text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL,
      run_id text COLLATE "C" NOT NULL,
      event_id text COLLATE "C" NOT NULL,
      body jsonb NOT NULL,
      revision bigint NOT NULL DEFAULT 1,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_lifecycle_events_identity UNIQUE (namespace_key, run_id, event_id),
      CONSTRAINT triage_lifecycle_events_run_fkey
        FOREIGN KEY (namespace_key, run_id)
        REFERENCES triage_runs(namespace_key, run_id),
      CONSTRAINT triage_lifecycle_events_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        btrim(run_id) <> '' AND
        btrim(event_id) <> '' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY[
          'schema', 'event_id', 'run_id', 'run_sha256', 'proposal_sha256',
          'event_type', 'causal_event_id', 'receipt', 'observed_at_ms'
        ] AND
        body ->> 'schema' = 'comma.triage-lifecycle-event.v1' AND
        revision = 1
      )
    );

    CREATE TABLE triage_late_results (
      record_key text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL,
      run_id text COLLATE "C" NOT NULL,
      observation_id text COLLATE "C" NOT NULL,
      body jsonb NOT NULL,
      revision bigint NOT NULL DEFAULT 1,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_late_results_identity UNIQUE (namespace_key, run_id, observation_id),
      CONSTRAINT triage_late_results_run_fkey
        FOREIGN KEY (namespace_key, run_id)
        REFERENCES triage_runs(namespace_key, run_id),
      CONSTRAINT triage_late_results_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        btrim(run_id) <> '' AND
        btrim(observation_id) <> '' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY[
          'schema', 'observation_id', 'linked_run_id', 'authoritative', 'created_at',
          'status', 'decision', 'evaluator', 'authority_status'
        ] AND
        body ->> 'schema' = 'comma.triage-late-result.v1' AND
        revision = 1
      )
    );

    CREATE TABLE triage_intent_settlements (
      connect_id text COLLATE "C" NOT NULL,
      event_key text COLLATE "C" NOT NULL,
      body jsonb NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (connect_id, event_key),
      CONSTRAINT triage_intent_settlements_shape CHECK (
        btrim(connect_id) <> '' AND
        event_key ~ '^[0-9a-f]{64}$' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY['schema', 'connect_id', 'event_id', 'reason', 'admission_ref'] AND
        body ->> 'schema' = 'comma.slack-intent-settlement.v1'
      )
    );

    CREATE TABLE triage_recovery_leases (
      record_key text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL UNIQUE,
      body jsonb NOT NULL,
      revision bigint NOT NULL DEFAULT 1,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_recovery_leases_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        jsonb_typeof(body) = 'object' AND
        body ?& ARRAY['holder', 'epoch', 'lease_until'] AND
        jsonb_typeof(body -> 'epoch') = 'number' AND
        jsonb_typeof(body -> 'lease_until') = 'number' AND
        btrim(body ->> 'holder') <> '' AND
        revision > 0
      )
    );

    CREATE TABLE meeting_group_projections (
      meeting_id text COLLATE "C" PRIMARY KEY,
      group_id text COLLATE "C" NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT meeting_group_projections_nonempty_identity
        CHECK (btrim(meeting_id) <> '' AND btrim(group_id) <> '')
    );

    CREATE INDEX meeting_group_projections_group_cursor_idx
      ON meeting_group_projections (group_id, meeting_id);

    CREATE TRIGGER triage_receipt_projections_append_only
      BEFORE UPDATE OR DELETE ON triage_receipt_projections
      FOR EACH ROW EXECUTE FUNCTION reject_triage_evidence_mutation();
    CREATE TRIGGER triage_ambient_aliases_append_only
      BEFORE UPDATE OR DELETE ON triage_ambient_aliases
      FOR EACH ROW EXECUTE FUNCTION reject_triage_evidence_mutation();
    CREATE TRIGGER triage_recipient_aliases_append_only
      BEFORE UPDATE OR DELETE ON triage_recipient_aliases
      FOR EACH ROW EXECUTE FUNCTION reject_triage_evidence_mutation();
    CREATE TRIGGER triage_runs_append_only
      BEFORE UPDATE OR DELETE ON triage_runs
      FOR EACH ROW EXECUTE FUNCTION reject_triage_evidence_mutation();
    CREATE TRIGGER triage_replays_append_only
      BEFORE UPDATE OR DELETE ON triage_replays
      FOR EACH ROW EXECUTE FUNCTION reject_triage_evidence_mutation();
    CREATE TRIGGER triage_correlation_entries_append_only
      BEFORE UPDATE OR DELETE ON triage_correlation_entries
      FOR EACH ROW EXECUTE FUNCTION reject_triage_evidence_mutation();
    CREATE TRIGGER triage_time_index_entries_append_only
      BEFORE UPDATE OR DELETE ON triage_time_index_entries
      FOR EACH ROW EXECUTE FUNCTION reject_triage_evidence_mutation();
    CREATE TRIGGER triage_activity_index_entries_append_only
      BEFORE UPDATE OR DELETE ON triage_activity_index_entries
      FOR EACH ROW EXECUTE FUNCTION reject_triage_evidence_mutation();
    CREATE TRIGGER triage_lifecycle_events_append_only
      BEFORE UPDATE OR DELETE ON triage_lifecycle_events
      FOR EACH ROW EXECUTE FUNCTION reject_triage_evidence_mutation();
    CREATE TRIGGER triage_late_results_append_only
      BEFORE UPDATE OR DELETE ON triage_late_results
      FOR EACH ROW EXECUTE FUNCTION reject_triage_evidence_mutation();
    CREATE TRIGGER triage_intent_settlements_append_only
      BEFORE UPDATE OR DELETE ON triage_intent_settlements
      FOR EACH ROW EXECUTE FUNCTION reject_triage_evidence_mutation();
    CREATE TRIGGER triage_run_fences_terminal_monotonic
      BEFORE UPDATE ON triage_run_fences
      FOR EACH ROW EXECUTE FUNCTION enforce_triage_fence_terminal_monotonicity();
    """
  end

  defp down_sql do
    """
    DROP TABLE meeting_group_projections;
    DROP TABLE triage_recovery_leases;
    DROP TABLE triage_intent_settlements;
    DROP TABLE triage_late_results;
    DROP TABLE triage_lifecycle_events;
    DROP TABLE triage_activity_index_entries;
    DROP TABLE triage_time_index_entries;
    DROP TABLE triage_correlation_entries;
    DROP TABLE triage_projection_obligations;
    DROP TABLE triage_replays;
    DROP TABLE triage_runs;
    DROP TABLE triage_run_fences;
    DROP TABLE triage_bucket_memberships;
    DROP TABLE triage_buckets;
    DROP TABLE triage_recipient_aliases;
    DROP TABLE triage_ambient_aliases;
    DROP TABLE triage_receipt_projections;
    DROP FUNCTION IF EXISTS enforce_triage_fence_terminal_monotonicity();
    DROP FUNCTION IF EXISTS reject_triage_evidence_mutation();
    """
  end
end
