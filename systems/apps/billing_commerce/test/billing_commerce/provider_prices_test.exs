defmodule BillingCommerce.ProviderPricesTest do
  use ExUnit.Case, async: false

  alias BillingCommerce.{PackageCatalog, ProviderPrices}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    seed_package("comma_monthly")
    :ok
  end

  test "provider price maps to immutable package version" do
    assert {:ok, _version} =
             PackageCatalog.create_package_version(version_attrs("comma_monthly", "2026-06"))

    assert {:ok, price} =
             ProviderPrices.put_provider_price(%{
               provider: "stripe",
               provider_lookup_key: "example_monthly_v1",
               provider_price_id: "price_test_123",
               package_code: "comma_monthly",
               package_version: "2026-06",
               currency: "usd",
               amount_minor: 2_000
             })

    assert price.package_code == "comma_monthly"
    assert price.provider_lookup_key == "example_monthly_v1"

    assert {:ok, duplicate} =
             ProviderPrices.put_provider_price(%{
               provider: "stripe",
               provider_lookup_key: "example_monthly_v1",
               provider_price_id: "price_test_123",
               package_code: "comma_monthly",
               package_version: "2026-06"
             })

    assert duplicate.id == price.id
    assert duplicate.idempotent == true
  end

  test "provider price idempotency rejects conflicting package terms" do
    assert {:ok, _version} =
             PackageCatalog.create_package_version(version_attrs("comma_monthly", "2026-06"))

    seed_package("comma_test_alt")

    assert {:ok, _version} =
             PackageCatalog.create_package_version(version_attrs("comma_test_alt", "2026-06"))

    assert {:ok, price} =
             ProviderPrices.put_provider_price(%{
               provider: "stripe",
               provider_lookup_key: "example_monthly_v1",
               provider_price_id: "price_test_123",
               package_code: "comma_monthly",
               package_version: "2026-06",
               currency: "usd",
               amount_minor: 2_000
             })

    assert {:error, {:provider_price_mapping_conflict, :package_code}} =
             ProviderPrices.put_provider_price(%{
               provider: "stripe",
               provider_lookup_key: "example_monthly_v1",
               provider_price_id: price.provider_price_id,
               package_code: "comma_test_alt",
               package_version: "2026-06",
               currency: "usd",
               amount_minor: 2_000
             })

    assert {:error, {:provider_price_mapping_conflict, :amount_minor}} =
             ProviderPrices.put_provider_price(%{
               provider: "stripe",
               provider_lookup_key: "example_monthly_v1",
               provider_price_id: price.provider_price_id,
               package_code: "comma_monthly",
               package_version: "2026-06",
               currency: "usd",
               amount_minor: 3_000
             })
  end

  test "provider price idempotency rejects lookup key conflicts" do
    assert {:ok, _version} =
             PackageCatalog.create_package_version(version_attrs("comma_monthly", "2026-06"))

    assert {:ok, _price} =
             ProviderPrices.put_provider_price(%{
               provider: "stripe",
               provider_lookup_key: "example_monthly_v1",
               provider_price_id: "price_test_123",
               package_code: "comma_monthly",
               package_version: "2026-06",
               currency: "usd",
               amount_minor: 2_000
             })

    assert {:error, {:provider_price_mapping_conflict, :provider_price_id}} =
             ProviderPrices.put_provider_price(%{
               provider: "stripe",
               provider_lookup_key: "example_monthly_v1",
               provider_price_id: "price_test_456",
               package_code: "comma_monthly",
               package_version: "2026-06",
               currency: "usd",
               amount_minor: 2_000
             })
  end

  test "lists provider plans by stable lookup key and optionally requires synced price id" do
    assert {:ok, _} = BillingCommerce.sync_local_pricing_catalog(provider_plan_catalog())

    seed_package("comma_unsynced_filter")

    assert {:ok, _version} =
             PackageCatalog.create_package_version(
               version_attrs("comma_unsynced_filter", "2026-06")
               |> put_in([:usage_policy, "stripe_lookup_key"], "example_unsynced_filter_v1")
             )

    assert {:ok, _price} =
             ProviderPrices.put_provider_price(%{
               provider: "stripe",
               provider_lookup_key: "test_value_v1",
               provider_price_id: "price_test_value_v1",
               package_code: "test_value",
               package_version: "2026-06",
               currency: "usd",
               amount_minor: 2_000
             })

    assert {:ok, all_plans} =
             ProviderPrices.list_provider_plans(%{surface: "comma", provider: "stripe"})

    assert Enum.any?(all_plans, &(&1.provider_lookup_key == "example_unsynced_filter_v1"))

    assert {:ok, synced_plans} =
             ProviderPrices.list_provider_plans(%{
               surface: "comma",
               provider: "stripe",
               synced_only: true
             })

    refute Enum.any?(synced_plans, &(&1.provider_lookup_key == "example_unsynced_filter_v1"))
    plan = Enum.find(synced_plans, &(&1.provider_lookup_key == "test_value_v1"))

    assert plan.provider_price_id == "price_test_value_v1"
    assert plan.mode == "subscription"
    assert plan.grant_credits == 20_000_000

    assert {:ok, ^plan} =
             ProviderPrices.get_provider_plan(%{
               surface: "comma",
               provider: "stripe",
               provider_lookup_key: "test_value_v1"
             })
  end

  defp provider_plan_catalog do
    %{
      name: "provider_prices_test",
      provider: "stripe",
      packages: [
        %{
          code: "test_value",
          surface: "comma",
          name: "Test Value",
          status: "active",
          metadata: %{"description" => "Test monthly plan."}
        }
      ],
      versions: [
        %{
          package_code: "test_value",
          name: "Test Value",
          version: "2026-06",
          surface: "comma",
          kind: "subscription",
          billing_period: "month",
          grant_credits: 20_000_000,
          grant_period: "current_period",
          currency: "usd",
          amount_minor: 2_000,
          usage_policy: %{
            "llm_models" => %{"mode" => "unrestricted", "models" => []},
            "stripe_lookup_key" => "test_value_v1",
            "description" => "Test monthly plan."
          },
          effective_at: ~U[2026-06-01 00:00:00Z],
          status: "active",
          provider_lookup_key: "test_value_v1"
        }
      ]
    }
  end

  defp seed_package(code) do
    {:ok, _} =
      PackageCatalog.create_package(%{
        code: code,
        surface: "comma",
        name: "Comma Monthly"
      })
  end

  defp version_attrs(package_code, version) do
    %{
      package_code: package_code,
      version: version,
      surface: "comma",
      kind: "subscription",
      billing_period: "month",
      grant_credits: 1_000,
      grant_period: "current_period",
      currency: "usd",
      amount_minor: 2_000,
      usage_policy: %{
        "llm_models" => %{"mode" => "unrestricted", "models" => []}
      },
      effective_at: ~U[2026-06-17 00:00:00Z],
      status: "active"
    }
  end
end
