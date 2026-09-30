defmodule SalixStore.Repo.Migrations.CreateTriageProductRuntime do
  use Ecto.Migration

  def up do
    up_sql()
    |> statements(~r/;\n(?=\s*CREATE\b)/)
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
    CREATE TABLE triage_product_obligations (
      namespace_key text COLLATE "C" NOT NULL,
      run_id text COLLATE "C" NOT NULL,
      obligation_id text COLLATE "C" NOT NULL,
      payload jsonb NOT NULL,
      state text COLLATE "C" NOT NULL DEFAULT 'pending',
      attempts integer NOT NULL DEFAULT 0,
      claim_token text COLLATE "C",
      lease_until timestamptz,
      result jsonb,
      last_error text,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (namespace_key, run_id),
      UNIQUE (namespace_key, obligation_id),
      CONSTRAINT triage_product_obligations_run_fkey
        FOREIGN KEY (namespace_key, run_id)
        REFERENCES triage_runs(namespace_key, run_id),
      CONSTRAINT triage_product_obligations_shape CHECK (
        namespace_key ~ '^[0-9a-f]{64}$' AND
        btrim(run_id) <> '' AND
        obligation_id ~ '^triage-product-[0-9a-f]{64}$' AND
        jsonb_typeof(payload) = 'object' AND
        payload ?& ARRAY[
          'schema', 'obligation_id', 'namespace', 'fence_key', 'run_id',
          'target', 'product_identity', 'communication', 'context_candidates',
          'delegations', 'target_cutoff', 'settled_at'
        ] AND
        payload ->> 'schema' = 'comma.triage-product-obligation.v1' AND
        payload ->> 'obligation_id' = obligation_id AND
        payload ->> 'run_id' = run_id AND
        btrim(payload ->> 'namespace') <> '' AND
        btrim(payload ->> 'fence_key') <> '' AND
        jsonb_typeof(payload -> 'target') = 'object' AND
        jsonb_typeof(payload -> 'product_identity') = 'object' AND
        jsonb_typeof(payload -> 'communication') = 'object' AND
        jsonb_typeof(payload -> 'context_candidates') = 'array' AND
        jsonb_typeof(payload -> 'delegations') = 'array' AND
        jsonb_typeof(payload -> 'target_cutoff') = 'object' AND
        jsonb_typeof(payload -> 'settled_at') = 'number' AND
        state IN ('pending', 'claimed', 'applied', 'stale', 'failed') AND
        attempts >= 0 AND
        ((claim_token IS NULL AND lease_until IS NULL) OR
         (state = 'claimed' AND btrim(claim_token) <> '' AND lease_until IS NOT NULL)) AND
        (result IS NULL OR jsonb_typeof(result) = 'object')
      )
    );

    CREATE INDEX triage_product_obligations_claim_idx
      ON triage_product_obligations (state, lease_until, updated_at, namespace_key, run_id)
      WHERE state IN ('pending', 'claimed');

    CREATE TABLE triage_product_effect_attempts (
      attempt_id text COLLATE "C" PRIMARY KEY,
      namespace_key text COLLATE "C" NOT NULL,
      run_id text COLLATE "C" NOT NULL,
      adapter text COLLATE "C" NOT NULL,
      outcome text COLLATE "C" NOT NULL,
      external_writes integer NOT NULL,
      payload jsonb NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT triage_product_effect_attempts_run_fkey
        FOREIGN KEY (namespace_key, run_id)
        REFERENCES triage_product_obligations(namespace_key, run_id),
      CONSTRAINT triage_product_effect_attempts_shape CHECK (
        btrim(attempt_id) <> '' AND
        namespace_key ~ '^[0-9a-f]{64}$' AND
        btrim(run_id) <> '' AND
        adapter IN ('slack', 'audit_sink') AND
        outcome IN ('applied', 'stale', 'failed') AND
        external_writes >= 0 AND
        jsonb_typeof(payload) = 'object'
      )
    );

    CREATE INDEX triage_product_effect_attempts_run_idx
      ON triage_product_effect_attempts (namespace_key, run_id, inserted_at, attempt_id);

    CREATE TRIGGER triage_product_effect_attempts_append_only
      BEFORE UPDATE OR DELETE ON triage_product_effect_attempts
      FOR EACH ROW EXECUTE FUNCTION reject_triage_evidence_mutation();

    CREATE TABLE triage_context_entries (
      entry_id text COLLATE "C" PRIMARY KEY,
      project_id text COLLATE "C" NOT NULL,
      agent_id text COLLATE "C" NOT NULL,
      kind text COLLATE "C" NOT NULL,
      subject_key text COLLATE "C" NOT NULL,
      value_key text COLLATE "C" NOT NULL,
      evidence_key text COLLATE "C" NOT NULL,
      state text COLLATE "C" NOT NULL,
      payload jsonb NOT NULL,
      next_check_at timestamptz,
      resolved_at timestamptz,
      superseded_by text COLLATE "C",
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (project_id, kind, subject_key, value_key, evidence_key),
      CONSTRAINT triage_context_entries_superseded_fkey
        FOREIGN KEY (superseded_by) REFERENCES triage_context_entries(entry_id),
      CONSTRAINT triage_context_entries_shape CHECK (
        btrim(entry_id) <> '' AND btrim(project_id) <> '' AND btrim(agent_id) <> '' AND
        kind IN ('project_fact', 'decision', 'follow_up') AND
        subject_key ~ '^[0-9a-f]{64}$' AND value_key ~ '^[0-9a-f]{64}$' AND
        evidence_key ~ '^[0-9a-f]{64}$' AND
        state IN ('active', 'proposed', 'resolved', 'superseded') AND
        jsonb_typeof(payload) = 'object' AND
        ((kind = 'follow_up' AND next_check_at IS NOT NULL) OR
         (kind <> 'follow_up' AND next_check_at IS NULL)) AND
        ((state = 'resolved' AND resolved_at IS NOT NULL) OR
         (state <> 'resolved' AND resolved_at IS NULL)) AND
        ((state = 'superseded' AND superseded_by IS NOT NULL) OR
         (state <> 'superseded' AND superseded_by IS NULL))
      )
    );

    CREATE UNIQUE INDEX triage_context_entries_active_subject_idx
      ON triage_context_entries (project_id, kind, subject_key)
      WHERE state = 'active';

    CREATE INDEX triage_context_entries_follow_up_idx
      ON triage_context_entries (next_check_at, entry_id)
      WHERE kind = 'follow_up' AND state = 'active';

    CREATE INDEX triage_context_entries_recent_idx
      ON triage_context_entries (project_id, updated_at DESC, entry_id DESC);

    CREATE TABLE triage_patrol_cursors (
      cursor_key text COLLATE "C" PRIMARY KEY,
      tenant_id text COLLATE "C" NOT NULL,
      group_id text COLLATE "C" NOT NULL,
      connect_id text COLLATE "C" NOT NULL,
      channel_id text COLLATE "C" NOT NULL,
      channel_name text NOT NULL,
      channel_generation text COLLATE "C" NOT NULL,
      authority_generation text COLLATE "C" NOT NULL,
      last_message_ts text COLLATE "C" NOT NULL,
      scan_state jsonb,
      revision bigint NOT NULL DEFAULT 1,
      claim_token text COLLATE "C",
      lease_until timestamptz,
      next_due_at timestamptz NOT NULL DEFAULT now(),
      last_outcome text COLLATE "C" NOT NULL DEFAULT 'initialized',
      last_error text,
      last_result jsonb,
      last_started_at timestamptz,
      last_completed_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (tenant_id, group_id, connect_id, channel_id),
      CONSTRAINT triage_patrol_cursors_shape CHECK (
        btrim(cursor_key) <> '' AND btrim(tenant_id) <> '' AND btrim(group_id) <> '' AND
        btrim(connect_id) <> '' AND btrim(channel_id) <> '' AND
        btrim(channel_name) <> '' AND btrim(channel_generation) <> '' AND
        btrim(authority_generation) <> '' AND revision > 0 AND
        last_message_ts ~ '^[0-9]{1,12}\.[0-9]{6}$' AND
        (scan_state IS NULL OR jsonb_typeof(scan_state) = 'object') AND
        ((claim_token IS NULL AND lease_until IS NULL) OR
         (last_outcome = 'running' AND btrim(claim_token) <> '' AND lease_until IS NOT NULL)) AND
        (last_result IS NULL OR jsonb_typeof(last_result) = 'object') AND
        last_outcome IN (
          'initialized', 'running', 'idle', 'admitted', 'partial', 'failed', 'inactive', 'reset'
        )
      )
    );

    CREATE INDEX triage_patrol_cursors_due_idx
      ON triage_patrol_cursors (next_due_at, cursor_key);
    """
  end

  defp down_sql do
    """
    DROP TABLE triage_patrol_cursors;
    DROP TABLE triage_context_entries;
    DROP TABLE triage_product_effect_attempts;
    DROP TABLE triage_product_obligations;
    """
  end
end
