defmodule BillingCommerce do
  @moduledoc """
  Package catalog and source-to-grant commands for billing commerce.
  """

  alias BillingCommerce.{
    DefaultEntitlements,
    ManualGrants,
    PackageCatalog,
    PricingSync,
    ProviderCustomers,
    ProviderPrices,
    RedeemCodes,
    Subscriptions
  }

  defdelegate create_package(attrs), to: PackageCatalog
  defdelegate create_package_version(attrs), to: PackageCatalog
  defdelegate get_package_version(attrs), to: PackageCatalog
  defdelegate list_package_versions(attrs \\ %{}), to: PackageCatalog
  defdelegate put_provider_price(attrs), to: ProviderPrices
  defdelegate list_provider_plans(attrs), to: ProviderPrices
  defdelegate get_provider_plan(attrs), to: ProviderPrices

  defdelegate sync_local_pricing_catalog(catalog, opts \\ []),
    to: PricingSync,
    as: :sync_local_catalog

  defdelegate pricing_catalog_current?(catalog, opts \\ []),
    to: PricingSync,
    as: :catalog_current?

  defdelegate get_active_provider_customer(attrs), to: ProviderCustomers, as: :get_active_customer
  defdelegate bind_provider_customer(attrs), to: ProviderCustomers, as: :bind_customer

  defdelegate upsert_provider_customer_from_event(attrs),
    to: ProviderCustomers,
    as: :upsert_from_provider_event

  defdelegate issue_manual_grant(attrs), to: ManualGrants
  defdelegate issue_bridge_org_grant(attrs), to: ManualGrants
  defdelegate issue_comma_support_grant(attrs), to: ManualGrants
  defdelegate issue_comma_admin_support_grant(attrs), to: ManualGrants
  defdelegate issue_bridge_platform_unlimited(attrs), to: DefaultEntitlements
  defdelegate ensure_bridge_platform_unlimited_package(attrs \\ %{}), to: DefaultEntitlements

  defdelegate sync_bridge_default_entitlements(attrs \\ %{}),
    to: DefaultEntitlements,
    as: :sync_bridge_defaults

  defdelegate create_subscription(attrs), to: Subscriptions
  defdelegate run_due_cycles(attrs \\ %{}), to: Subscriptions
  defdelegate issue_one_time_purchase(attrs), to: Subscriptions
  defdelegate set_provider_subscription_status(attrs), to: Subscriptions
  defdelegate refund_one_time_purchase(attrs), to: Subscriptions

  defdelegate create_redeem_code(attrs), to: RedeemCodes, as: :create_code
  defdelegate disable_redeem_code(attrs), to: RedeemCodes, as: :disable_code
  defdelegate list_redeem_codes(attrs \\ %{}), to: RedeemCodes, as: :list_codes
  defdelegate list_redemptions(attrs \\ %{}), to: RedeemCodes
  defdelegate apply_redeem_code(attrs), to: RedeemCodes, as: :apply_code
end
