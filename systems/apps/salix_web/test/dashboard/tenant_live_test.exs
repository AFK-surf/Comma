defmodule SalixWeb.Dashboard.TenantLiveTest do
  @moduledoc "Cluster overview, tenant CRUD, and API keys via LiveView."
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SalixWeb.DashboardEndpoint

  defp authed_conn do
    build_conn()
    |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => "default"})
  end

  test "cluster page renders stats and nodes" do
    {:ok, _view, html} = live(authed_conn(), "/dash/cluster")
    assert html =~ "Cluster"
    assert html =~ "Active nodes"
  end

  test "tenants index lists tenants and creates a new one" do
    {:ok, view, _html} = live(authed_conn(), "/dash/tenants")

    name = "Acme #{System.unique_integer([:positive])}"

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

  test "tenant config rejects invalid JSON" do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "CfgTest"})
    {:ok, view, _html} = live(authed_conn(), "/dash/tenants/#{tenant["tenant_id"]}")

    html =
      view
      |> form("form[phx-submit=save-config]", %{"config" => "{not json"})
      |> render_submit()

    assert html =~ "valid JSON"
  end
end
