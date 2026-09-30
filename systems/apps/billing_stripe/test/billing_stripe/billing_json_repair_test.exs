defmodule BillingStripe.BillingJSONRepairTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    :ok
  end

  test "real Postgrex expressions converge without losing previous invoice ids or changing BFT data" do
    comma = subscription("comma", "json_comma")
    bft = subscription("bridge", "json_bft")
    first = Jason.encode!(%{"stripe_invoice_id" => "in_first", "status" => "active"})
    second = Jason.encode!(%{"stripe_invoice_id" => "in_second", "status" => "canceled"})

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_subscriptions SET source_metadata = $2 WHERE id = $1",
      [comma.id, first]
    )

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_subscriptions SET source_metadata = source_metadata || $2::jsonb WHERE id = $1",
      [comma.id, second]
    )

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_subscriptions SET source_metadata = $2 WHERE id = $1",
      [bft.id, first]
    )

    assert [[raw]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT source_metadata FROM billing_subscriptions WHERE id = $1",
               [comma.id]
             ).rows

    assert is_list(raw)
    decoded = BillingCore.Metadata.object(raw)
    assert decoded["stripe_invoice_id"] == "in_second"
    assert decoded["_legacy_updates"] == [first, second]
    BillingCore.BillingJSONRepair.run(BillingCore.Repo)

    assert [[^decoded]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT source_metadata FROM billing_subscriptions WHERE id = $1",
               [comma.id]
             ).rows

    assert [[^first]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT source_metadata FROM billing_subscriptions WHERE id = $1",
               [bft.id]
             ).rows

    assert Enum.all?(BillingCore.BillingJSONRepair.run(BillingCore.Repo), fn {_, count} ->
             count == 0
           end)
  end

  test "an invalid legacy expression reports its exact row and leaves it unchanged" do
    comma = subscription("comma", "json_invalid")

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_subscriptions SET source_metadata = $2 WHERE id = $1",
      [comma.id, 7]
    )

    assert_raise RuntimeError,
                 ~r/invalid Comma billing JSON at billing_subscriptions.source_metadata/,
                 fn ->
                   BillingCore.BillingJSONRepair.run(BillingCore.Repo)
                 end

    assert [[7]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT source_metadata FROM billing_subscriptions WHERE id = $1",
               [comma.id]
             ).rows
  end

  defp subscription(surface, code) do
    {:ok, _} =
      BillingCommerce.PackageCatalog.create_package(%{code: code, surface: surface, name: code})

    {:ok, _} =
      BillingCommerce.PackageCatalog.create_package_version(%{
        package_code: code,
        version: "v1",
        surface: surface,
        kind: "subscription",
        billing_period: "month",
        grant_credits: 10,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 100,
        usage_policy: %{},
        effective_at: ~U[2026-01-01 00:00:00Z],
        status: "active"
      })

    {:ok, %{subscription: result}} =
      BillingCommerce.Subscriptions.create_subscription(%{
        billing_account_id: "ba_" <> code,
        surface: surface,
        product_owner_type: "workspace",
        product_owner_id: code,
        package_code: code,
        package_version: "v1",
        source_type: "internal_subscription",
        source_id: code,
        source_event_id: code,
        idempotency_key: code,
        periods: [
          %{
            cycle_key: "2026-09",
            valid_from: ~U[2026-09-01 00:00:00Z],
            expires_at: ~U[2026-10-01 00:00:00Z]
          }
        ]
      })

    result
  end
end
