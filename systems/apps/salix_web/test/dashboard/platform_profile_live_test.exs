defmodule SalixWeb.Dashboard.PlatformProfileLiveTest do
  @moduledoc """
  The operator page for platform Profiles: an operator adds a key, disables
  it and deletes it, and the key is never shown back.
  """
  use SystemsClock.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint SalixWeb.DashboardEndpoint

  alias SalixAgent.AccountPool

  setup do
    on_exit(fn ->
      SalixAgent.SubscriptionStore.query("DELETE FROM subscription_accounts WHERE tenant_id=$1", [
        AccountPool.platform_tenant()
      ])
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Platform Profiles UI"})
    {:ok, tenant: tenant["tenant_id"]}
  end

  defp conn(tenant),
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant})

  defp platform_profiles do
    {:ok, %{"accounts" => accounts}} = AccountPool.list(AccountPool.platform_tenant())
    accounts
  end

  test "an operator adds, disables and deletes a platform Profile", %{tenant: tenant} do
    {:ok, view, html} = live(conn(tenant), "/dash/platform-profiles")
    assert html =~ "No platform Profiles"

    view
    |> form("#platform-profile-form",
      profile: %{"source" => "openrouter", "api_key" => "sk-or-v1-platform-0123456789"}
    )
    |> render_submit()

    html = render(view)
    assert html =~ "Platform Profile added."
    assert html =~ "OpenRouter API Key"
    refute html =~ "sk-or-v1-platform-0123456789"
    assert [%{"id" => id, "disabled" => false, "source" => "openrouter"}] = platform_profiles()

    view |> element("#platform-profile-#{id}") |> render_click()
    assert [%{"disabled" => true}] = platform_profiles()

    view |> element("button[phx-value-id='#{id}']", "Delete") |> render_click()
    assert render(view) =~ "Platform Profile deleted."

    assert {:ok, %{"accounts" => []}} = AccountPool.list(AccountPool.platform_tenant())
  end
end
