defmodule SalixStore.Repo.Migrations.IndexTriageContextSearch do
  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION triage_context_search_terms(body text) RETURNS text[]
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      WITH words AS (
        SELECT part[1] AS word
        FROM regexp_matches(lower(coalesce(body, '')), '[[:alnum:]_]+', 'g') AS part
      ), terms AS (
        SELECT word AS term FROM words
        WHERE word ~ '^[a-z0-9_]+$' AND char_length(word) BETWEEN 2 AND 64
        UNION ALL
        SELECT substr(word, position, 2) FROM words
        CROSS JOIN LATERAL generate_series(1, char_length(word) - 1) AS position
        WHERE word !~ '^[a-z0-9_]+$'
      )
      SELECT coalesce(array_agg(DISTINCT term ORDER BY term), ARRAY[]::text[]) FROM terms
    $$;
    """)

    execute("""
    ALTER TABLE triage_context_entries
      ADD COLUMN search_terms text[] GENERATED ALWAYS AS (
        triage_context_search_terms(coalesce(payload->>'subject', '') || ' ' || coalesce(payload->>'value', ''))
      ) STORED;
    """)

    execute("""
    CREATE INDEX triage_context_entries_search_idx ON triage_context_entries
      USING gin (search_terms) WHERE state = 'active';
    """)
  end

  def down do
    execute("ALTER TABLE triage_context_entries DROP COLUMN search_terms")
    execute("DROP FUNCTION triage_context_search_terms(text)")
  end
end
