defmodule SalixStore.Repo.Migrations.StoreProfiles do
  use Ecto.Migration

  # An account is stored as the Profile Comma and its stations share
  # (systems/profiles model.rs): `credential` and `source` for
  # `credential_kind` and `provider`, the address as `endpoint`, `protocol`
  # (chat_completions, responses, anthropic) and `auth`, the status as ok or
  # login, the allowance's windows as used percent, refill and length in
  # milliseconds and minutes, the wait as milliseconds. The server's own fields
  # stay as they were.

  def up do
    execute("""
    UPDATE subscription_accounts SET value =
      (value - 'credential_kind' - 'provider' - 'connection' - 'quota' - 'cooldown_until')
      || jsonb_build_object(
        'credential', CASE WHEN value->>'credential_kind'='provider_api_key' THEN 'api_key' ELSE 'subscription' END,
        'source', CASE WHEN value->>'credential_kind'='provider_api_key' THEN COALESCE(value->>'source','custom') ELSE value->>'provider' END,
        'status', CASE
          WHEN value->>'credential_kind'='provider_api_key' THEN 'ok'
          WHEN value->>'status' IN ('active','connected') THEN 'ok'
          WHEN value->>'status'='reauthorization_required' THEN 'login'
          ELSE 'unknown' END)
      || jsonb_strip_nulls(jsonb_build_object(
        'endpoint', value->'connection'->>'endpoint',
        'protocol', CASE value->'connection'->>'protocol'
          WHEN 'anthropic_messages' THEN 'anthropic'
          WHEN 'openai_completions' THEN 'chat_completions'
          WHEN 'openai_responses' THEN 'responses' END,
        'auth', value->'connection'->>'auth_scheme',
        'cooldown_until', (extract(epoch FROM (value->>'cooldown_until')::timestamptz) * 1000)::bigint,
        'quota', CASE WHEN jsonb_typeof(value->'quota')='object' THEN
          ((value->'quota') - 'windows' - 'observed_at') || jsonb_strip_nulls(jsonb_build_object(
            'observed_at', (extract(epoch FROM (value->'quota'->>'observed_at')::timestamptz) * 1000)::bigint,
            'windows', COALESCE((
              SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'label', COALESCE(w->>'period',''),
                'used_percent', 100 - COALESCE((w->>'remaining_percent')::float, 100),
                'resets_at', (extract(epoch FROM (w->>'reset_at')::timestamptz) * 1000)::bigint,
                'minutes', CASE w->>'period' WHEN 'short' THEN 300 WHEN 'week' THEN 10080 WHEN 'month' THEN 43200 END,
                'model', NULLIF(w->>'model','')
              )) ORDER BY ord)
              FROM jsonb_array_elements(value->'quota'->'windows') WITH ORDINALITY AS t(w, ord)
            ), '[]'::jsonb)))
          END))
    WHERE value ? 'credential_kind'
    """)

    execute("DROP INDEX IF EXISTS subscription_accounts_email_idx")

    create(
      index(
        :subscription_accounts,
        [:tenant_id, "(value->>'source')", "lower(btrim(value->>'email'))", :id],
        name: :subscription_accounts_email_idx
      )
    )
  end

  def down do
    execute("""
    UPDATE subscription_accounts SET value =
      (value - 'credential' - 'source' - 'endpoint' - 'protocol' - 'auth' - 'quota' - 'cooldown_until' - 'status')
      || jsonb_build_object(
        'credential_kind', CASE WHEN value->>'credential'='api_key' THEN 'provider_api_key' ELSE 'subscription_oauth' END,
        'provider', CASE WHEN value->>'credential'='api_key' THEN 'custom' ELSE value->>'source' END,
        'status', CASE WHEN value->>'status'='login' THEN 'reauthorization_required' ELSE 'active' END)
      || CASE WHEN value->>'credential'='api_key' THEN jsonb_build_object(
        'source', value->>'source',
        'connection', jsonb_strip_nulls(jsonb_build_object(
          'endpoint', value->>'endpoint',
          'protocol', CASE value->>'protocol'
            WHEN 'anthropic' THEN 'anthropic_messages'
            WHEN 'chat_completions' THEN 'openai_completions'
            WHEN 'responses' THEN 'openai_responses' END,
          'auth_scheme', value->>'auth'))) ELSE '{}'::jsonb END
      || jsonb_strip_nulls(jsonb_build_object(
        'cooldown_until', to_char(to_timestamp((value->>'cooldown_until')::bigint / 1000.0) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'quota', CASE WHEN jsonb_typeof(value->'quota')='object' THEN
          ((value->'quota') - 'windows' - 'observed_at') || jsonb_strip_nulls(jsonb_build_object(
            'observed_at', to_char(to_timestamp((value->'quota'->>'observed_at')::bigint / 1000.0) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            'windows', COALESCE((
              SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'period', w->>'label',
                'remaining_percent', 100 - (w->>'used_percent')::float,
                'reset_at', to_char(to_timestamp((w->>'resets_at')::bigint / 1000.0) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                'model', w->>'model'
              )) ORDER BY ord)
              FROM jsonb_array_elements(value->'quota'->'windows') WITH ORDINALITY AS t(w, ord)
            ), '[]'::jsonb)))
          END))
    WHERE value ? 'credential'
    """)

    execute("DROP INDEX IF EXISTS subscription_accounts_email_idx")

    create(
      index(
        :subscription_accounts,
        [:tenant_id, "(value->>'provider')", "lower(btrim(value->>'email'))", :id],
        name: :subscription_accounts_email_idx
      )
    )
  end
end
