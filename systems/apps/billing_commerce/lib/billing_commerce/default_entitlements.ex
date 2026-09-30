defmodule BillingCommerce.DefaultEntitlements do
  @moduledoc "Product-owned default entitlement commands."

  alias BillingCommerce.{ManualGrants, PackageCatalog}

  @bridge_package_code "bridge_platform_unlimited"
  @bridge_package_version "2026-06"
  @bridge_far_future_expires_at ~U[2099-12-31 23:59:59Z]

  @bridge_usage_policy %{
    "usage_credits" => %{"mode" => "unlimited_metered"},
    "llm_models" => %{"mode" => "unrestricted", "models" => []},
    "vm_concurrency" => %{"mode" => "unrestricted", "limit" => nil},
    "storage_hard_cap" => %{"mode" => "unrestricted", "bytes" => nil}
  }

  @spec issue_bridge_platform_unlimited(map()) :: {:ok, map()} | {:error, term()}
  def issue_bridge_platform_unlimited(attrs) when is_map(attrs) do
    org_id = required(attrs, :organization_id)
    valid_from = attrs[:valid_from] || attrs["valid_from"] || DateTime.utc_now()
    expires_at = attrs[:expires_at] || attrs["expires_at"] || @bridge_far_future_expires_at

    with {:ok, _package} <- ensure_bridge_platform_unlimited_package(attrs),
         {:ok, _version} <- ensure_bridge_platform_unlimited_version(attrs) do
      attrs
      |> Map.merge(%{
        package_code: @bridge_package_code,
        package_version: @bridge_package_version,
        source_type: "default_entitlement",
        source_id: @bridge_package_code,
        source_event_id: "bridge:default_unlimited:#{org_id}:v1",
        idempotency_key: "bridge:default_unlimited:#{org_id}",
        valid_from: valid_from,
        expires_at: expires_at,
        operator: %{
          id: "bridge_default_entitlement",
          type: "system",
          reason: "bridge platform default unlimited entitlement"
        }
      })
      |> ManualGrants.issue_bridge_org_grant()
    end
  end

  @spec sync_bridge_defaults(map()) :: {:ok, map()} | {:error, term()}
  def sync_bridge_defaults(attrs \\ %{}) do
    with {:ok, package} <- ensure_bridge_platform_unlimited_package(attrs),
         {:ok, version} <- ensure_bridge_platform_unlimited_version(attrs) do
      {:ok, %{packages: [package], versions: [version]}}
    end
  end

  @spec ensure_bridge_platform_unlimited_package(map()) :: {:ok, map()} | {:error, term()}
  def ensure_bridge_platform_unlimited_package(attrs \\ %{}) do
    PackageCatalog.create_package(
      Map.merge(attrs, %{
        code: @bridge_package_code,
        surface: "bridge",
        name: "Bridge Platform Unlimited",
        status: "active"
      })
    )
  end

  @spec ensure_bridge_platform_unlimited_version(map()) :: {:ok, map()} | {:error, term()}
  def ensure_bridge_platform_unlimited_version(attrs \\ %{}) do
    PackageCatalog.create_package_version(
      Map.merge(attrs, %{
        package_code: @bridge_package_code,
        version: @bridge_package_version,
        surface: "bridge",
        kind: "manual",
        billing_period: "year",
        grant_credits: 0,
        grant_period: "explicit",
        currency: "usd",
        amount_minor: 0,
        usage_policy: @bridge_usage_policy,
        effective_at: ~U[2026-06-01 00:00:00Z],
        expires_at: nil,
        status: "active"
      })
    )
  end

  defp required(attrs, key) do
    attrs[key] || attrs[to_string(key)] ||
      raise ArgumentError, "missing default entitlement field #{key}"
  end
end
