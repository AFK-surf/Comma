defmodule BillingCommerce.StorePaymentsTest do
  use SystemsClock.Case, async: false

  alias BillingCommerce.{PackageCatalog, PaidCycles, PaymentRights, Subscriptions}

  @account "example-ba-wsp_store"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    seed_package("store_test_plus", 500)
    seed_package("store_test_pro", 1500)
    :ok
  end

  test "an App Store upgrade starts a new period and subtracts the old tier's unused share" do
    # Old tier: 500 credits for June 1 to July 1 (30 days), paid and issued.
    sub =
      subscribe("store_test_plus", [
        period("2026-06-01", ~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z])
      ])

    pay(sub, "store_test_plus", "apple:t1", ~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z])

    # Upgrade on June 11: the App Store charges a full new period from that time.
    sub =
      subscribe("store_test_pro", [
        period("2026-06-11", ~U[2026-06-11 00:00:00Z], ~U[2026-07-11 00:00:00Z])
      ])

    pay(sub, "store_test_pro", "apple:t2", ~U[2026-06-11 00:00:00Z], ~U[2026-07-11 00:00:00Z],
      replaces: %{at: ~U[2026-06-11 00:00:00Z], payment_id: "apple:t1"}
    )

    # 1500 - 500 * 20 / 30 = 1167. The old grant keeps its credits and expiry.
    assert grants() == [
             {500, ~U[2026-07-01 00:00:00Z], "apple:t1"},
             {1167, ~U[2026-07-11 00:00:00Z], "apple:t2"}
           ]

    assert [{"2026-06-01", ~U[2026-06-11 00:00:00Z], "issued"}, {"2026-06-11", _, "issued"}] =
             cycles(sub.id)

    # A redelivered transaction issues nothing again.
    pay(sub, "store_test_pro", "apple:t2", ~U[2026-06-11 00:00:00Z], ~U[2026-07-11 00:00:00Z],
      replaces: %{at: ~U[2026-06-11 00:00:00Z], payment_id: "apple:t1"}
    )

    assert length(grants()) == 2
  end

  test "an annual upgrade removes the old period's unissued months" do
    months =
      for m <- 0..11 do
        starts = DateTime.shift(~U[2026-06-01 00:00:00Z], month: m)
        period("old-#{m}", starts, DateTime.shift(starts, month: 1))
      end

    sub = subscribe("store_test_plus", months)
    pay(sub, "store_test_plus", "apple:year1", ~U[2026-06-01 00:00:00Z], ~U[2027-06-01 00:00:00Z])

    sub =
      subscribe("store_test_pro", [
        period("new-0", ~U[2026-06-11 00:00:00Z], ~U[2026-07-11 00:00:00Z])
      ])

    pay(sub, "store_test_pro", "apple:year2", ~U[2026-06-11 00:00:00Z], ~U[2026-07-11 00:00:00Z],
      replaces: %{at: ~U[2026-06-11 00:00:00Z], payment_id: "apple:year1"}
    )

    statuses = sub.id |> cycles() |> Enum.map(&elem(&1, 2)) |> Enum.frequencies()
    assert statuses == %{"issued" => 2, "replaced" => 11}

    # The replaced months never issue.
    assert {:ok, %{processed: 0}} =
             Subscriptions.run_due_cycles(%{at: ~U[2026-08-15 00:00:00Z], limit: 50})

    assert length(grants()) == 2
  end

  test "a store refund revokes only the refunded payment's unspent credits" do
    sub =
      subscribe("store_test_plus", [
        period("2026-06-01", ~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z])
      ])

    pay(sub, "store_test_plus", "apple:t1", ~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z])

    assert {:ok, %{grants: [_]}} =
             PaymentRights.apply("apple:t1", "apple:refund:1", fn ->
               {:ok, %{type: :refund, amount: 2_000, full: true}}
             end)

    assert [{0, _, "apple:t1"}] = grants()
  end

  test "resubscribing after a refund issues only the new payment's full grant" do
    {sub, cycles1} =
      subscribe_with_cycles("store_test_plus", [
        period("t1:2026-06-01", ~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z])
      ])

    pay(sub, "store_test_plus", "apple:t1", ~U[2026-06-01 00:00:00Z], ~U[2026-07-01 00:00:00Z],
      cycle_ids: Enum.map(cycles1, & &1.id)
    )

    assert {:ok, %{grants: [_]}} =
             PaymentRights.apply("apple:t1", "apple:refund:1", fn ->
               {:ok, %{type: :refund, amount: 2_000, full: true}}
             end)

    {sub, cycles2} =
      subscribe_with_cycles("store_test_pro", [
        period("t2:2026-06-11", ~U[2026-06-11 00:00:00Z], ~U[2026-07-11 00:00:00Z])
      ])

    pay(sub, "store_test_pro", "apple:t2", ~U[2026-06-11 00:00:00Z], ~U[2026-07-11 00:00:00Z],
      cycle_ids: Enum.map(cycles2, & &1.id),
      replaces: %{at: ~U[2026-06-11 00:00:00Z], provider: "apple"}
    )

    assert grants() == [
             {0, ~U[2026-07-01 00:00:00Z], "apple:t1"},
             {1500, ~U[2026-07-11 00:00:00Z], "apple:t2"}
           ]
  end

  test "an annual upgrade at the exact start of an unissued month succeeds without offset" do
    months =
      for m <- 0..11 do
        starts = DateTime.shift(~U[2026-06-01 00:00:00Z], month: m)
        period("year1:#{m}", starts, DateTime.shift(starts, month: 1))
      end

    {sub, cycles1} = subscribe_with_cycles("store_test_plus", months)

    pay(sub, "store_test_plus", "apple:year1", ~U[2026-06-01 00:00:00Z], ~U[2027-06-01 00:00:00Z],
      cycle_ids: Enum.map(cycles1, & &1.id)
    )

    {sub, cycles2} =
      subscribe_with_cycles("store_test_pro", [
        period("year2:0", ~U[2026-07-01 00:00:00Z], ~U[2026-08-01 00:00:00Z])
      ])

    pay(sub, "store_test_pro", "apple:year2", ~U[2026-07-01 00:00:00Z], ~U[2026-08-01 00:00:00Z],
      cycle_ids: Enum.map(cycles2, & &1.id),
      replaces: %{at: ~U[2026-07-01 00:00:00Z], provider: "apple"}
    )

    assert grants() == [
             {500, ~U[2026-07-01 00:00:00Z], "apple:year1"},
             {1500, ~U[2026-08-01 00:00:00Z], "apple:year2"}
           ]

    statuses = sub.id |> cycles() |> Enum.map(&elem(&1, 2)) |> Enum.frequencies()
    assert statuses == %{"issued" => 2, "replaced" => 11}
  end

  test "an annual upgrade at the exact start of an already-issued month deducts its full grant" do
    months =
      for m <- 0..11 do
        starts = DateTime.shift(~U[2026-06-01 00:00:00Z], month: m)
        period("year1:#{m}", starts, DateTime.shift(starts, month: 1))
      end

    {sub, cycles1} = subscribe_with_cycles("store_test_plus", months)

    pay(sub, "store_test_plus", "apple:year1", ~U[2026-06-01 00:00:00Z], ~U[2027-06-01 00:00:00Z],
      cycle_ids: Enum.map(cycles1, & &1.id)
    )

    assert {:ok, %{processed: 1}} =
             Subscriptions.run_due_cycles(%{at: ~U[2026-07-01 00:00:00Z], limit: 50})

    {sub, cycles2} =
      subscribe_with_cycles("store_test_pro", [
        period("year2:0", ~U[2026-07-01 00:00:00Z], ~U[2026-08-01 00:00:00Z])
      ])

    pay(sub, "store_test_pro", "apple:year2", ~U[2026-07-01 00:00:00Z], ~U[2026-08-01 00:00:00Z],
      cycle_ids: Enum.map(cycles2, & &1.id),
      replaces: %{at: ~U[2026-07-01 00:00:00Z], provider: "apple"}
    )

    # Both grants for July expire on August 1, so their row order is not fixed.
    assert Enum.sort(grants()) ==
             Enum.sort([
               {500, ~U[2026-07-01 00:00:00Z], "apple:year1"},
               {500, ~U[2026-08-01 00:00:00Z], "apple:year1"},
               {1000, ~U[2026-08-01 00:00:00Z], "apple:year2"}
             ])

    statuses = sub.id |> cycles() |> Enum.map(&elem(&1, 2)) |> Enum.frequencies()
    assert statuses == %{"issued" => 3, "replaced" => 10}
  end

  defp subscribe(package_code, periods) do
    {subscription, _cycles} = subscribe_with_cycles(package_code, periods)
    subscription
  end

  defp subscribe_with_cycles(package_code, periods) do
    {:ok, %{subscription: subscription, cycles: cycles}} =
      Subscriptions.create_subscription(%{
        billing_account_id: @account,
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: "wsp_store",
        package_code: package_code,
        package_version: "2026-06",
        source_type: "apple_subscription",
        source_id: "orig-1",
        source_event_id: "apple:orig-1",
        idempotency_key: "apple:subscription:orig-1",
        periods: periods
      })

    {subscription, cycles}
  end

  defp pay(subscription, package_code, payment_id, starts, ends, extra \\ []) do
    {:ok, package} =
      PackageCatalog.get_package_version(%{
        repo: BillingCore.Repo,
        package_code: package_code,
        version: "2026-06"
      })

    payment =
      Map.merge(
        %{
          provider: "apple",
          payment_id: payment_id,
          valid_from: starts,
          expires_at: ends,
          disputes: %{},
          fully_refunded: false
        },
        Map.new(extra)
      )

    {:ok, _} = PaidCycles.record_invoice(subscription, package, payment_id, payment, starts)
  end

  defp period(key, starts, ends), do: %{cycle_key: key, valid_from: starts, expires_at: ends}

  defp grants do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      SELECT remaining_credits, expires_at, metadata->>'provider_payment_id' FROM credit_grants
      WHERE billing_account_id = $1 ORDER BY expires_at, id
      """,
      [@account]
    ).rows
    |> Enum.map(fn [credits, expires_at, payment] ->
      {credits, DateTime.truncate(expires_at, :second), payment}
    end)
  end

  defp cycles(subscription) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      SELECT cycle_key, period_end, status FROM billing_subscription_cycles
      WHERE subscription_id = $1 ORDER BY period_start, cycle_key
      """,
      [subscription]
    ).rows
    |> Enum.map(fn [key, ends, status] -> {key, DateTime.truncate(ends, :second), status} end)
  end

  defp seed_package(code, credits) do
    {:ok, _} = PackageCatalog.create_package(%{code: code, surface: "comma", name: code})

    {:ok, _} =
      PackageCatalog.create_package_version(%{
        package_code: code,
        version: "2026-06",
        surface: "comma",
        kind: "subscription",
        billing_period: "month",
        grant_credits: credits,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 2_000,
        usage_policy: %{},
        effective_at: ~U[2026-06-01 00:00:00Z],
        status: "active"
      })
  end
end
