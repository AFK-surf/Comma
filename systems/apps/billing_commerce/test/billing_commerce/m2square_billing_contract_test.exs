defmodule BillingCommerce.M2squareBillingContractTest do
  use SystemsClock.Case, async: false

  alias BillingCommerce.{PackageCatalog, PaidCycles, SubscriptionCheckout, Subscriptions}
  alias BillingCore.TeamsAccess

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    package = seed_teams_package!()
    {:ok, package: package}
  end

  test "m2square_term subscription and 30-48 seat PaidCycles.record_invoice grant access", %{
    package: package
  } do
    now = SystemsClock.utc_now()
    starts = DateTime.add(now, -3_600, :second)
    ends = DateTime.add(now, 90 * 86_400, :second)

    for seats <- [30, 48] do
      account_id = "bridge-ba-m2_seats_#{seats}"
      org_id = "org_m2_seats_#{seats}"
      insert_account!(account_id, org_id, true)

      assert {:ok, %{subscription: subscription, cycles: [cycle]}} =
               Subscriptions.create_subscription(%{
                 billing_account_id: account_id,
                 surface: "bridge",
                 product_owner_type: "organization",
                 product_owner_id: org_id,
                 package_code: package.package_code,
                 package_version: package.version,
                 source_type: "m2square_term",
                 source_id: "m2_sub_#{seats}",
                 source_event_id: "m2_evt_#{seats}",
                 idempotency_key: "m2square:sub:#{seats}",
                 periods: [
                   %{cycle_key: "m2_q1_#{seats}", valid_from: starts, expires_at: ends}
                 ]
               })

      assert subscription.source_type == "m2square_term"

      order_key = "m2square:mtt#{String.duplicate("a", 21)}"

      assert {:ok, %{invoice_id: ^order_key, cycle_count: 1}} =
               PaidCycles.record_invoice(
                 subscription,
                 package,
                 order_key,
                 %{
                   valid_from: starts,
                   expires_at: ends,
                   payment_intent_id: order_key,
                   fully_refunded: false,
                   disputes: %{},
                   teams_seats: seats
                 },
                 now
               )

      assert {:ok, ^seats} = TeamsAccess.check(account_id)
      assert {:ok, cov} = TeamsAccess.coverage(account_id, now)
      assert cov.active == true
      assert cov.licensed_seats == seats
      assert cov.provider == "m2square"
      assert cycle.id != nil
    end
  end

  test "revoke_payment_source!/5 revokes only the exact allocation key and preserves Stripe history",
       %{package: package} do
    now = SystemsClock.utc_now()
    old_start = DateTime.add(now, -180 * 86_400, :second)
    old_end = DateTime.add(now, -90 * 86_400, :second)
    cur_start = DateTime.add(now, -3_600, :second)
    cur_end = DateTime.add(now, 90 * 86_400, :second)

    account_id = "bridge-ba-m2_revoke_exact"
    org_id = "org_m2_revoke_exact"
    insert_account!(account_id, org_id, true)

    # Historical Stripe subscription allocation on the same account
    assert {:ok, %{subscription: stripe_sub, cycles: [stripe_cycle]}} =
             Subscriptions.create_subscription(%{
               billing_account_id: account_id,
               surface: "bridge",
               product_owner_type: "organization",
               product_owner_id: org_id,
               package_code: package.package_code,
               package_version: package.version,
               source_type: "stripe_subscription",
               source_id: "sub_stripe_hist",
               source_event_id: "evt_stripe_hist",
               idempotency_key: "stripe:hist",
               periods: [
                 %{cycle_key: "stripe_hist_q1", valid_from: old_start, expires_at: old_end}
               ]
             })

    assert {:ok, _} =
             PaidCycles.record_invoice(
               stripe_sub,
               package,
               "in_stripe_hist_1",
               %{
                 valid_from: old_start,
                 expires_at: old_end,
                 payment_intent_id: "pi_stripe_hist_1",
                 fully_refunded: false,
                 disputes: %{},
                 teams_seats: 100
               },
               old_start
             )

    # Current M2square cycle with two distinct payment source keys
    assert {:ok, %{subscription: m2_sub, cycles: [m2_cycle]}} =
             Subscriptions.create_subscription(%{
               billing_account_id: account_id,
               surface: "bridge",
               product_owner_type: "organization",
               product_owner_id: org_id,
               package_code: package.package_code,
               package_version: package.version,
               source_type: "m2square_term",
               source_id: "m2_sub_revoke",
               source_event_id: "m2_evt_revoke",
               idempotency_key: "m2square:sub:revoke",
               periods: [
                 %{cycle_key: "m2_cur_q1", valid_from: cur_start, expires_at: cur_end}
               ]
             })

    m2_key = "m2square:mttbbbbbbbbbbbbbbbbbbbbb"
    other_key = "m2square:mttccccccccccccccccccccc"

    for {key, seats} <- [{m2_key, 35}, {other_key, 30}] do
      assert {:ok, _} =
               PaidCycles.record_invoice(
                 m2_sub,
                 package,
                 key,
                 %{
                   valid_from: cur_start,
                   expires_at: cur_end,
                   payment_intent_id: key,
                   fully_refunded: false,
                   disputes: %{},
                   teams_seats: seats
                 },
                 now
               )
    end

    assert :ok =
             PaidCycles.revoke_payment_source!(
               BillingCore.Repo,
               account_id,
               m2_cycle.id,
               m2_key,
               %{reason: "m2square_reversed", provider_order_id: "ord_123"}
             )

    # Idempotent repeat returns :ok
    assert :ok =
             PaidCycles.revoke_payment_source!(
               BillingCore.Repo,
               account_id,
               m2_cycle.id,
               m2_key,
               %{reason: "m2square_reversed"}
             )

    m2_sources = cycle_payment_sources(m2_cycle.id)
    assert m2_sources[m2_key]["state"] == "refunded"
    assert m2_sources[m2_key]["refund"]["type"] == "refund"
    assert m2_sources[m2_key]["refund"]["full"] == true
    assert m2_sources[m2_key]["refund"]["reason"] == "m2square_reversed"
    assert m2_sources[m2_key]["refund"]["provider_order_id"] == "ord_123"
    # Sibling allocation on the same cycle is untouched
    assert m2_sources[other_key]["state"] == "paid"
    assert m2_sources[other_key]["teams_seats"] == 30

    # Historical Stripe allocation on the same account is untouched
    stripe_sources = cycle_payment_sources(stripe_cycle.id)
    assert stripe_sources["in_stripe_hist_1"]["state"] == "paid"
    assert stripe_sources["in_stripe_hist_1"]["teams_seats"] == 100

    # Missing allocation key rolls back with :payment_source_not_found
    assert {:error, :payment_source_not_found} =
             BillingCore.Repo.transaction(fn ->
               PaidCycles.revoke_payment_source!(
                 BillingCore.Repo,
                 account_id,
                 m2_cycle.id,
                 "m2square:missing_key",
                 %{}
               )
             end)
  end

  test "SubscriptionCheckout blocks unexpired M2square paid cycle and 1-hour pending M2square orders",
       %{package: package} do
    now = SystemsClock.utc_now()
    starts = DateTime.add(now, -3_600, :second)
    ends = DateTime.add(now, 86_400, :second)

    # 1. Unexpired M2square paid cycle blocks Stripe checkout, unblocks after refund
    paid_account = "bridge-ba-m2_block_paid"
    paid_org = "org_m2_block_paid"
    insert_account!(paid_account, paid_org, true)

    assert {:ok, %{subscription: sub, cycles: [cycle]}} =
             Subscriptions.create_subscription(%{
               billing_account_id: paid_account,
               surface: "bridge",
               product_owner_type: "organization",
               product_owner_id: paid_org,
               package_code: package.package_code,
               package_version: package.version,
               source_type: "m2square_term",
               source_id: "m2_sub_block",
               source_event_id: "m2_evt_block",
               idempotency_key: "m2square:sub:block",
               periods: [%{cycle_key: "m2_block_q1", valid_from: starts, expires_at: ends}]
             })

    m2_key = "m2square:mttddddddddddddddddddddd"

    assert {:ok, _} =
             PaidCycles.record_invoice(
               sub,
               package,
               m2_key,
               %{
                 valid_from: starts,
                 expires_at: ends,
                 payment_intent_id: m2_key,
                 fully_refunded: false,
                 disputes: %{},
                 teams_seats: 32
               },
               now
             )

    checkout_attrs = %{
      billing_account_id: paid_account,
      provider_price_id: "price_teams_quarterly",
      quantity: 100
    }

    assert {:error, :subscription_already_exists} =
             SubscriptionCheckout.create(
               checkout_attrs,
               fn _ -> flunk("must not create Stripe session") end,
               fn _ -> flunk("must not retrieve Stripe session") end
             )

    assert :ok =
             PaidCycles.revoke_payment_source!(BillingCore.Repo, paid_account, cycle.id, m2_key)

    assert {:ok, %{"id" => "cs_after_refund"}} =
             SubscriptionCheckout.create(
               checkout_attrs,
               fn _ -> {:ok, %{"id" => "cs_after_refund", "status" => "open"}} end,
               fn _ -> flunk("must not retrieve") end
             )

    # 2. Pending M2square order within 1-hour window blocks Stripe checkout; expired order allows it
    pending_account = "bridge-ba-m2_block_pending"
    pending_org = "org_m2_block_pending"
    insert_account!(pending_account, pending_org, true)

    insert_m2square_order!(
      "mttopenorderaaaaaaaaaaaa",
      pending_account,
      pending_org,
      "open",
      DateTime.add(now, -1_800, :second)
    )

    pending_attrs = %{
      billing_account_id: pending_account,
      provider_price_id: "price_teams_quarterly",
      quantity: 100
    }

    assert {:error, :subscription_checkout_pending} =
             SubscriptionCheckout.create(
               pending_attrs,
               fn _ -> flunk("must not create Stripe session") end,
               fn _ -> flunk("must not retrieve Stripe session") end
             )

    # Age the pending order past 1 hour -> Stripe checkout is allowed
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_m2square_orders SET inserted_at = $2 WHERE mch_order_id = $1",
      ["mttopenorderaaaaaaaaaaaa", DateTime.add(now, -3_601, :second)]
    )

    assert {:ok, %{"id" => "cs_after_window"}} =
             SubscriptionCheckout.create(
               pending_attrs,
               fn _ -> {:ok, %{"id" => "cs_after_window", "status" => "open"}} end,
               fn _ -> flunk("must not retrieve") end
             )
  end

  test "SubscriptionCheckout.reserve rejects expired quote_expires_at under row lock without clearing existing pending session" do
    now = SystemsClock.utc_now()
    now_unix = DateTime.to_unix(now, :second)

    # 1. Fresh account with expired quote_expires_at (exact boundary now_unix >= expires_at) -> :quote_expired
    fresh_account = "bridge-ba-quote_exp_fresh"
    fresh_org = "org_quote_exp_fresh"
    insert_account!(fresh_account, fresh_org, true)

    assert {:error, :quote_expired} =
             SubscriptionCheckout.create(
               %{
                 billing_account_id: fresh_account,
                 provider_price_id: "price_teams_quarterly",
                 quantity: 100,
                 quote_expires_at: now_unix
               },
               fn _ -> flunk("must not create Stripe session after quote expiry") end,
               fn _ -> flunk("must not retrieve Stripe session after quote expiry") end
             )

    assert [[nil]] ==
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT subscription_checkout FROM billing_accounts WHERE id = $1",
               [fresh_account]
             ).rows

    # 2. Unexpired quote_expires_at succeeds and strips quote_expires_at from persisted request JSON
    assert {:ok, %{"id" => "cs_valid_quote"}} =
             SubscriptionCheckout.create(
               %{
                 billing_account_id: fresh_account,
                 provider_price_id: "price_teams_quarterly",
                 quantity: 100,
                 quote_expires_at: now_unix + 60
               },
               fn req ->
                 refute Map.has_key?(req, "quote_expires_at")
                 {:ok, %{"id" => "cs_valid_quote", "status" => "open"}}
               end,
               fn _ -> flunk("must not retrieve") end
             )

    [[stored_pending]] =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT subscription_checkout FROM billing_accounts WHERE id = $1",
        [fresh_account]
      ).rows

    assert stored_pending["session"]["id"] == "cs_valid_quote"
    refute Map.has_key?(stored_pending["request"], "quote_expires_at")

    # 3. Existing pending session on account + expired quote_expires_at -> STILL rejected with :quote_expired,
    #    and existing pending session stays untouched in DB!
    assert {:error, :quote_expired} =
             SubscriptionCheckout.create(
               %{
                 billing_account_id: fresh_account,
                 provider_price_id: "price_teams_quarterly",
                 quantity: 100,
                 quote_expires_at: now_unix - 1
               },
               fn _ -> flunk("must not create") end,
               fn _ -> flunk("must not retrieve existing session after quote expiry") end
             )

    [[after_expired_pending]] =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT subscription_checkout FROM billing_accounts WHERE id = $1",
        [fresh_account]
      ).rows

    assert after_expired_pending == stored_pending
  end

  defp seed_teams_package! do
    {:ok, _} =
      PackageCatalog.create_package(%{
        code: "bridge_teams_seat_quarterly_m2_test",
        surface: "bridge",
        name: "Bridge Teams Quarterly"
      })

    {:ok, version} =
      PackageCatalog.create_package_version(%{
        package_code: "bridge_teams_seat_quarterly_m2_test",
        version: "2026-11",
        surface: "bridge",
        kind: "subscription",
        billing_period: "quarter",
        grant_credits: 0,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 24_000,
        usage_policy: %{},
        effective_at: ~U[2026-01-01 00:00:00Z],
        status: "active"
      })

    version
  end

  defp insert_account!(account_id, org_id, required?) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      INSERT INTO billing_accounts (
        id, surface, product_owner_type, product_owner_id, status,
        teams_subscription_required, inserted_at, updated_at
      ) VALUES ($1, 'bridge', 'organization', $2, 'active', $3, now(), now())
      """,
      [account_id, org_id, required?]
    )
  end

  defp insert_m2square_order!(mch_order_id, account_id, org_id, status, inserted_at) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      INSERT INTO billing_m2square_orders (
        mch_order_id, billing_account_id, product_owner_id, kind, target_slot,
        country, payment_type, currency, display_currency, teams_seats,
        usd_net_minor, locked_amount, fx_rate, fx_source, fee_rate, markup_rate,
        status, inserted_at, updated_at
      ) VALUES (
        $1, $2, $3, 'signup', 'initial',
        'BR', 'PIX', 'BRL', 'BRL', 30,
        720000, '37500.00', '0.20', 'stripe_fx_quotes', '0.04', '0',
        $4, $5, $5
      )
      """,
      [mch_order_id, account_id, org_id, status, inserted_at]
    )
  end

  defp cycle_payment_sources(cycle_id) do
    %{rows: [[metadata]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT source_metadata FROM billing_subscription_cycles WHERE id = $1",
        [cycle_id]
      )

    BillingCore.Metadata.object(metadata)["payment_sources"] || %{}
  end
end
