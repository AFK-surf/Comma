defmodule SalixWeb.Dashboard.DriveLiveTest do
  @moduledoc """
  Drive dashboard surfaces: the tenant/platform-default settings page and the
  group page's Drive tab (write-only key, source badge, control-plane probe).
  """
  use SystemsClock.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Salix.Control.{DriveBindings, DriveSettings}

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    SalixStore.Repo.query!("TRUNCATE drive_settings, drive_bindings")
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Drive"})
    tenant_id = tenant["tenant_id"]
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Drive group"}, tenant_id)
    previous = SystemsRuntime.get_env(:salix_web, :drive_req_options)
    SystemsRuntime.put_env(:salix_web, :drive_req_options, plug: {Req.Test, Salix.Drive.Files})

    on_exit(fn ->
      case previous do
        nil -> SystemsRuntime.delete_env(:salix_web, :drive_req_options)
        value -> SystemsRuntime.put_env(:salix_web, :drive_req_options, value)
      end

      DriveSettings.delete(tenant_id)
      DriveSettings.delete_default()
      DriveBindings.delete(group["group_id"])
    end)

    {:ok, tenant_id: tenant_id, group_id: group["group_id"]}
  end

  defp authed_conn(tenant_id),
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id})

  test "settings page saves the platform default and the tenant override", %{tenant_id: tenant_id} do
    {:ok, view, html} = live(authed_conn(tenant_id), "/dash/drive")
    assert html =~ "Drive"
    assert html =~ "not configured"

    view
    |> form("#drive-default-form", %{
      "base_url" => "https://sync.example.com",
      "enabled" => "true"
    })
    |> render_submit()

    assert render(view) =~ "platform default"
    assert {:ok, %{"base_url" => "https://sync.example.com"}} = DriveSettings.get(tenant_id)

    view
    |> form("#drive-form", %{"base_url" => "not an origin", "enabled" => "true"})
    |> render_submit()

    assert render(view) =~ "HTTPS origin"

    view
    |> form("#drive-form", %{"base_url" => "https://tenant.example.com", "enabled" => "true"})
    |> render_submit()

    assert {:ok, %{"base_url" => "https://tenant.example.com"}} = DriveSettings.get(tenant_id)
    refute render(view) =~ "platform default"
  end

  test "the group tab saves a binding write-only and probes the control plane", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    {:ok, _} = DriveSettings.put_default(%{"base_url" => "http://127.0.0.1:1"})
    {:ok, view, html} = live(authed_conn(tenant_id), "/dash/groups/#{group_id}?tab=drive")
    assert html =~ "Drive binding"
    assert html =~ "not configured"

    view
    |> form("#drive-binding-form", %{
      "org_slug" => "acme",
      "network" => "default",
      "space" => "comma-drive",
      "api_key" => "synch_operator",
      "base_url" => "",
      "enabled" => "true"
    })
    |> render_submit()

    html = render(view)
    assert html =~ "configured"
    assert html =~ "leave blank to keep"
    refute html =~ "synch_operator"

    assert {:ok, %{"api_key" => "synch_operator", "source" => "manual"}} =
             DriveBindings.get(group_id)

    # Saving without a key keeps the stored one.
    view
    |> form("#drive-binding-form", %{
      "org_slug" => "acme",
      "network" => "default",
      "space" => "docs",
      "api_key" => "",
      "base_url" => "",
      "enabled" => "true"
    })
    |> render_submit()

    assert {:ok, %{"api_key" => "synch_operator", "space" => "docs"}} =
             DriveBindings.get(group_id)

    Req.Test.stub(Salix.Drive.Files, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synch_operator"]

      Req.Test.json(conn, %{
        "enabled" => true,
        "devices" => [%{"device" => "cloud-1", "spaces" => ["docs"]}],
        "writes" => %{"enabled" => true, "attached" => true, "device" => "cloud-1"}
      })
    end)

    html = view |> element("button", "Check") |> render_click()
    assert html =~ "readable"
    assert html =~ "writable"
  end
end
