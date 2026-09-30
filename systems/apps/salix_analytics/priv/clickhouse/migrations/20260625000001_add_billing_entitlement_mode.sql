ALTER TABLE {{database}}.fee_control_checks
  ADD COLUMN IF NOT EXISTS entitlement_mode String AFTER decision_id;

ALTER TABLE {{database}}.billing_charge_events
  ADD COLUMN IF NOT EXISTS entitlement_mode String AFTER balance_after;
