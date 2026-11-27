defmodule BillingCore.Repo.Migrations.AddM2squareOrders do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE billing_m2square_orders (
      mch_order_id text PRIMARY KEY,
      provider_order_id text,
      billing_account_id text NOT NULL REFERENCES billing_accounts(id),
      product_owner_id text NOT NULL,
      kind text NOT NULL,
      target_slot text NOT NULL,
      country text NOT NULL,
      payment_type text NOT NULL,
      currency text NOT NULL,
      display_currency text NOT NULL,
      teams_seats integer NOT NULL,
      usd_net_minor bigint NOT NULL,
      locked_amount text NOT NULL,
      fx_rate text NOT NULL,
      fx_source text NOT NULL,
      fee_rate text NOT NULL,
      markup_rate text NOT NULL,
      signup_snapshot jsonb,
      checkout_url text,
      status text NOT NULL DEFAULT 'creating',
      real_amount text,
      mch_fee text,
      bank_id text,
      duplicate_events jsonb NOT NULL DEFAULT '[]'::jsonb,
      subscription_id text,
      cycle_id text,
      paid_at timestamptz,
      reversed_at timestamptz,
      refund_metadata jsonb,
      notification_claimed_at timestamptz,
      notified_at timestamptz,
      last_checked_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT billing_m2square_orders_kind_check CHECK (kind IN ('signup', 'renewal')),
      CONSTRAINT billing_m2square_orders_seats_check CHECK (teams_seats >= 30 AND teams_seats <= 48),
      CONSTRAINT billing_m2square_orders_status_check CHECK (
        status IN ('creating', 'open', 'paid', 'failed', 'reversed', 'conflict_paid', 'quarantined')
      )
    )
    """)

    execute("""
    CREATE UNIQUE INDEX billing_m2square_orders_provider_order_id_idx
      ON billing_m2square_orders (provider_order_id)
      WHERE provider_order_id IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX billing_m2square_orders_paid_slot_idx
      ON billing_m2square_orders (billing_account_id, target_slot)
      WHERE status = 'paid'
    """)

    execute("""
    CREATE INDEX billing_m2square_orders_account_time_idx
      ON billing_m2square_orders (billing_account_id, inserted_at DESC)
    """)
  end

  def down do
    execute("DROP TABLE billing_m2square_orders")
  end
end
