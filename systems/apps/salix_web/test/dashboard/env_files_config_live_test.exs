defmodule SalixWeb.Dashboard.EnvFilesConfigLiveTest do
  @moduledoc "Environments, the VFS file browser, and agent defaults via LiveView."
  use SystemsClock.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixEnv.Registry
  alias SalixStore.RuntimeIds

  @endpoint SalixWeb.DashboardEndpoint

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Environment"})
    Process.put(:test_tenant_id, tenant["tenant_id"])
    :ok
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  test "group connectors tab mints a group connector credential and lists only group devices" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Env Group"}, tenant_id())
    {:ok, other_group} = Salix.Control.Groups.create(%{"name" => "Other Env Group"}, tenant_id())

    device_id = connected_device!(group["group_id"], "Group Mac")
    other_device_id = connected_device!(other_group["group_id"], "Other Mac")

    {:ok, view, html} = live(authed_conn(), "/dash/groups/#{group["group_id"]}?tab=connectors")

    assert html =~ "Devices"
    assert html =~ "Mint connector credential"
    assert html =~ device_id
    refute html =~ other_device_id

    html =
      view
      |> form("#group-connector-token-form", %{
        "name" => "Lab Mac",
        "alias" => "lab"
      })
      |> render_submit()

    assert html =~ "Connector credential minted"
    assert html =~ "salix-connect --server"
    assert html =~ "SALIX_CONNECTOR_TOKEN="
    refute html =~ "SALIX_GROUP_ID="
    refute html =~ "SALIX_AGENT_ID"
    refute html =~ "agent_id"

    [token] = Regex.run(~r/salix_conn_[A-Za-z0-9_-]+/, html)

    render_patch(view, "/dash/groups/#{group["group_id"]}")
    html = render_patch(view, "/dash/groups/#{group["group_id"]}?tab=connectors")

    refute html =~ token
    assert html =~ device_id
    refute html =~ other_device_id
  end

  defp connected_device!(group_id, name) do
    transport_id = "env-live-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    device_id = SalixStore.Ids.new_device_id()

    {:ok, ^transport_id, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant_id(),
          "group_id" => group_id,
          "device_id" => device_id,
          "connector_id" => "connector-#{transport_id}",
          "name" => name,
          "os" => "darwin",
          "arch" => "arm64"
        },
        transport_id: transport_id
      )

    record["device_id"]
  end
end
