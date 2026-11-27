defmodule SalixStore.FeishuTenantAppsTest do
  use SystemsClock.Case, async: false

  alias SalixStore.FeishuTenantApps

  defp tenant_id, do: "ten_multi_#{SystemsRuntime.Proc.unique_integer([:positive])}"

  defp app(tenant_id, app_id, attrs \\ %{}) do
    Map.merge(
      %{
        "tenant_id" => tenant_id,
        "app_id" => app_id,
        "app_secret" => "secret-#{app_id}",
        "verification_token" => "vt-#{app_id}",
        "encrypt_key" => "ek-#{app_id}",
        "updated_at" => 1_795_000_000
      },
      attrs
    )
  end

  test "a tenant keeps one record per app, and each is read, replaced and removed alone" do
    tenant = tenant_id()
    {:ok, _} = FeishuTenantApps.put(app(tenant, "cli_dept_b"))
    {:ok, _} = FeishuTenantApps.put(app(tenant, "cli_dept_a"))

    assert ["cli_dept_a", "cli_dept_b"] = Enum.map(FeishuTenantApps.list(tenant), & &1["app_id"])

    assert {:ok, %{"app_secret" => "secret-cli_dept_a"}} =
             FeishuTenantApps.get(tenant, "cli_dept_a")

    assert {:ok, %{"app_secret" => "secret-cli_dept_b"}} =
             FeishuTenantApps.get(tenant, "cli_dept_b")

    assert {:error, :not_found} = FeishuTenantApps.get(tenant, "cli_other")
    # Several apps have no single answer for a caller that does not name one.
    assert {:error, :ambiguous_tenant_app} = FeishuTenantApps.get(tenant)

    {:ok, _} =
      FeishuTenantApps.put(app(tenant, "cli_dept_b", %{"verification_token" => "vt-rotated"}))

    assert {:ok, %{"verification_token" => "vt-rotated"}} =
             FeishuTenantApps.get(tenant, "cli_dept_b")

    assert {:ok, %{"verification_token" => "vt-cli_dept_a"}} =
             FeishuTenantApps.get(tenant, "cli_dept_a")

    assert :ok = FeishuTenantApps.delete(tenant, "cli_dept_a")
    assert {:error, :not_found} = FeishuTenantApps.get(tenant, "cli_dept_a")
    assert {:ok, %{"app_id" => "cli_dept_b"}} = FeishuTenantApps.get(tenant)

    {:ok, _} = FeishuTenantApps.put(app(tenant, "cli_dept_a"))
    assert :ok = FeishuTenantApps.delete(tenant)
    assert [] = FeishuTenantApps.list(tenant)
  end

  test "an app record without an app id is refused" do
    assert_raise ArgumentError, fn -> FeishuTenantApps.put(app(tenant_id(), " ")) end
  end
end
