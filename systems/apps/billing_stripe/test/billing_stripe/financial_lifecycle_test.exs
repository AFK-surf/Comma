defmodule BillingStripe.FinancialLifecycleTest do
  use ExUnit.Case, async: false

  alias BillingStripe.Webhooks

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    Application.put_env(:billing_stripe, :stripe_api, BillingStripe.TestAPI)

    for key <- [
          :test_payment_intents,
          :test_charges,
          :test_disputes,
          :test_prices,
          :test_invoices,
          :test_invoice_payment_pages,
          :test_checkout_session_pages,
          :test_checkout_sessions
        ] do
      Application.delete_env(:billing_stripe, key)
    end

    start_supervised!(%{
      id: BillingStripe.TestAPI.Recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: BillingStripe.TestAPI.Recorder]]}
    })

    assert {:ok, _} = BillingStripe.sync_prices(Comma.Billing.PricingV1.catalog())

    on_exit(fn ->
      for key <- [
            :test_payment_intents,
            :test_charges,
            :test_disputes,
            :test_prices,
            :test_invoices,
            :test_invoice_payment_pages,
            :test_checkout_session_pages,
            :test_checkout_sessions
          ] do
        Application.delete_env(:billing_stripe, key)
      end
    end)

    :ok
  end

  test "annual paid upgrades retain invoice attribution and refund only the upgrade's unspent rights" do
    account = "ba_paid_upgrade"

    initial =
      invoice(
        account,
        "in_base",
        "pi_base",
        "comma_value_annual_v1",
        ~U[2026-09-01 00:00:00Z],
        ~U[2027-09-01 00:00:00Z]
      )

    assert {:ok, _} = deliver("evt_base", "invoice.paid", initial)

    partial_base = %{
      "id" => "ch_base",
      "payment_intent" => "pi_base",
      "amount" => 20_000,
      "amount_refunded" => 100
    }

    put_provider(:test_charges, partial_base["id"], partial_base)
    assert {:ok, _} = deliver("evt_partial_before_upgrade", "charge.refunded", partial_base)

    upgrade =
      invoice(
        account,
        "in_upgrade",
        "pi_upgrade",
        "comma_pro_annual_v1",
        ~U[2026-09-16 00:00:00Z],
        ~U[2027-09-01 00:00:00Z]
      )

    old_line = %{
      "amount" => -1000,
      "price" => %{"id" => price("comma_value_annual_v1")},
      "period" => upgrade["lines"]["data"] |> hd() |> Map.fetch!("period")
    }

    upgrade = put_in(upgrade, ["lines", "data"], [old_line | upgrade["lines"]["data"]])
    assert {:ok, _} = deliver("evt_upgrade", "invoice.paid", upgrade)
    assert amounts(account) == %{"in_base" => 20_000_000, "in_upgrade" => 20_000_000}
    assert {:ok, _} = deliver("evt_upgrade_again", "invoice.paid", upgrade)
    assert amounts(account) == %{"in_base" => 20_000_000, "in_upgrade" => 20_000_000}

    assert {:ok, _} =
             BillingCommerce.Subscriptions.run_due_cycles(%{at: ~U[2026-10-01 00:00:00Z]})

    assert amounts(account) == %{"in_base" => 40_000_000, "in_upgrade" => 60_000_000}

    partial = %{
      "id" => "ch_upgrade",
      "payment_intent" => "pi_upgrade",
      "amount" => 60_000,
      "amount_refunded" => 10_000
    }

    put_provider(:test_charges, partial["id"], partial)
    assert {:ok, _} = deliver("evt_partial", "charge.refunded", partial)
    assert amounts(account) == %{"in_base" => 40_000_000, "in_upgrade" => 60_000_000}

    # Establish a consumed portion in this grant lot. Compensation must report it, never charge the base lot.
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE credit_grants SET remaining_credits = remaining_credits - 5_000_000 WHERE metadata->>'stripe_invoice_id' = 'in_upgrade' AND valid_from = $1",
      [~U[2026-09-01 00:00:00Z]]
    )

    full = Map.put(partial, "amount_refunded", 60_000)
    put_provider(:test_charges, full["id"], full)
    assert {:ok, %{result: %{grants: reductions}}} = deliver("evt_full", "charge.refunded", full)
    assert Enum.sum(Enum.map(reductions, & &1.unapplied_credits)) == 5_000_000
    assert amounts(account) == %{"in_base" => 40_000_000, "in_upgrade" => 0}

    assert {:ok, _} =
             BillingCommerce.Subscriptions.run_due_cycles(%{at: ~U[2026-11-01 00:00:00Z]})

    assert amounts(account) == %{"in_base" => 60_000_000, "in_upgrade" => 0}
  end

  test "monthly upgrade across a calendar month reuses its paid cycle" do
    account = "ba_month_crossing"

    initial =
      invoice(
        account,
        "in_month_base",
        "pi_month_base",
        "comma_value_v1",
        ~U[2026-09-15 00:00:00Z],
        ~U[2026-10-15 00:00:00Z]
      )

    assert {:ok, _} = deliver("evt_month_base", "invoice.paid", initial)

    upgrade =
      invoice(
        account,
        "in_month_upgrade",
        "pi_month_upgrade",
        "comma_pro_v1",
        ~U[2026-10-01 00:00:00Z],
        ~U[2026-10-15 00:00:00Z]
      )

    old_line = %{
      "amount" => -1000,
      "price" => %{"id" => price("comma_value_v1")},
      "period" => hd(upgrade["lines"]["data"])["period"]
    }

    upgrade = put_in(upgrade, ["lines", "data"], [old_line | upgrade["lines"]["data"]])
    assert {:ok, _} = deliver("evt_month_upgrade", "invoice.paid", upgrade)

    assert amounts(account) == %{
             "in_month_base" => 20_000_000,
             "in_month_upgrade" => div(40_000_000 * 14, 30)
           }

    assert [[1]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT COUNT(*) FROM billing_subscription_cycles c JOIN billing_subscriptions s ON s.id = c.subscription_id WHERE s.billing_account_id = $1",
               [account]
             ).rows
  end

  test "annual upgrade keeps month-end cycles from its original paid period" do
    account = "ba_year_month_end"

    initial =
      invoice(
        account,
        "in_year_base",
        "pi_year_base",
        "comma_value_annual_v1",
        ~U[2026-10-31 00:00:00Z],
        ~U[2027-10-31 00:00:00Z]
      )

    assert {:ok, _} = deliver("evt_year_base", "invoice.paid", initial)

    upgrade =
      invoice(
        account,
        "in_year_upgrade",
        "pi_year_upgrade",
        "comma_pro_annual_v1",
        ~U[2026-12-15 00:00:00Z],
        ~U[2027-10-31 00:00:00Z]
      )

    old_line = %{
      "amount" => -1000,
      "price" => %{"id" => price("comma_value_annual_v1")},
      "period" => hd(upgrade["lines"]["data"])["period"]
    }

    upgrade = put_in(upgrade, ["lines", "data"], [old_line | upgrade["lines"]["data"]])
    assert {:ok, _} = deliver("evt_year_upgrade", "invoice.paid", upgrade)

    assert amounts(account) == %{
             "in_year_base" => 40_000_000,
             "in_year_upgrade" => div(40_000_000 * 16, 31)
           }

    assert [[12]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT COUNT(*) FROM billing_subscription_cycles c JOIN billing_subscriptions s ON s.id = c.subscription_id WHERE s.billing_account_id = $1",
               [account]
             ).rows
  end

  test "dispute win restores valid rights, loss revokes them, and delayed win cannot undo a refund" do
    account = "ba_dispute"

    assert {:ok, _} =
             deliver(
               "evt_dispute_pay",
               "invoice.paid",
               invoice(
                 account,
                 "in_dispute",
                 "pi_dispute",
                 "comma_value_v1",
                 ~U[2026-09-01 00:00:00Z],
                 ~U[2026-10-01 00:00:00Z]
               )
             )

    dispute = %{"id" => "dp_test", "payment_intent" => "pi_dispute", "status" => "under_review"}
    put_provider(:test_disputes, dispute["id"], dispute)
    assert {:ok, _} = deliver("evt_hold", "charge.dispute.created", dispute)
    assert grant_status(account) == {20_000_000, "suspended"}
    won = Map.put(dispute, "status", "won")
    put_provider(:test_disputes, dispute["id"], won)
    assert {:ok, _} = deliver("evt_win", "charge.dispute.closed", won)
    assert grant_status(account) == {20_000_000, "active"}
    assert {:ok, _} = deliver("evt_delayed_hold", "charge.dispute.created", dispute)
    assert grant_status(account) == {20_000_000, "active"}

    full = %{
      "id" => "ch_dispute",
      "payment_intent" => "pi_dispute",
      "amount" => 2000,
      "amount_refunded" => 2000
    }

    put_provider(:test_charges, full["id"], full)
    assert {:ok, _} = deliver("evt_refund_won", "charge.refunded", full)
    assert {:ok, _} = deliver("evt_delayed_win", "charge.dispute.closed", won)
    assert grant_status(account) == {0, "revoked"}

    other = "ba_lost_dispute"

    assert {:ok, _} =
             deliver(
               "evt_lost_pay",
               "invoice.paid",
               invoice(
                 other,
                 "in_lost",
                 "pi_lost",
                 "comma_value_v1",
                 ~U[2026-09-01 00:00:00Z],
                 ~U[2026-10-01 00:00:00Z]
               )
             )

    lost = %{"id" => "dp_lost", "payment_intent" => "pi_lost", "status" => "lost"}
    put_provider(:test_disputes, lost["id"], lost)
    assert {:ok, _} = deliver("evt_lost", "charge.dispute.closed", lost)
    assert grant_status(other) == {0, "revoked"}
  end

  test "foreign BFT catalog events are ignored and offline paid invoices do not issue credits" do
    bft = %{"id" => "in_bft", "lines" => %{"data" => [%{"price" => %{"id" => "price_bft"}}]}}

    put_provider(:test_prices, "price_bft", %{
      "id" => "price_bft",
      "lookup_key" => "bridge_for_teams_seat",
      "product" => %{"metadata" => %{}}
    })

    assert {:ok, %{result: %{ignored: true, reason: :foreign_product}}} =
             deliver("evt_bft", "invoice.paid", bft)

    # Clover no longer guarantees Charge.invoice. Resolve the exact payment
    # relation before classifying the foreign catalog, including retries.
    refund = %{
      "id" => "ch_bft",
      "payment_intent" => "pi_bft",
      "amount" => 2000,
      "amount_refunded" => 2000
    }

    put_provider(:test_charges, "ch_bft", refund)
    put_provider(:test_payment_intents, "pi_bft", %{"id" => "pi_bft", "metadata" => %{}})

    put_provider(:test_invoice_payment_pages, "pi_bft", %{
      "has_more" => true,
      "data" => [%{"invoice" => "in_bft"}]
    })

    assert {:error, :stripe_event_payment_links_incomplete} =
             deliver("evt_bft_refund", "charge.refunded", refund)

    put_provider(:test_invoice_payment_pages, "pi_bft", %{
      "has_more" => false,
      "data" => [%{"invoice" => "in_bft"}]
    })

    put_provider(:test_invoices, "in_bft", bft)

    assert {:ok, %{result: %{ignored: true, reason: :foreign_product}}} =
             deliver("evt_bft_refund", "charge.refunded", refund)

    offline =
      invoice(
        "ba_offline",
        "in_offline",
        "pi_offline",
        "comma_value_v1",
        ~U[2026-09-01 00:00:00Z],
        ~U[2026-10-01 00:00:00Z]
      )
      |> Map.put("paid_out_of_band", true)

    assert {:ok, %{result: %{ignored: true, reason: :not_stripe_payment}}} =
             deliver("evt_offline", "invoice.paid", offline)

    assert amounts("ba_offline") == %{}
  end

  test "refund before checkout remains retryable and a refunded payment never becomes spendable" do
    account = "ba_early_refund"
    metadata = metadata(account, "comma_addon_4m", "2026-06")

    intent = %{
      "id" => "pi_early",
      "status" => "succeeded",
      "amount_received" => 499,
      "metadata" => metadata,
      "latest_charge" => %{
        "paid" => true,
        "created" => 1_790_000_000,
        "amount_refunded" => 499,
        "refunded" => true
      }
    }

    put_provider(:test_payment_intents, "pi_early", intent)

    charge = %{
      "id" => "ch_early",
      "payment_intent" => "pi_early",
      "amount" => 499,
      "amount_refunded" => 499
    }

    put_provider(:test_charges, charge["id"], charge)

    assert {:error, :stripe_payment_not_recorded} =
             deliver("evt_early_refund", "charge.refunded", charge)

    session = %{
      "id" => "cs_early",
      "mode" => "payment",
      "payment_status" => "paid",
      "payment_intent" => "pi_early",
      "metadata" => metadata
    }

    assert {:ok, _} = deliver("evt_early_checkout", "checkout.session.completed", session)
    assert grant_status(account) == {0, "revoked"}
    assert {:ok, _} = deliver("evt_early_refund", "charge.refunded", charge)
    assert grant_status(account) == {0, "revoked"}
  end

  test "asynchronous payment uses Stripe confirmation UTC month rather than Checkout creation month" do
    account = "ba_month_boundary"

    session = %{
      "id" => "cs_boundary",
      "mode" => "payment",
      "payment_status" => "unpaid",
      "payment_intent" => "pi_boundary",
      "created" => DateTime.to_unix(~U[2026-06-30 23:59:00Z]),
      "metadata" => metadata(account, "comma_addon_4m", "2026-06")
    }

    assert {:ok, _} =
             deliver(
               "evt_boundary_pending",
               "checkout.session.completed",
               session,
               ~U[2026-06-30 23:59:00Z]
             )

    assert {:ok, _} =
             deliver(
               "evt_boundary_paid",
               "checkout.session.async_payment_succeeded",
               session,
               ~U[2026-07-01 00:01:00Z]
             )

    assert [[~U[2026-07-01 00:01:00.000000Z], ~U[2026-08-01 00:00:00.000000Z]]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT valid_from, expires_at FROM credit_grants WHERE billing_account_id = $1",
               [account]
             ).rows
  end

  defp invoice(account, id, pi, key, starts, ends) do
    {:ok, plan} =
      BillingCommerce.get_provider_plan(%{
        surface: "comma",
        provider: "stripe",
        provider_lookup_key: key
      })

    put_provider(:test_payment_intents, pi, %{
      "id" => pi,
      "status" => "succeeded",
      "amount_received" => plan.amount_minor,
      "latest_charge" => %{"paid" => true, "created" => DateTime.to_unix(starts)},
      "metadata" => %{}
    })

    %{
      "id" => id,
      "subscription" => "sub_" <> account,
      "amount_paid" => plan.amount_minor,
      "payment_intent" => pi,
      "status_transitions" => %{"paid_at" => DateTime.to_unix(starts)},
      "metadata" => metadata(account, plan.package_code, plan.package_version),
      "lines" => %{
        "has_more" => false,
        "data" => [
          %{
            "amount" => plan.amount_minor,
            "price" => %{"id" => plan.provider_price_id},
            "period" => %{"start" => DateTime.to_unix(starts), "end" => DateTime.to_unix(ends)}
          }
        ]
      }
    }
  end

  defp metadata(account, code, version),
    do: %{
      "billing_account_id" => account,
      "surface" => "comma",
      "product_owner_type" => "workspace",
      "product_owner_id" => "wsp_" <> account,
      "package_code" => code,
      "package_version" => version
    }

  defp deliver(id, type, object, created \\ ~U[2026-09-01 00:00:00Z]) do
    event = %{
      "id" => id,
      "type" => type,
      "created" => DateTime.to_unix(created),
      "data" => %{"object" => object}
    }

    Webhooks.handle_webhook(Jason.encode!(event), "audit", [])
  end

  defp put_provider(key, id, value),
    do:
      Application.put_env(
        :billing_stripe,
        key,
        Map.put(Application.get_env(:billing_stripe, key, %{}), id, value)
      )

  defp price(key) do
    {:ok, plan} =
      BillingCommerce.get_provider_plan(%{
        surface: "comma",
        provider: "stripe",
        provider_lookup_key: key
      })

    plan.provider_price_id
  end

  defp amounts(account) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "SELECT metadata->>'stripe_invoice_id', SUM(remaining_credits)::bigint FROM credit_grants WHERE billing_account_id = $1 GROUP BY 1",
      [account]
    ).rows
    |> Map.new(fn [invoice, amount] -> {invoice, amount} end)
  end

  defp grant_status(account) do
    [[remaining, status]] =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT remaining_credits, status FROM credit_grants WHERE billing_account_id = $1",
        [account]
      ).rows

    {remaining, status}
  end
end
