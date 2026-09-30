defmodule BillingCommerce.PackageCatalogTest do
  use ExUnit.Case, async: false

  alias BillingCommerce.PackageCatalog

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    seed_package("comma_monthly")
    :ok
  end

  test "package versions are immutable terms" do
    attrs = version_attrs("comma_monthly", "2026-06")

    assert {:ok, version} = PackageCatalog.create_package_version(attrs)
    assert version.grant_credits == 1_000
    assert version.usage_policy["llm_models"]["mode"] == "unrestricted"

    assert {:ok, duplicate} = PackageCatalog.create_package_version(attrs)
    assert duplicate.id == version.id
    assert duplicate.idempotent == true

    changed = %{attrs | grant_credits: 2_000}
    assert {:error, :package_version_immutable} = PackageCatalog.create_package_version(changed)
  end

  test "lists only latest issuable package versions" do
    assert {:ok, _} =
             PackageCatalog.create_package_version(version_attrs("comma_monthly", "2026-05"))

    assert {:ok, current} =
             PackageCatalog.create_package_version(version_attrs("comma_monthly", "2026-06"))

    seed_package("comma_expired")

    assert {:ok, _} =
             PackageCatalog.create_package_version(
               version_attrs("comma_expired", "2026-05")
               |> Map.put(:expires_at, ~U[2026-06-01 00:00:00Z])
             )

    assert {:ok, %{data: versions}} =
             PackageCatalog.list_package_versions(%{
               surface: "comma",
               issuable_only?: true,
               latest_per_package?: true,
               at: ~U[2026-06-18 00:00:00Z]
             })

    listed_versions = Map.new(versions, &{&1.package_code, &1})

    assert listed_versions["comma_monthly"].id == current.id
    assert listed_versions["comma_monthly"].package_name == "Comma Monthly"
    refute Map.has_key?(listed_versions, "comma_expired")
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
