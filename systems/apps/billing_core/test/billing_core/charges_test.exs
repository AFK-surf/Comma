defmodule BillingCore.ChargesTest do
  use ExUnit.Case, async: true

  alias BillingCore.{Charges, State}

  @now ~U[2026-06-17 00:00:00Z]

  defp event(state, attrs \\ []) do
    Map.merge(
      %{
        state: state,
        billing_account_id: "acct_1",
        source_key: "usage_1",
        provider: "openai",
        sku: "tokens",
        quantity: 1.0,
        metered_at: @now
      },
      Map.new(attrs)
    )
  end

  test "charge_meter_event/1 is idempotent by billing account and source key" do
    state =
      State.new(
        pricing_catalog: [%{provider: "openai", sku: "tokens", credits_per_unit: 10}],
        grants: [
          %{
            id: "grant_1",
            billing_account_id: "acct_1",
            remaining_credits: 100,
            expires_at: ~U[2026-06-18 00:00:00Z]
          }
        ]
      )

    assert {:ok, charge, state} = Charges.charge_meter_event(event(state))
    assert charge.charged_credits == 10
    assert charge.grant_debits == [%{grant_id: "grant_1", credits: 10}]
    assert [%{remaining_credits: 90}] = state.grants

    assert {:ok, duplicate, same_state} = Charges.charge_meter_event(event(state))
    assert duplicate.idempotent == true
    assert duplicate.charged_credits == 10
    assert [%{remaining_credits: 90}] = same_state.grants
    assert length(same_state.credit_ledger) == 1
  end

  test "consumes grants before balance" do
    state =
      State.new(
        pricing_catalog: [%{provider: "openai", sku: "tokens", credits_per_unit: 10}],
        grants: [
          %{
            id: "grant_1",
            billing_account_id: "acct_1",
            remaining_credits: 6,
            expires_at: ~U[2026-06-18 00:00:00Z]
          }
        ]
      )

    assert {:ok, charge, state} = Charges.charge_meter_event(event(state))
    assert charge.grant_credits == 6
    assert charge.grace_credits == 4
    assert charge.balance_after == 0
    assert state.grants == []
  end

  test "does not consume expired or revoked grants and records grant debits" do
    state =
      State.new(
        pricing_catalog: [%{provider: "openai", sku: "tokens", credits_per_unit: 10}],
        grants: [
          %{
            id: "expired",
            billing_account_id: "acct_1",
            remaining_credits: 100,
            expires_at: ~U[2026-06-16 00:00:00Z]
          },
          %{
            id: "revoked",
            billing_account_id: "acct_1",
            remaining_credits: 100,
            status: "revoked",
            expires_at: ~U[2026-06-18 00:00:00Z]
          },
          %{
            id: "active",
            billing_account_id: "acct_1",
            remaining_credits: 25,
            status: "active",
            expires_at: ~U[2026-06-18 00:00:00Z]
          }
        ]
      )

    assert {:ok, charge, state} = Charges.charge_meter_event(event(state, quantity: 2))
    assert charge.charged_credits == 20
    assert charge.grant_debits == [%{grant_id: "active", credits: 20}]
    assert Enum.find(state.grants, &(&1.id == "active")).remaining_credits == 5
    assert Enum.find(state.grants, &(&1.id == "expired")).remaining_credits == 100
    assert Enum.find(state.grants, &(&1.id == "revoked")).remaining_credits == 100
  end

  test "unlimited metered charge records cost without consuming credits or grace" do
    state =
      State.new(
        pricing_catalog: [%{provider: "openai", sku: "tokens", credits_per_unit: 10}],
        grants: [
          %{
            id: "unlimited",
            billing_account_id: "acct_1",
            remaining_credits: 0,
            status: "active",
            valid_from: ~U[2026-06-01 00:00:00Z],
            expires_at: ~U[2026-07-01 00:00:00Z],
            policy_snapshot: %{"usage_credits" => %{"mode" => "unlimited_metered"}}
          }
        ]
      )

    assert {:ok, charge, state} = Charges.charge_meter_event(event(state, quantity: 2))

    assert charge.status == :unlimited_metered
    assert charge.entitlement_mode == :unlimited_metered
    assert charge.calculated_credits == 20
    assert charge.charged_credits == 0
    assert charge.grace_credits == 0
    assert charge.grant_debits == []
    assert [%{remaining_credits: 0}] = state.grants
  end

  test "carries fractional meter rounding remainders" do
    state =
      State.new(
        pricing_catalog: [%{provider: "openai", sku: "tokens", credits_per_unit: 10}],
        grants: [
          %{
            id: "grant_1",
            billing_account_id: "acct_1",
            remaining_credits: 100,
            expires_at: ~U[2026-06-18 00:00:00Z]
          }
        ]
      )

    assert {:ok, first, state} = Charges.charge_meter_event(event(state, quantity: 0.25))
    assert first.charged_credits == 2
    assert_in_delta first.rounding_remainder, 0.5, 0.00001

    assert {:ok, second, state} =
             Charges.charge_meter_event(event(state, source_key: "usage_2", quantity: 0.25))

    assert second.charged_credits == 3
    assert_in_delta second.rounding_remainder, 0.0, 0.00001
    assert [%{remaining_credits: 95}] = state.grants
  end

  test "records pending meter charges for missing pricing with one-month expiry" do
    state = State.new()

    assert {:pending, pending, state} = Charges.charge_meter_event(event(state))
    assert pending.status == :pending
    assert pending.pricing_status == :missing_pricing
    assert pending.expires_at == ~U[2026-07-18 00:00:00Z]
    assert map_size(state.pending_meter_charges) == 1
    assert state.credit_ledger == []
  end
end
