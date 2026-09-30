defmodule BillingCore.Metering.PricingBackfillTest do
  use ExUnit.Case, async: true

  alias BillingCore.{Charges, State}
  alias BillingCore.Metering.PricingBackfill

  @now ~U[2026-06-17 00:00:00Z]

  test "run/1 charges active pending meter charges once pricing exists" do
    state = State.new(grants: [grant("acct_1", 50)])

    assert {:pending, _pending, state} =
             Charges.charge_meter_event(%{
               state: state,
               billing_account_id: "acct_1",
               source_key: "usage_1",
               provider: "openai",
               sku: "tokens",
               quantity: 2.0,
               metered_at: @now
             })

    state = %{
      state
      | pricing_catalog: [%{provider: "openai", sku: "tokens", credits_per_unit: 10}]
    }

    assert {:ok, summary, state} =
             PricingBackfill.run(%{state: state, now: ~U[2026-06-18 00:00:00Z]})

    assert summary.charged_count == 1
    assert summary.pending_count == 0
    assert summary.expired_count == 0
    assert [%{remaining_credits: 30}] = state.grants
    assert state.pending_meter_charges == %{}
  end

  test "run/1 expires pending meter charges after their expiry" do
    state =
      State.new(
        pending_meter_charges: %{
          {"acct_1", "usage_old"} => %{
            billing_account_id: "acct_1",
            source_key: "usage_old",
            provider: "openai",
            sku: "tokens",
            quantity: 1,
            metered_at: @now,
            expires_at: ~U[2026-07-18 00:00:00Z]
          }
        }
      )

    assert {:ok, summary, state} =
             PricingBackfill.run(%{state: state, now: ~U[2026-07-19 00:00:00Z]})

    assert summary.expired_count == 1
    assert summary.charged_count == 0

    assert %{
             {"acct_1", "usage_old"} => %{
               status: :expired_unpriced,
               pricing_status: :expired_unpriced
             }
           } = state.pending_meter_charges

    assert [%{source_key: "usage_old", status: :expired_unpriced}] = summary.expired
  end

  defp grant(account_id, credits) do
    %{
      id: "grant_#{account_id}",
      billing_account_id: account_id,
      remaining_credits: credits,
      expires_at: ~U[2026-06-18 00:00:00Z]
    }
  end
end
