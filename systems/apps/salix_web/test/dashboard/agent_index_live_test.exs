defmodule SalixWeb.Dashboard.AgentIndexLiveTest do
  @moduledoc """
  Agents index loading semantics: skeleton-only dead render and storage
  failures surfacing as a retry banner instead of an empty tenant.
  """
  use SystemsClock.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SalixStore.Keys

  @endpoint SalixWeb.DashboardEndpoint

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Agent index"})
    Process.put(:test_tenant_id, tenant["tenant_id"])
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "IdxGrp"}, tenant_id())

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "IdxAgent",
          "group_id" => group["group_id"],
          "role" => "worker"
        },
        tenant_id()
      )

    %{group: group, agent: agent}
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  defp agents_prefix, do: Keys.ctl_agents_prefix_for_tenant(tenant_id())

  test "dead render shows the skeleton and does not scan agent control storage" do
    SalixStore.S3.Fake.reset_read_log()

    html = authed_conn() |> get("/dash/agents") |> html_response(200)

    assert html =~ "agents-skeleton"
    refute html =~ "IdxAgent"

    prefix = agents_prefix()

    refute Enum.any?(SalixStore.S3.Fake.read_log(), fn
             {:list, ^prefix, _opts} -> true
             _ -> false
           end)
  end
end
