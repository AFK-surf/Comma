defmodule SalixWeb.Dashboard.EnvFilesConfigLiveTest do
  @moduledoc "Environments, the VFS file browser, and agent defaults via LiveView."
  use ExUnit.Case, async: false

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

  test "environments index renders" do
    {:ok, _v, html} = live(authed_conn(), "/dash/environments")
    assert html =~ "Devices"
  end

  test "device detail renders connector health and canonical runtime inventory" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Runtime Device"}, tenant_id())
    device_id = SalixStore.Ids.new_device_id()
    identity = "/private/bin/codex"
    runtime_id = RuntimeIds.runtime_id(identity)
    device_runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)
    checked_at = System.system_time(:millisecond)
    transport_id = "env-runtime-#{System.unique_integer([:positive])}"

    {:ok, ^transport_id, _record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant_id(),
          "group_id" => group["group_id"],
          "device_id" => device_id,
          "connector_id" => "connector-runtime-device",
          "name" => "Runtime Mac",
          "capabilities" => %{
            "runtime_probe" => true,
            "component_releases" => %{"salix-connect" => %{"release_id" => "v-test"}}
          },
          "agent_runtimes" => [
            %{
              "kind" => "external",
              "provider" => "codex",
              "command" => identity,
              "identity_material" => identity,
              "runtime_id" => runtime_id,
              "device_runtime_id" => device_runtime_id,
              "version" => "codex 1.2.3",
              "version_detected" => true,
              "auth_ready" => true,
              "native_server_startable" => true,
              "ready" => true,
              "readiness_checked_at" => checked_at,
              "readiness_valid_until" => checked_at + 600_000,
              "session_snapshot" => %{
                "schema_version" => 1,
                "observed_at" => checked_at,
                "session_count" => 1,
                "session_ids" => ["ses1_0000000000000000001"],
                "truncated" => false
              }
            }
          ],
          "runtime_session_snapshot_generation" => 1,
          "connector_health" => %{
            "schema_version" => 1,
            "observed_at" => checked_at,
            "process_started_at" => checked_at - 5_000,
            "request_inflight" => 1,
            "request_capacity" => 16,
            "runtime_proxy_inflight" => 0,
            "runtime_proxy_capacity" => 16,
            "managed_processes" => 2,
            "resumable_runtime_sessions" => 607,
            "recoverable_runtime_sessions" => 3,
            "pending_input_batches" => 1,
            "pending_runtime_events" => 0
          },
          "connector_health_updated_at" => checked_at
        },
        transport_id: transport_id
      )

    {:ok, view, html} =
      live(authed_conn(), "/dash/environments/#{group["group_id"]}/#{device_id}")

    account_html = view |> element("button[phx-click=manage-account]") |> render_click()
    assert account_html =~ "Runtime account"
    assert account_html =~ "unbound"
    assert has_element?(view, "form[phx-submit=bind-account]")
    refute has_element?(view, "button[phx-click=more-accounts]")

    assert view |> element("button[phx-click=refresh-account]") |> render_click() =~
             "Runtime account"

    assert html =~ "Connector health"
    assert html =~ "v-test"
    assert html =~ "Resumable sessions"
    assert html =~ "Recoverable executions"
    assert html =~ "External runtimes"
    assert html =~ "codex 1.2.3"
    assert html =~ "Connector-held sessions"
    assert html =~ "ses1_0000000000000000001"
    refute html =~ "running tasks"
    refute html =~ identity

    assert render_click(view, "select-runtime", %{"device_runtime_id" => "other"}) =~
             "Runtime not found."
  end

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

  test "agent defaults page separates platform following from tenant creation choices" do
    {:ok, global} = SalixAgent.Templates.create(%{"name" => "Platform pick", "model" => "mock"})

    {:ok, other} = SalixAgent.Templates.create(%{"name" => "Other endpoint", "model" => "mock"})

    {:ok, private} =
      SalixAgent.Templates.create_private(
        %{"name" => "Tenant pick", "model" => "mock"},
        tenant_id()
      )

    {:ok, view, _html} = live(authed_conn(), "/dash/agent-defaults")

    html =
      view
      |> form("form[phx-submit=save-platform]", %{"worker_template_id" => global["template_id"]})
      |> render_submit()

    assert html =~ "Platform defaults saved"

    global_id = global["template_id"]

    assert {:ok, ^global_id, :platform_default} =
             SalixAgent.AgentDefaults.resolve_role_default("worker", tenant_id())

    html =
      view
      |> form("form[phx-submit=save-tenant]", %{"worker_template_id" => private["template_id"]})
      |> render_submit()

    assert html =~ "Tenant defaults saved"

    assert has_element?(
             view,
             "form[phx-submit=save-tenant] select[name=worker_template_id] option[value='#{private["template_id"]}'][selected]",
             "mock — Tenant pick"
           )

    assert has_element?(
             view,
             "form[phx-submit=save-platform] select[name=worker_template_id] option[value='#{global["template_id"]}']",
             "mock — Platform pick"
           )

    assert has_element?(
             view,
             "form[phx-submit=save-platform] select[name=worker_template_id] option[value='#{other["template_id"]}']",
             "mock — Other endpoint"
           )

    private_id = private["template_id"]

    assert has_element?(
             view,
             "form[phx-submit=save-tenant] select[name=worker_template_id] option[value='']",
             "Default (mock)"
           )

    refute has_element?(
             view,
             "form[phx-submit=save-tenant] select[name=worker_template_id] option[value=default]"
           )

    assert {:ok, ^global_id, :platform_default} =
             SalixAgent.AgentDefaults.resolve_template_id(%{
               "role" => "worker",
               "tenant_id" => tenant_id()
             })

    assert {:ok, ^private_id} = SalixAgent.AgentDefaults.creation_template("worker", tenant_id())

    assert {:ok, ^private_id, :tenant_default} =
             SalixAgent.AgentDefaults.resolve_role_default("worker", tenant_id())

    # Clearing the tenant pointer defers to the platform layer again.
    view
    |> form("form[phx-submit=save-tenant]", %{"worker_template_id" => ""})
    |> render_submit()

    assert {:ok, ^global_id, :platform_default} =
             SalixAgent.AgentDefaults.resolve_role_default("worker", tenant_id())
  end

  test "agent file browser renders root" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "FileGrp"}, tenant_id())
    {:ok, tmpl} = SalixAgent.Templates.create(%{"name" => "FileTmpl", "model" => "mock"})

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "FileAgent",
          "group_id" => group["group_id"],
          "template_id" => tmpl["template_id"]
        },
        tenant_id()
      )

    {:ok, _v, html} = live(authed_conn(), "/dash/agents/#{agent["agent_id"]}/files")
    assert html =~ "Files"
  end

  defp connected_device!(group_id, name) do
    transport_id = "env-live-#{System.unique_integer([:positive])}"
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
