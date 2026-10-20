defmodule SalixWeb.Dashboard.IMLiveTest do
  @moduledoc "Dashboard IM connects, config, router session links and memory links."
  use SystemsClock.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixIM.Conversations
  alias SalixIM.ProviderConnects

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "IM"})
    Process.put(:test_tenant_id, tenant["tenant_id"])
    :ok
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  test "im config saves a valid JSON document" do
    {:ok, view, _html} = live(authed_conn(), "/dash/im-config")

    html =
      view
      |> form("form[phx-submit=save]", %{"config" => ~s({"slack":{"bot_token":"xoxb-1"}})})
      |> render_submit()

    assert html =~ "IM config saved"
    {:ok, cfg} = Salix.Control.Tenants.get_config(tenant_id(), "im_integrations", %{})
    assert cfg["slack"]["bot_token"] == "xoxb-1"
  end
end
