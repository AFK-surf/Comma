defmodule SalixWeb.Dashboard.MediaSettingsLiveTest do
  @moduledoc "The operator page for the platform's media settings."
  use SystemsClock.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint SalixWeb.DashboardEndpoint

  setup do
    on_exit(fn -> SalixStore.S3.delete(SalixStore.Keys.ctl_system_media_settings()) end)
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Media settings UI"})

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{
        "admin_authed" => true,
        "current_tenant" => tenant["tenant_id"]
      })

    {:ok, conn: conn}
  end

  test "an operator saves a media model and is told about bad JSON", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dash/media-settings")

    view
    |> form("#media-settings-form", %{"video_config" => "{not json"})
    |> render_submit()

    assert render(view) =~ "Enter a JSON object"
    assert {:ok, %{}} = SalixAgent.MediaSettings.get()

    view
    |> form("#media-settings-form", %{
      "video_config" => ~s({"provider": "volcengine", "model": "doubao-seedance-2-0"})
    })
    |> render_submit()

    assert render(view) =~ "Media settings saved."

    assert {:ok, %{"video_config" => %{"model" => "doubao-seedance-2-0"}}} =
             SalixAgent.MediaSettings.get()
  end
end
