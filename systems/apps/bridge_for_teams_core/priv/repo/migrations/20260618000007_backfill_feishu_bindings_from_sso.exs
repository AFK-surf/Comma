defmodule BridgeForTeams.Repo.Migrations.BackfillFeishuBindingsFromSso do
  use Ecto.Migration

  # RFC feishu-onboarding-rfc.md §4.5 "迁移已有 setup": orgs that configured
  # Feishu SSO before App Bindings existed have an `org_sso_connections` row but
  # no `feishu_app_bindings` row, so the reworked SSO card + Feishu apps tab would
  # wrongly show them as "no Feishu app". Backfill a binding (SSO posture only —
  # per option B the secret stays in org_sso_connections, the binding only records
  # `*_configured`) so an existing Feishu-SSO org surfaces as a managed app.
  #
  # SSO side only: the bot side lives in Salix (per-project connects) and can't be
  # reached from a SQL migration; existing bot connects keep working off their own
  # stored credentials and a later runtime reconcile can flip `bot_enabled`.
  # Idempotent: skips any (org_id, app_id) that already has a binding.
  def up do
    execute("""
    INSERT INTO feishu_app_bindings
      (id, org_id, app_id, sso_enabled, bot_enabled,
       app_secret_configured, verification_token_configured, encrypt_key_configured,
       created_at, updated_at)
    SELECT
      uuid_generate_v7(), s.org_id, s.client_id, true, false,
      (s.client_secret IS NOT NULL AND s.client_secret <> ''), false, false,
      now(), now()
    FROM org_sso_connections s
    WHERE s.provider = 'feishu'
      AND s.client_id IS NOT NULL AND s.client_id <> ''
      AND NOT EXISTS (
        SELECT 1 FROM feishu_app_bindings b
        WHERE b.org_id = s.org_id AND b.app_id = s.client_id
      )
    """)
  end

  def down do
    # Irreversible: a backfilled binding is indistinguishable from a
    # user-created one, and dropping bindings could orphan real config. No-op.
    :ok
  end
end
