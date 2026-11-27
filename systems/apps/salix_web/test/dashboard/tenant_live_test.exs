defmodule SalixWeb.Dashboard.TenantLiveTest do
  @moduledoc "Cluster overview, tenant CRUD, API keys and the platform Router via LiveView."
  use SystemsClock.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SalixWeb.DashboardEndpoint

  defp authed_conn do
    build_conn()
    |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => "default"})
  end

  test "tenants index lists tenants and creates a new one" do
    {:ok, view, _html} = live(authed_conn(), "/dash/tenants")

    name = "Acme #{SystemsRuntime.Proc.unique_integer([:positive])}"

    # Open the create modal, then submit the form.
    render_click(element(view, "button[phx-click=new]"))

    {:ok, show_view, html} =
      view
      |> form("#new-tenant form", %{"name" => name})
      |> render_submit()
      |> follow_redirect(authed_conn())

    assert html =~ name
    # API key lifecycle on the show page.
    html = render_submit(form(show_view, "form[phx-submit=create-key]", %{"name" => "ci-key"}))
    assert html =~ "copy it now"
  end

  test "saving a platform Router marks the tenant's Routers; clearing removes the record" do
    alias SalixAgent.{AccountPool, Control, PlatformRouter}

    platform = AccountPool.platform_tenant()
    router_id = SalixAgent.TestSupport.new_agent_id()
    router = SalixAgent.TestSupport.create_control_agent!(router_id, %{role: "router"})
    tenant = router["tenant_id"]
    {:ok, _} = Salix.Control.Tenants.create_preallocated(%{"name" => "Router tenant"}, tenant)

    on_exit(fn ->
      SalixAgent.SubscriptionStore.query(
        "DELETE FROM subscription_accounts WHERE tenant_id=$1",
        [platform]
      )

      PlatformRouter.delete(tenant)
    end)

    {:ok, _} =
      AccountPool.create(platform, %{
        "credential_kind" => "provider_api_key",
        "source" => "openrouter",
        "api_key" => "sk-or-v1-platform-router-0000"
      })

    {:ok, view, html} = live(authed_conn(), "/dash/tenants/#{tenant}")
    assert html =~ "Not set."

    html =
      view
      |> form("#tenant-platform-router", %{
        "router" => %{"model" => "gpt-5.5", "billing" => "record", "allow_paid" => "true"}
      })
      |> render_submit()

    assert html =~ "Platform Router saved. 1 Router(s) now use it."

    {:ok, models} = SalixWeb.Dashboard.RoutingModels.platform_models()
    name = Enum.find_value(models, "gpt-5.5", &(&1["model"] == "gpt-5.5" && &1["name"]))
    summary = view |> element("#platform-router-summary") |> render()
    assert summary =~ name
    assert summary =~ "subscriptions and API keys"

    assert {:ok, %{"model" => "gpt-5.5", "billing" => "record", "allow_paid" => true}} =
             PlatformRouter.get(tenant)

    assert {:ok,
            %{
              "model" => %{
                "kind" => "catalog",
                "model" => "gpt-5.5",
                "platform" => true,
                "allow_paid" => true
              }
            }} = Control.get(router_id, tenant)

    html = render_click(element(view, "button[phx-click=clear-router]"))
    assert html =~ "Platform Router cleared."
    assert {:error, :not_found} = PlatformRouter.get(tenant)
  end
end
