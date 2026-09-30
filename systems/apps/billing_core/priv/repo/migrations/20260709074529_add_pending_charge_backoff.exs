defmodule BillingCore.Repo.Migrations.AddPendingChargeBackoff do
  use Ecto.Migration

  def up do
    # Retry-backoff state for the pending-charge sweeper. Legacy rows carry
    # attempts=0 and next_attempt_at=NULL, which the sweep treats as due now.
    execute("""
    ALTER TABLE pending_meter_charges
      ADD COLUMN IF NOT EXISTS attempts integer NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS next_attempt_at timestamptz
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS pending_meter_charges_due_idx
      ON pending_meter_charges (status, next_attempt_at, expires_at, id)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS pending_meter_charges_due_idx")

    execute("""
    ALTER TABLE pending_meter_charges
      DROP COLUMN IF EXISTS next_attempt_at,
      DROP COLUMN IF EXISTS attempts
    """)
  end
end
