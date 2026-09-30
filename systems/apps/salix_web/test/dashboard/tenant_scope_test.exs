defmodule SalixWeb.Dashboard.TenantScopeTest do
  @moduledoc "Tenant switcher: runtime views scope to the session-selected tenant."
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_session: 2]

  @endpoint SalixWeb.DashboardEndpoint

  defp conn_for(tenant) do
    session = %{"admin_authed" => true}
    session = if tenant, do: Map.put(session, "current_tenant", tenant), else: session
    build_conn() |> Plug.Test.init_test_session(session)
  end

  defp agent_in(tenant, name) do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "G-#{tenant}"}, tenant)
    {:ok, tmpl} = SalixAgent.Templates.create(%{"name" => "T-#{name}", "model" => "mock"})

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"name" => name, "group_id" => group["group_id"], "template_id" => tmpl["template_id"]},
        tenant
      )

    agent
  end

  test "agents list is scoped to the session-selected tenant" do
    {:ok, default_tenant} = Salix.Control.Tenants.create(%{"name" => "Default"})
    {:ok, t2_tenant} = Salix.Control.Tenants.create(%{"name" => "T2"})
    default_id = default_tenant["tenant_id"]
    t2 = t2_tenant["tenant_id"]
    default_agent = agent_in(default_id, "DefaultOnlyAgent-#{System.unique_integer([:positive])}")
    t2_agent = agent_in(t2, "T2OnlyAgent-#{System.unique_integer([:positive])}")

    # Scoped to t2: shows the t2 agent, hides the default-tenant agent.
    {:ok, _view, html} = live(conn_for(t2), "/dash/agents")
    assert html =~ t2_agent["name"]
    refute html =~ default_agent["name"]

    # Scoped to "default": shows the default agent, hides the t2 agent.
    {:ok, _view, html} = live(conn_for(default_id), "/dash/agents")
    assert html =~ default_agent["name"]
    refute html =~ t2_agent["name"]
  end

  test "the sidebar switcher offers the available tenants" do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Switch"})
    t = tenant["tenant_id"]

    {:ok, _view, html} = live(conn_for(nil), "/dash/agents")
    assert html =~ "tenant-switcher"
    assert html =~ "/dash/tenant/select?tenant_id=#{t}"
  end

  test "TenantController.select stores the tenant in the session and redirects" do
    conn = get(conn_for(nil), "/dash/tenant/select?tenant_id=acme")
    assert redirected_to(conn) == "/dash/agents"
    assert get_session(conn, "current_tenant") == "acme"
  end
end
