defmodule BridgeForTeams.Repo.Migrations.BackfillBillingAccounts do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE organizations
    SET salix_tenant_id = 'org_' || id::text
    WHERE NULLIF(BTRIM(salix_tenant_id), '') IS NULL
    """)

    execute("""
    UPDATE organizations
    SET billing_account_id = 'bridge-ba-' || salix_tenant_id
    WHERE NULLIF(BTRIM(billing_account_id), '') IS NULL
    """)

    execute("""
    ALTER TABLE organizations
      ADD CONSTRAINT organizations_salix_tenant_id_nonblank
      CHECK (BTRIM(salix_tenant_id) <> '')
    """)

    execute("""
    ALTER TABLE organizations
      ADD CONSTRAINT organizations_billing_account_id_nonblank
      CHECK (BTRIM(billing_account_id) <> '')
    """)

    execute("ALTER TABLE organizations ALTER COLUMN salix_tenant_id SET NOT NULL")
    execute("ALTER TABLE organizations ALTER COLUMN billing_account_id SET NOT NULL")

    execute("""
    INSERT INTO reconcile_outbox (
      aggregate,
      aggregate_id,
      op,
      payload,
      status,
      attempts,
      created_at
    )
    SELECT
      'project',
      p.id::text,
      'update_group',
      jsonb_build_object(
        'group_id', p.salix_group_id,
        'tenant_id', o.salix_tenant_id,
        'attrs', jsonb_build_object(
          'billing_owner', jsonb_build_object(
            'billing_account_id', o.billing_account_id,
            'surface', 'bridge',
            'product_owner_type', 'organization',
            'product_owner_id', o.id::text,
            'project_id', p.id::text,
            'salix_tenant_id', o.salix_tenant_id,
            'salix_group_id', p.salix_group_id,
            'router_agent_id', router.salix_agent_id,
            'charge_policy', 'platform_paid'
          )
        )
      ),
      'pending',
      0,
      now()
    FROM projects p
    JOIN organizations o ON o.id = p.org_id
    JOIN LATERAL (
      SELECT a.salix_agent_id
      FROM agents a
      WHERE a.project_id = p.id
        AND a.archived_at IS NULL
        AND a.salix_agent_id IS NOT NULL
        AND BTRIM(a.salix_agent_id) <> ''
        AND (a.slot = 'router' OR a.role = 'router')
      ORDER BY
        CASE WHEN a.slot = 'router' THEN 0 ELSE 1 END,
        a.created_at DESC
      LIMIT 1
    ) router ON TRUE
    WHERE p.archived_at IS NULL
      AND p.salix_group_id IS NOT NULL
      AND BTRIM(p.salix_group_id) <> ''
    """)
  end

  def down do
    execute("ALTER TABLE organizations ALTER COLUMN billing_account_id DROP NOT NULL")
    execute("ALTER TABLE organizations ALTER COLUMN salix_tenant_id DROP NOT NULL")

    execute("""
    ALTER TABLE organizations
      DROP CONSTRAINT IF EXISTS organizations_billing_account_id_nonblank
    """)

    execute("""
    ALTER TABLE organizations
      DROP CONSTRAINT IF EXISTS organizations_salix_tenant_id_nonblank
    """)
  end
end
