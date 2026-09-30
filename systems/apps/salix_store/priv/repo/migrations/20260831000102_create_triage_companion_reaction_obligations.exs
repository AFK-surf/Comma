defmodule SalixStore.Repo.Migrations.CreateTriageCompanionReactionObligations do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE triage_companion_reaction_obligations (
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
      CONSTRAINT triage_companion_reaction_obligations_run_fkey
        FOREIGN KEY (namespace_key, run_id)
        REFERENCES triage_runs(namespace_key, run_id),
      CONSTRAINT triage_companion_reaction_obligations_shape CHECK (
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
        payload -> 'communication' ->> 'kind' = 'reaction' AND
        jsonb_array_length(payload -> 'context_candidates') = 0 AND
        jsonb_array_length(payload -> 'delegations') = 0 AND
        state IN ('pending', 'claimed', 'applied', 'stale', 'failed') AND
        attempts >= 0 AND
        ((claim_token IS NULL AND lease_until IS NULL) OR
         (state = 'claimed' AND btrim(claim_token) <> '' AND lease_until IS NOT NULL)) AND
        (result IS NULL OR jsonb_typeof(result) = 'object')
      )
    )
    """)

    execute("""
    CREATE INDEX triage_companion_reaction_obligations_claim_idx
      ON triage_companion_reaction_obligations
        (state, lease_until, updated_at, namespace_key, run_id)
      WHERE state IN ('pending', 'claimed')
    """)
  end

  def down do
    execute("DROP TABLE triage_companion_reaction_obligations")
  end
end
