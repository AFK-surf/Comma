defmodule BillingStripe.WebhooksTest do
  use ExUnit.Case, async: false

  alias BillingCommerce.{PackageCatalog, Subscriptions}
  alias BillingStripe.Checkout
  alias BillingStripe.Webhooks

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    seed_package("comma_monthly", "comma")
    seed_package("comma_topup", "comma", kind: "one_time")
    Application.put_env(:billing_stripe, :webhook_secret, "whsec_test")
    Application.put_env(:billing_stripe, :secret_key, "sk_test_secret")
    Application.put_env(:billing_stripe, :stripe_api, BillingStripe.TestAPI)
    Application.delete_env(:billing_stripe, :test_payment_intents)
    Application.delete_env(:billing_stripe, :test_subscriptions)

    start_supervised!(%{
      id: BillingStripe.TestAPI.Recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: BillingStripe.TestAPI.Recorder]]}
    })

    start_supervised!(%{
      id: __MODULE__.ProjectionLog,
      start: {Agent, :start_link, [fn -> [] end, [name: __MODULE__.ProjectionLog]]}
    })

    Application.put_env(:billing_commerce, :billing_source_typed_sink, __MODULE__.ProjectionSink)

    on_exit(fn ->
      Application.delete_env(:billing_commerce, :billing_source_typed_sink)
      Application.delete_env(:billing_stripe, :test_payment_intents)
      Application.delete_env(:billing_stripe, :test_subscriptions)
    end)

    :ok
  end

  test "verifies, journals, and maps invoice paid to one subscription cycle grant idempotently" do
    payload =
      Jason.encode!(%{
        "id" => "evt_invoice_paid_1",
        "type" => "invoice.paid",
        "data" => %{
          "object" => %{
            "id" => "in_1",
            "subscription" => "sub_1",
            "period_start" => 1_780_272_000,
            "period_end" => 1_782_691_200,
            "metadata" => metadata("example-ba-wsp_stripe")
          }
        }
      })

    header = signature(payload, "whsec_test", 1_780_272_100)

    assert {:ok, %{idempotent: false}} =
             Webhooks.handle_webhook(payload, header, now: 1_780_272_100)

    assert {:ok, %{idempotent: true}} =
             Webhooks.handle_webhook(payload, header, now: 1_780_272_100)

    assert grant_count("example-ba-wsp_stripe") == 1
    assert event_status("evt_invoice_paid_1") == "processed"

    assert Enum.any?(
             Agent.get(__MODULE__.ProjectionLog, & &1),
             &(&1["event_kind"] == "stripe_event_processed" and &1["provider"] == "stripe")
           )
  end

  test "invoice paid reads subscription metadata from real Stripe invoice parent shape" do
    payload =
      Jason.encode!(%{
        "id" => "evt_invoice_parent_metadata",
        "type" => "invoice.paid",
        "data" => %{
          "object" => %{
            "id" => "in_parent_metadata",
            "period_start" => 1_780_272_000,
            "period_end" => 1_782_691_200,
            "metadata" => metadata("example-ba-wsp_invoice_metadata"),
            "parent" => %{
              "subscription_details" => %{
                "subscription" => "sub_parent_metadata",
                "metadata" => metadata("example-ba-wsp_parent_metadata")
              }
            }
          }
        }
      })

    assert {:ok, %{idempotent: false}} =
             Webhooks.handle_webhook(payload, signature(payload, "whsec_test", 1_780_272_100),
               now: 1_780_272_100
             )

    assert grant_count("example-ba-wsp_parent_metadata") == 1
    assert grant_count("example-ba-wsp_invoice_metadata") == 0
    assert event_status("evt_invoice_parent_metadata") == "processed"

    assert Enum.any?(
             Agent.get(__MODULE__.ProjectionLog, & &1),
             &(&1["billing_account_id"] == "example-ba-wsp_parent_metadata" and
                 &1["event_kind"] == "stripe_event_processed")
           )
  end

  test "invoice paid uses the line period when Stripe's top-level creation period is empty" do
    payload =
      invoice_payload("evt_invoice_line_period", %{
        "id" => "in_line_period",
        "period_start" => 1_788_220_000,
        "period_end" => 1_788_220_000,
        "lines" => %{
          "data" => [
            %{
              "period" => %{
                "start" => 1_788_220_000,
                "end" => 1_790_899_200
              }
            }
          ]
        },
        "parent" => %{
          "subscription_details" => %{
            "subscription" => "sub_line_period",
            "metadata" => metadata("example-ba-wsp_line_period")
          }
        }
      })

    assert {:ok, %{idempotent: false}} =
             Webhooks.handle_webhook(payload, signature(payload, "whsec_test", 1_788_220_100),
               now: 1_788_220_100
             )

    assert grant_count("example-ba-wsp_line_period") == 1
    assert event_status("evt_invoice_line_period") == "processed"
  end

  test "failed Stripe processing emits a source lifecycle projection" do
    payload =
      Jason.encode!(%{
        "id" => "evt_invoice_failed_projection",
        "type" => "invoice.paid",
        "data" => %{
          "object" => %{
            "id" => "in_failed_projection",
            "subscription" => "sub_failed_projection",
            "period_start" => 1_780_272_000,
            "period_end" => 1_782_691_200,
            "metadata" => metadata("example-ba-wsp_failed_projection", package_code: "missing_pkg")
          }
        }
      })

    header = signature(payload, "whsec_test", 1_780_272_100)

    assert {:error, _reason} = Webhooks.handle_webhook(payload, header, now: 1_780_272_100)
    assert event_status("evt_invoice_failed_projection") == "failed"

    assert Enum.any?(
             Agent.get(__MODULE__.ProjectionLog, & &1),
             &(&1["event_kind"] == "stripe_event_failed" and &1["status"] == "failed")
           )

    seed_package("missing_pkg", "comma")

    assert {:ok, %{idempotent: false}} =
             Webhooks.handle_webhook(payload, header, now: 1_780_272_100)

    assert grant_count("example-ba-wsp_failed_projection") == 1
    assert event_status("evt_invoice_failed_projection") == "processed"
  end

  defmodule ProjectionSink do
    def insert(rows) do
      Agent.update(BillingStripe.WebhooksTest.ProjectionLog, &(rows ++ &1))
      {:ok, length(rows)}
    end
  end

  test "successive invoices for the same Stripe subscription append cycle grants idempotently" do
    first =
      invoice_payload("evt_invoice_paid_month_1", %{
        "id" => "in_month_1",
        "subscription" => "sub_monthly_repeat",
        "period_start" => 1_780_272_000,
        "period_end" => 1_782_691_200,
        "metadata" => metadata("example-ba-wsp_repeat_invoice")
      })

    second =
      invoice_payload("evt_invoice_paid_month_2", %{
        "id" => "in_month_2",
        "subscription" => "sub_monthly_repeat",
        "period_start" => 1_782_864_000,
        "period_end" => 1_785_542_400,
        "metadata" => metadata("example-ba-wsp_repeat_invoice")
      })

    assert {:ok, %{idempotent: false}} =
             Webhooks.handle_webhook(first, signature(first, "whsec_test", 1_780_272_100),
               now: 1_780_272_100
             )

    assert {:ok, %{idempotent: false}} =
             Webhooks.handle_webhook(second, signature(second, "whsec_test", 1_782_864_100),
               now: 1_782_864_100
             )

    assert {:ok, %{idempotent: true}} =
             Webhooks.handle_webhook(second, signature(second, "whsec_test", 1_782_864_100),
               now: 1_782_864_100
             )

    assert grant_count("example-ba-wsp_repeat_invoice") == 2
    assert cycle_count("example-ba-wsp_repeat_invoice") == 2
  end

  test "invoice paid issues only its own cycle when older unrelated cycles are due first" do
    assert {:ok, _} =
             Subscriptions.create_subscription(%{
               billing_account_id: "example-ba-wsp_unrelated_due",
               surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: "wsp_unrelated_due",
               package_code: "comma_monthly",
               package_version: "2026-06",
               source_type: "stripe_subscription",
               source_id: "sub_unrelated_due",
               source_event_id: "evt_unrelated_due",
               idempotency_key: "stripe:subscription:unrelated_due",
               periods: older_periods(11)
             })

    payload =
      invoice_payload("evt_invoice_scoped_cycle", %{
        "id" => "in_scoped_cycle",
        "subscription" => "sub_scoped_cycle",
        "period_start" => 1_780_272_000,
        "period_end" => 1_782_691_200,
        "metadata" => metadata("example-ba-wsp_scoped_invoice")
      })

    assert {:ok, %{idempotent: false}} =
             Webhooks.handle_webhook(payload, signature(payload, "whsec_test", 1_780_272_100),
               now: 1_780_272_100
             )

    assert grant_count("example-ba-wsp_scoped_invoice") == 1
    assert grant_count("example-ba-wsp_unrelated_due") == 0
    assert cycle_count("example-ba-wsp_unrelated_due") == 11
  end

  test "checkout payment maps to one-time purchase grant with explicit period" do
    payload =
      Jason.encode!(%{
        "id" => "evt_checkout_1",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "id" => "cs_1",
            "mode" => "payment",
            "payment_status" => "paid",
            "payment_intent" => "pi_1",
            "period_start" => 1_780_272_000,
            "period_end" => 1_782_691_200,
            "metadata" => metadata("example-ba-wsp_topup_stripe")
          }
        }
      })

    assert {:ok, %{idempotent: false}} =
             Webhooks.handle_webhook(payload, signature(payload, "whsec_test", 1_780_272_100),
               now: 1_780_272_100
             )

    assert grant_count("example-ba-wsp_topup_stripe") == 1
  end

  test "checkout completion waits for a paid state and async success grants once" do
    session = %{
      "id" => "cs_async_1",
      "mode" => "payment",
      "payment_status" => "unpaid",
      "payment_intent" => "pi_async_1",
      "period_start" => 1_780_272_000,
      "period_end" => 1_782_691_200,
      "metadata" => metadata("example-ba-wsp_async_topup", package_code: "comma_topup")
    }

    pending =
      Jason.encode!(%{
        "id" => "evt_checkout_async_pending",
        "type" => "checkout.session.completed",
        "data" => %{"object" => session}
      })

    assert {:ok, %{result: %{ignored: true, reason: :payment_not_complete}}} =
             Webhooks.handle_webhook(
               pending,
               signature(pending, "whsec_test", 1_780_272_100),
               now: 1_780_272_100
             )

    assert grant_count("example-ba-wsp_async_topup") == 0

    paid =
      Jason.encode!(%{
        "id" => "evt_checkout_async_paid",
        "type" => "checkout.session.async_payment_succeeded",
        "data" => %{"object" => session}
      })

    assert {:ok, %{idempotent: false}} =
             Webhooks.handle_webhook(
               paid,
               signature(paid, "whsec_test", 1_780_272_101),
               now: 1_780_272_101
             )

    assert grant_count("example-ba-wsp_async_topup") == 1
  end

  test "partial and full refunds reduce only the purchased grant idempotently" do
    account_id = "example-ba-wsp_refunded_topup"

    checkout =
      Jason.encode!(%{
        "id" => "evt_checkout_refund_source",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "id" => "cs_refund_source",
            "mode" => "payment",
            "payment_status" => "paid",
            "payment_intent" => "pi_refund_source",
            "period_start" => 1_780_272_000,
            "period_end" => 1_782_691_200,
            "metadata" => metadata(account_id, package_code: "comma_topup")
          }
        }
      })

    assert {:ok, _} =
             Webhooks.handle_webhook(
               checkout,
               signature(checkout, "whsec_test", 1_780_272_100),
               now: 1_780_272_100
             )

    partial =
      Jason.encode!(%{
        "id" => "evt_refund_partial",
        "type" => "charge.refunded",
        "data" => %{
          "object" => %{
            "id" => "ch_refund_source",
            "payment_intent" => "pi_refund_source",
            "amount" => 2_000,
            "amount_refunded" => 1_000
          }
        }
      })

    assert {:ok, %{result: %{purchase: %{status: "partially_refunded"}}}} =
             Webhooks.handle_webhook(
               partial,
               signature(partial, "whsec_test", 1_780_272_101),
               now: 1_780_272_101
             )

    assert grant_balance(account_id) == {250, "active"}

    full =
      Jason.encode!(%{
        "id" => "evt_refund_full",
        "type" => "charge.refunded",
        "data" => %{
          "object" => %{
            "id" => "ch_refund_source",
            "payment_intent" => "pi_refund_source",
            "amount" => 2_000,
            "amount_refunded" => 2_000
          }
        }
      })

    assert {:ok, %{result: %{purchase: %{status: "refunded"}}}} =
             Webhooks.handle_webhook(
               full,
               signature(full, "whsec_test", 1_780_272_102),
               now: 1_780_272_102
             )

    assert grant_balance(account_id) == {0, "revoked"}

    assert {:ok, %{idempotent: true}} =
             Webhooks.handle_webhook(
               full,
               signature(full, "whsec_test", 1_780_272_102),
               now: 1_780_272_102
             )
  end

  test "partial disputes use the original PaymentIntent total and replay idempotently" do
    account_id = "example-ba-wsp_partial_dispute"
    payment_intent_id = "pi_partial_dispute"
    Application.put_env(:billing_stripe, :test_payment_intents, %{payment_intent_id => 2_000})

    assert {:ok, _} =
             one_time_checkout(account_id, payment_intent_id, "evt_checkout_partial_dispute")

    dispute =
      dispute_payload(
        "evt_dispute_partial",
        "dp_partial",
        payment_intent_id,
        500
      )

    assert {:ok, %{result: %{purchase: %{status: "partially_refunded"}}}} =
             Webhooks.handle_webhook(
               dispute,
               signature(dispute, "whsec_test", 1_780_272_101),
               now: 1_780_272_101
             )

    assert grant_balance(account_id) == {375, "active"}

    assert [
             {:retrieve_payment_intent, ^payment_intent_id, %{}, retrieve_opts}
           ] = stripe_calls(:retrieve_payment_intent)

    assert retrieve_opts[:api_key] == "sk_test_secret"

    assert {:ok, %{idempotent: true}} =
             Webhooks.handle_webhook(
               dispute,
               signature(dispute, "whsec_test", 1_780_272_101),
               now: 1_780_272_101
             )

    assert grant_balance(account_id) == {375, "active"}
    assert length(stripe_calls(:retrieve_payment_intent)) == 1
  end

  test "a failed PaymentIntent lookup leaves a dispute retryable without reducing credits" do
    account_id = "example-ba-wsp_retryable_dispute"
    payment_intent_id = "pi_retryable_dispute"

    assert {:ok, _} =
             one_time_checkout(account_id, payment_intent_id, "evt_checkout_retryable_dispute")

    Application.put_env(:billing_stripe, :test_payment_intents, %{
      payment_intent_id => {:error, :stripe_temporarily_unavailable}
    })

    dispute =
      dispute_payload(
        "evt_dispute_retryable",
        "dp_retryable",
        payment_intent_id,
        500
      )

    assert {:error, :stripe_temporarily_unavailable} =
             Webhooks.handle_webhook(
               dispute,
               signature(dispute, "whsec_test", 1_780_272_101),
               now: 1_780_272_101
             )

    assert event_status("evt_dispute_retryable") == "failed"
    assert grant_balance(account_id) == {500, "active"}

    Application.put_env(:billing_stripe, :test_payment_intents, %{payment_intent_id => 2_000})

    assert {:ok, %{result: %{purchase: %{status: "partially_refunded"}}}} =
             Webhooks.handle_webhook(
               dispute,
               signature(dispute, "whsec_test", 1_780_272_101),
               now: 1_780_272_101
             )

    assert event_status("evt_dispute_retryable") == "processed"
    assert grant_balance(account_id) == {375, "active"}
  end

  test "webhook customer mismatch fails before granting credits and can retry" do
    assert {:ok, _customer} =
             BillingCommerce.bind_provider_customer(%{
               billing_account_id: "example-ba-wsp_customer_mismatch",
               surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: "wsp_customer_mismatch",
               provider: "stripe",
               provider_customer_id: "cus_expected",
               source_type: "test"
             })

    payload =
      Jason.encode!(%{
        "id" => "evt_customer_mismatch",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "id" => "cs_customer_mismatch",
            "mode" => "payment",
            "payment_status" => "paid",
            "payment_intent" => "pi_customer_mismatch",
            "customer" => "cus_attacker",
            "period_start" => 1_780_272_000,
            "period_end" => 1_782_691_200,
            "metadata" => metadata("example-ba-wsp_customer_mismatch", package_code: "comma_topup")
          }
        }
      })

    assert {:error, :stripe_customer_mismatch} =
             Webhooks.handle_webhook(payload, signature(payload, "whsec_test", 1_780_272_100),
               now: 1_780_272_100
             )

    assert event_status("evt_customer_mismatch") == "failed"
    assert grant_count("example-ba-wsp_customer_mismatch") == 0

    retry_payload =
      Jason.encode!(%{
        "id" => "evt_customer_mismatch",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "id" => "cs_customer_mismatch",
            "mode" => "payment",
            "payment_status" => "paid",
            "payment_intent" => "pi_customer_mismatch",
            "customer" => "cus_expected",
            "period_start" => 1_780_272_000,
            "period_end" => 1_782_691_200,
            "metadata" => metadata("example-ba-wsp_customer_mismatch", package_code: "comma_topup")
          }
        }
      })

    assert {:ok, %{idempotent: false}} =
             Webhooks.handle_webhook(
               retry_payload,
               signature(retry_payload, "whsec_test", 1_780_272_100),
               now: 1_780_272_100
             )

    assert grant_count("example-ba-wsp_customer_mismatch") == 1
    assert event_status("evt_customer_mismatch") == "processed"
  end

  test "checkout payment metadata can drive the later top-up webhook grant" do
    assert {:ok, checkout} =
             Checkout.create_session(%{
               billing_account_id: "example-ba-wsp_checkout_command",
               surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: "wsp_checkout_command",
               package_code: "comma_topup",
               package_version: "2026-06",
               provider_price_id: "price_comma_topup",
               mode: "payment",
               success_url: "https://comma.test/success",
               cancel_url: "https://comma.test/cancel",
               idempotency_key: "checkout-command-1",
               now: ~U[2026-06-23 12:00:00Z]
             })

    metadata = checkout_metadata(checkout)

    {:checkout, params, opts} = only_stripe_call(:checkout)
    assert params.mode == :payment
    assert params.line_items == [%{price: "price_comma_topup", quantity: 1}]
    assert params.payment_intent_data == %{metadata: metadata}
    assert opts[:api_key] == "sk_test_secret"
    assert opts[:idempotency_key] == "checkout-command-1"
    assert metadata["period_start"] == "1780272000"
    assert metadata["period_end"] == "1782864000"

    payload =
      Jason.encode!(%{
        "id" => "evt_checkout_from_command",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "id" => checkout["id"],
            "mode" => "payment",
            "payment_status" => "paid",
            "payment_intent" => "pi_checkout_from_command",
            "metadata" => metadata
          }
        }
      })

    assert {:ok, %{idempotent: false}} =
             Webhooks.handle_webhook(
               payload,
               signature(payload, "whsec_test", 1_780_272_100),
               now: 1_780_272_100
             )

    assert grant_count("example-ba-wsp_checkout_command") == 1
  end

  test "subscription checkout carries billing metadata onto the Stripe subscription" do
    assert {:ok, checkout} =
             Checkout.create_session(%{
               billing_account_id: "example-ba-wsp_subscription_checkout",
               surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: "wsp_subscription_checkout",
               package_code: "comma_monthly",
               package_version: "2026-06",
               provider_price_id: "price_comma_monthly",
               mode: "subscription",
               success_url: "https://comma.test/success",
               cancel_url: "https://comma.test/cancel",
               idempotency_key: "checkout-subscription-1"
             })

    metadata = checkout_metadata(checkout)
    {:checkout, params, _opts} = only_stripe_call(:checkout)

    assert params.mode == :subscription
    assert params.subscription_data == %{metadata: metadata}
    refute Map.has_key?(params, :payment_intent_data)
  end

  test "paid yearly invoices preserve Stripe anchors and cover the exact interval" do
    seed_package("comma_yearly", "comma", billing_period: "year")

    cases = [
      {"mid_month", ~U[2026-09-15 14:30:45Z], ~U[2027-09-15 14:30:45Z]},
      {"month_end", ~U[2026-01-31 23:59:59Z], ~U[2027-01-31 23:59:59Z]},
      {"leap_day", ~U[2028-02-29 07:08:09Z], ~U[2029-02-28 07:08:09Z]}
    ]

    for {name, period_start, period_end} <- cases do
      account_id = "example-ba-wsp_year_#{name}"

      payload =
        invoice_payload("evt_invoice_year_#{name}", %{
          "id" => "in_year_#{name}",
          "subscription" => "sub_year_#{name}",
          "period_start" => DateTime.to_unix(period_start),
          "period_end" => DateTime.to_unix(period_end),
          "lines" => %{
            "data" => [%{"price" => %{"recurring" => %{"interval" => "year"}}}]
          },
          "metadata" => metadata(account_id, package_code: "comma_yearly")
        })

      assert {:ok, %{idempotent: false}} =
               Webhooks.handle_webhook(
                 payload,
                 signature(payload, "whsec_test", DateTime.to_unix(period_start) + 100),
                 now: DateTime.to_unix(period_start) + 100
               )

      cycles = subscription_cycles(account_id)
      assert length(cycles) == 12
      assert grant_count(account_id) == 1
      assert DateTime.compare(hd(cycles).valid_from, period_start) == :eq
      assert DateTime.compare(List.last(cycles).expires_at, period_end) == :eq

      assert Enum.map(cycles, &DateTime.to_unix(&1.valid_from, :microsecond)) ==
               Enum.map(
                 0..11,
                 &(period_start
                   |> DateTime.shift(month: &1)
                   |> DateTime.to_unix(:microsecond))
               )

      assert Enum.all?(cycles, &(DateTime.compare(&1.valid_from, &1.expires_at) == :lt))

      assert Enum.all?(Enum.chunk_every(cycles, 2, 1, :discard), fn [left, right] ->
               left.expires_at == right.valid_from
             end)
    end
  end

  test "subscription cancellation updates local state without revoking the paid period" do
    invoice =
      invoice_payload("evt_subscription_active", %{
        "id" => "in_subscription_active",
        "subscription" => "sub_lifecycle",
        "period_start" => 1_780_272_000,
        "period_end" => 1_782_691_200,
        "metadata" => metadata("example-ba-wsp_subscription_lifecycle")
      })

    assert {:ok, _} =
             Webhooks.handle_webhook(
               invoice,
               signature(invoice, "whsec_test", 1_780_272_100),
               now: 1_780_272_100
             )

    Application.put_env(:billing_stripe, :test_subscriptions, %{
      "sub_lifecycle" => %{"id" => "sub_lifecycle", "status" => "canceled"}
    })

    deleted =
      Jason.encode!(%{
        "id" => "evt_subscription_deleted",
        "type" => "customer.subscription.deleted",
        "data" => %{
          "object" => %{
            "id" => "sub_lifecycle",
            "status" => "canceled",
            "metadata" => metadata("example-ba-wsp_subscription_lifecycle")
          }
        }
      })

    assert {:ok, _} =
             Webhooks.handle_webhook(
               deleted,
               signature(deleted, "whsec_test", 1_780_272_101),
               now: 1_780_272_101
             )

    assert subscription_status("sub_lifecycle") == "canceled"
    assert grant_count("example-ba-wsp_subscription_lifecycle") == 1
  end

  test "subscription update maps the provider price back to the new local package" do
    seed_package("comma_test_pro", "comma")

    assert {:ok, _mapping} =
             BillingCommerce.put_provider_price(%{
               package_code: "comma_test_pro",
               package_version: "2026-06",
               provider: "stripe",
               provider_lookup_key: "example_test_pro_v1",
               provider_price_id: "price_pro",
               currency: "usd",
               amount_minor: 6_000
             })

    invoice =
      invoice_payload("evt_subscription_before_change", %{
        "id" => "in_subscription_before_change",
        "subscription" => "sub_plan_change",
        "period_start" => 1_780_272_000,
        "period_end" => 1_782_691_200,
        "metadata" => metadata("example-ba-wsp_plan_change")
      })

    assert {:ok, _} =
             Webhooks.handle_webhook(
               invoice,
               signature(invoice, "whsec_test", 1_780_272_100),
               now: 1_780_272_100
             )

    Application.put_env(:billing_stripe, :test_subscriptions, %{
      "sub_plan_change" => %{
        "id" => "sub_plan_change",
        "status" => "active",
        "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
      }
    })

    updated =
      Jason.encode!(%{
        "id" => "evt_subscription_plan_changed",
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "id" => "sub_plan_change",
            "status" => "active",
            "metadata" => metadata("example-ba-wsp_plan_change"),
            "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
          }
        }
      })

    assert {:ok, _} =
             Webhooks.handle_webhook(
               updated,
               signature(updated, "whsec_test", 1_780_272_101),
               now: 1_780_272_101
             )

    assert subscription_package("sub_plan_change") == {"comma_test_pro", "2026-06"}
    assert grant_count("example-ba-wsp_plan_change") == 1
  end

  test "rejects invalid signature" do
    assert {:error, :invalid_signature} =
             Webhooks.handle_webhook(~s({"id":"evt_bad","type":"noop"}), "t=1,v1=bad",
               now: 1,
               secret: "whsec_test"
             )
  end

  test "real Stripe webhook verifier accepts matching HMAC and rejects mismatch" do
    previous_api = Application.get_env(:billing_stripe, :stripe_api)
    Application.put_env(:billing_stripe, :stripe_api, BillingStripe.StripityAPI)

    on_exit(fn ->
      case previous_api do
        nil -> Application.delete_env(:billing_stripe, :stripe_api)
        api -> Application.put_env(:billing_stripe, :stripe_api, api)
      end
    end)

    payload =
      Jason.encode!(%{
        "id" => "evt_real_signature",
        "type" => "checkout.session.completed",
        "data" => %{"object" => %{"id" => "cs_real_signature"}}
      })

    timestamp = System.system_time(:second)
    header = signature(payload, "whsec_real_signature", timestamp)

    assert {:ok, %{"id" => "evt_real_signature"}} =
             Webhooks.verify(payload, header, "whsec_real_signature", tolerance: 300)

    assert {:error, :invalid_signature} =
             Webhooks.verify(payload, "t=#{timestamp},v1=bad", "whsec_real_signature",
               tolerance: 300
             )
  end

  test "payment redelivery recovers a request killed after journaling" do
    account_id = "example-ba-wsp_audit_crash"
    event_id = "evt_audit_crash"

    payload =
      invoice_payload(event_id, %{
        "id" => "in_audit_crash",
        "subscription" => "sub_audit_crash",
        "period_start" => 1_780_272_000,
        "period_end" => 1_782_691_200,
        "metadata" => metadata(account_id)
      })

    test_pid = self()
    handler = "comma-audit-journal-crash"

    :ok =
      :telemetry.attach(
        handler,
        [:billing_core, :repo, :query],
        fn _, _, meta, _ ->
          if String.contains?(meta.query, "INSERT INTO billing_stripe_events") and
               List.first(meta.params) == event_id do
            send(test_pid, {:journal_written, self()})

            receive do
              :continue -> :ok
            after
              5_000 -> :ok
            end
          end
        end,
        nil
      )

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :go ->
            Webhooks.handle_webhook(payload, signature(payload, "whsec_test", 1_780_272_100),
              now: 1_780_272_100
            )
        end
      end)

    :ok = Ecto.Adapters.SQL.Sandbox.allow(BillingCore.Repo, self(), worker)
    send(worker, :go)
    assert_receive {:journal_written, ^worker}, 3_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 3_000
    :telemetry.detach(handler)
    assert event_status(event_id) == "processing"

    assert {:ok, %{idempotent: false}} =
             Webhooks.handle_webhook(payload, signature(payload, "whsec_test", 1_780_272_100),
               now: 1_780_272_100
             )

    assert grant_count(account_id) == 1
    assert event_status(event_id) == "processed"
  end

  test "out-of-order events and a late invoice preserve current provider cancellation" do
    account_id = "example-ba-wsp_audit_order"

    payload =
      invoice_payload("evt_audit_paid", %{
        "id" => "in_audit_order",
        "subscription" => "sub_audit_order",
        "period_start" => 1_780_272_000,
        "period_end" => 1_782_691_200,
        "metadata" => metadata(account_id)
      })

    assert {:ok, _} = Webhooks.handle_webhook(payload, "audit", [])

    Application.put_env(:billing_stripe, :test_subscriptions, %{
      "sub_audit_order" => %{"id" => "sub_audit_order", "status" => "canceled"}
    })

    for {id, type, created, status} <- [
          {"evt_audit_cancel", "customer.subscription.deleted", 200, "canceled"},
          {"evt_audit_old_active", "customer.subscription.updated", 100, "active"}
        ] do
      event =
        Jason.encode!(%{
          "id" => id,
          "type" => type,
          "created" => created,
          "data" => %{"object" => %{"id" => "sub_audit_order", "status" => status}}
        })

      assert {:ok, _} = Webhooks.handle_webhook(event, "audit", [])

      result =
        Ecto.Adapters.SQL.query!(
          BillingCore.Repo,
          "SELECT status FROM billing_subscriptions WHERE source_id = $1",
          ["sub_audit_order"]
        )

      assert result.rows == [["canceled"]]
    end

    late_invoice =
      payload |> Jason.decode!() |> Map.put("id", "evt_audit_late_paid") |> Jason.encode!()

    assert {:ok, _} = Webhooks.handle_webhook(late_invoice, "audit", [])
    assert subscription_status("sub_audit_order") == "canceled"
    assert grant_count(account_id) == 1
  end

  test "Clover annual invoices use catalog cadence and issue twelve monthly grants" do
    code = "comma_audit_annual"
    {:ok, _} = PackageCatalog.create_package(%{code: code, surface: "comma", name: code})

    {:ok, _} =
      PackageCatalog.create_package_version(%{
        package_code: code,
        version: "2026-06",
        surface: "comma",
        kind: "subscription",
        billing_period: "year",
        grant_credits: 500,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 20_000,
        usage_policy: %{},
        effective_at: ~U[2026-01-01 00:00:00Z],
        status: "active"
      })

    {:ok, _} =
      BillingCommerce.put_provider_price(%{
        package_code: code,
        package_version: "2026-06",
        provider: "stripe",
        provider_lookup_key: "example_audit_annual_v1",
        provider_price_id: "price_audit_annual",
        currency: "usd",
        amount_minor: 20_000
      })

    account_id = "example-ba-wsp_audit_annual"
    start_at = ~U[2026-09-07 00:00:00Z]
    end_at = ~U[2027-09-07 00:00:00Z]

    payload =
      invoice_payload("evt_audit_annual", %{
        "id" => "in_audit_annual",
        "parent" => %{
          "subscription_details" => %{
            "subscription" => "sub_audit_annual",
            "metadata" => metadata(account_id, package_code: code)
          }
        },
        "lines" => %{
          "data" => [
            %{
              "pricing" => %{
                "type" => "price_details",
                "price_details" => %{"price" => "price_audit_annual"}
              },
              "period" => %{
                "start" => DateTime.to_unix(start_at),
                "end" => DateTime.to_unix(end_at)
              }
            }
          ]
        }
      })

    assert {:ok, _} = Webhooks.handle_webhook(payload, "audit", [])
    cycles = subscription_cycles(account_id)
    assert length(cycles) == 12
    assert DateTime.compare(hd(cycles).valid_from, start_at) == :eq
    assert DateTime.compare(List.last(cycles).expires_at, end_at) == :eq
    assert DateTime.compare(hd(cycles).expires_at, DateTime.shift(start_at, month: 1)) == :eq
    assert grant_count(account_id) == 1
    assert {:ok, %{idempotent: true}} = Webhooks.handle_webhook(payload, "audit", [])
    assert {:ok, _} = Subscriptions.run_due_cycles(%{at: end_at})
    assert grant_count(account_id) == 12
  end

  test "failed current-state lookup rolls back credits and retries the same payment" do
    account_id = "example-ba-wsp_provider_read_retry"

    payload =
      invoice_payload("evt_provider_read_retry", %{
        "id" => "in_provider_read_retry",
        "subscription" => "sub_provider_read_retry",
        "period_start" => 1_780_272_000,
        "period_end" => 1_782_691_200,
        "metadata" => metadata(account_id)
      })

    Application.put_env(:billing_stripe, :test_subscriptions, %{
      "sub_provider_read_retry" => {:error, :timeout}
    })

    assert {:error, :timeout} = Webhooks.handle_webhook(payload, "audit", [])
    assert grant_count(account_id) == 0
    assert event_status("evt_provider_read_retry") == "failed"
    Application.delete_env(:billing_stripe, :test_subscriptions)
    assert {:ok, %{idempotent: false}} = Webhooks.handle_webhook(payload, "audit", [])
    assert grant_count(account_id) == 1
    assert event_status("evt_provider_read_retry") == "processed"
  end

  test "cancellation before the paid invoice is reconciled when the subscription is recorded" do
    subscription = %{"id" => "sub_early_cancel", "status" => "canceled"}

    Application.put_env(:billing_stripe, :test_subscriptions, %{
      "sub_early_cancel" => subscription
    })

    canceled =
      Jason.encode!(%{
        "id" => "evt_early_cancel",
        "type" => "customer.subscription.deleted",
        "data" => %{"object" => subscription}
      })

    assert {:ok, _} = Webhooks.handle_webhook(canceled, "audit", [])
    account_id = "example-ba-wsp_early_cancel"

    paid =
      invoice_payload("evt_paid_after_cancel", %{
        "id" => "in_early_cancel",
        "subscription" => "sub_early_cancel",
        "period_start" => 1_780_272_000,
        "period_end" => 1_782_691_200,
        "metadata" => metadata(account_id)
      })

    assert {:ok, _} = Webhooks.handle_webhook(paid, "audit", [])
    assert subscription_status("sub_early_cancel") == "canceled"
    assert grant_count(account_id) == 1
  end

  defp seed_package(code, surface, opts \\ []) do
    {:ok, _} = PackageCatalog.create_package(%{code: code, surface: surface, name: code})

    {:ok, _} =
      PackageCatalog.create_package_version(%{
        package_code: code,
        version: "2026-06",
        surface: surface,
        kind: Keyword.get(opts, :kind, "subscription"),
        billing_period: Keyword.get(opts, :billing_period, "month"),
        grant_credits: 500,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 2_000,
        usage_policy: %{},
        effective_at: ~U[2026-01-01 00:00:00Z],
        status: "active"
      })
  end

  defp invoice_payload(event_id, invoice) do
    Jason.encode!(%{
      "id" => event_id,
      "type" => "invoice.paid",
      "data" => %{"object" => invoice}
    })
  end

  defp one_time_checkout(account_id, payment_intent_id, event_id) do
    payload =
      Jason.encode!(%{
        "id" => event_id,
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "id" => "cs_#{event_id}",
            "mode" => "payment",
            "payment_status" => "paid",
            "payment_intent" => payment_intent_id,
            "period_start" => 1_780_272_000,
            "period_end" => 1_782_691_200,
            "metadata" => metadata(account_id, package_code: "comma_topup")
          }
        }
      })

    Webhooks.handle_webhook(
      payload,
      signature(payload, "whsec_test", 1_780_272_100),
      now: 1_780_272_100
    )
  end

  defp dispute_payload(event_id, dispute_id, payment_intent_id, amount) do
    Jason.encode!(%{
      "id" => event_id,
      "type" => "charge.dispute.created",
      "data" => %{
        "object" => %{
          "id" => dispute_id,
          "payment_intent" => payment_intent_id,
          "amount" => amount
        }
      }
    })
  end

  defp older_periods(count) do
    start_date = ~D[2026-01-01]

    Enum.map(0..(count - 1), fn offset ->
      valid_from = DateTime.new!(Date.add(start_date, offset), ~T[00:00:00], "Etc/UTC")
      expires_at = DateTime.new!(Date.add(start_date, offset + 1), ~T[00:00:00], "Etc/UTC")

      %{
        cycle_key: "older-#{offset}",
        valid_from: valid_from,
        expires_at: expires_at,
        source_event_id: "older-#{offset}"
      }
    end)
  end

  defp metadata(account_id, overrides \\ []) do
    Map.merge(
      %{
        "billing_account_id" => account_id,
        "surface" => "comma",
        "product_owner_type" => "workspace",
        "product_owner_id" => String.replace_prefix(account_id, "example-ba-", ""),
        "package_code" => "comma_monthly",
        "package_version" => "2026-06"
      },
      Map.new(overrides, fn {key, value} -> {to_string(key), value} end)
    )
  end

  defp signature(payload, secret, timestamp) do
    sig =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{sig}"
  end

  defp checkout_metadata(checkout) do
    {:checkout, params, _opts} = only_stripe_call(:checkout)
    assert checkout["id"] =~ "cs_test_"
    params.metadata
  end

  defp only_stripe_call(kind) do
    calls = stripe_calls(kind)

    assert [call] = calls
    call
  end

  defp stripe_calls(kind) do
    BillingStripe.TestAPI.Recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(elem(&1, 0) == kind))
  end

  defp grant_count(account_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT count(*) FROM credit_grants WHERE billing_account_id = $1",
        [account_id]
      )

    count
  end

  defp grant_balance(account_id) do
    %{rows: [[remaining, status]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT remaining_credits, status FROM credit_grants WHERE billing_account_id = $1",
        [account_id]
      )

    {remaining, status}
  end

  defp subscription_status(source_id) do
    %{rows: [[status]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT status FROM billing_subscriptions WHERE source_id = $1",
        [source_id]
      )

    status
  end

  defp subscription_package(source_id) do
    %{rows: [[package_code, package_version]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT package_code, package_version FROM billing_subscriptions WHERE source_id = $1",
        [source_id]
      )

    {package_code, package_version}
  end

  defp cycle_count(account_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT count(*) FROM billing_subscription_cycles WHERE billing_account_id = $1",
        [account_id]
      )

    count
  end

  defp subscription_cycles(account_id) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT period_start, period_end
        FROM billing_subscription_cycles
        WHERE billing_account_id = $1
        ORDER BY period_start
        """,
        [account_id]
      )

    Enum.map(rows, fn [valid_from, expires_at] ->
      %{valid_from: valid_from, expires_at: expires_at}
    end)
  end

  defp event_status(event_id) do
    %{rows: [[status]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT status FROM billing_stripe_events WHERE id = $1",
        [event_id]
      )

    status
  end
end
