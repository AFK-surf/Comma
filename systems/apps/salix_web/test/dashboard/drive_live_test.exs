defmodule SalixWeb.Dashboard.DriveLiveTest do
  @moduledoc """
  Drive dashboard surfaces: the tenant/platform-default settings page and the
  group page's Drive tab (write-only key, source badge, control-plane probe).
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Salix.Control.{DriveBindings, DriveSettings}

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    SalixStore.Repo.query!("TRUNCATE drive_settings, drive_bindings")
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Drive"})
    tenant_id = tenant["tenant_id"]
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Drive group"}, tenant_id)
    previous = Application.get_env(:salix_web, :drive_req_options)
    Application.put_env(:salix_web, :drive_req_options, plug: {Req.Test, Salix.Drive.Files})

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:salix_web, :drive_req_options)
        value -> Application.put_env(:salix_web, :drive_req_options, value)
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
        "devices" => [%{"label" => "cloud-1"}],
        "writes" => %{"enabled" => true, "attached" => true, "device" => "cloud-1"}
      })
    end)

    html = view |> element("button", "Check") |> render_click()
    assert html =~ "readable"
    assert html =~ "writable"
  end

  test "a Comma-minted binding is marked as such on the group tab", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    {:ok, _} =
      DriveBindings.put(group_id, %{
        "org_slug" => "comma-abc",
        "api_key" => "synch_comma",
        "api_key_id" => "key_1",
        "source" => "comma",
        "base_url" => "https://sync.example.com"
      })

    {:ok, _view, html} = live(authed_conn(tenant_id), "/dash/groups/#{group_id}?tab=drive")
    assert html =~ "Comma created this binding"
    assert html =~ "comma-abc"
    refute html =~ "synch_comma"
  end

  test "pending revocations read differently for a Comma binding and an operator's", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    {:ok, _} =
      DriveBindings.put(group_id, %{
        "org_slug" => "comma-abc",
        "api_key" => "synch_comma",
        "api_key_id" => "key_2",
        "retired_key_ids" => ["key_1"],
        "source" => "comma",
        "base_url" => "https://sync.example.com"
      })

    {:ok, view, html} = live(authed_conn(tenant_id), "/dash/groups/#{group_id}?tab=drive")
    assert html =~ "key_1"
    assert html =~ "Comma retries on its next"
    refute html =~ "Comma does not retry"

    # Disabling here is a takeover: the retry promise goes with it.
    view
    |> form("#drive-binding-form", %{
      "org_slug" => "comma-abc",
      "network" => "default",
      "space" => "comma-drive",
      "api_key" => "",
      "base_url" => "https://sync.example.com",
      "enabled" => "false"
    })
    |> render_submit()

    html = render(view)
    assert html =~ "key_1"
    assert html =~ "Comma does not retry"
    refute html =~ "Comma retries on its next"

    assert {:ok, %{"source" => "manual", "retired_key_ids" => ["key_1"]}} =
             DriveBindings.stored(group_id)
  end
end
