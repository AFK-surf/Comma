defmodule SalixWeb.Dashboard.AgentIndexLiveTest do
  @moduledoc """
  Agents index loading semantics: skeleton-only dead render, single load on
  the connected mount with no auto-refresh, and storage failures surfacing
  as a retry banner instead of an empty tenant.
  """
  use ExUnit.Case, async: false

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
    {:ok, tmpl} = SalixAgent.Templates.create(%{"name" => "IdxTmpl", "model" => "mock"})

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "IdxAgent",
          "group_id" => group["group_id"],
          "template_id" => tmpl["template_id"],
          "role" => "worker"
        },
        tenant_id()
      )

    %{group: group, template: tmpl, agent: agent}
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

  # The merge-base regression was a 5s :timer.send_interval; this test must
  # outlast that interval or a restored timer would still pass it.
  @former_refresh_interval_ms 5_000

  test "connected mount lists the agent prefix exactly once, with no refresh past the former interval" do
    SalixStore.S3.Fake.reset_read_log()

    {:ok, view, html} = live(authed_conn(), "/dash/agents")

    assert html =~ "IdxAgent"
    refute html =~ "agents-skeleton"

    assert agent_prefix_list_count() == 1

    Process.sleep(@former_refresh_interval_ms + 500)
    _ = render(view)

    assert agent_prefix_list_count() == 1
  end

  defp agent_prefix_list_count do
    prefix = agents_prefix()

    Enum.count(SalixStore.S3.Fake.read_log(), fn
      {:list, ^prefix, _opts} -> true
      _ -> false
    end)
  end

  test "a transient LIST failure shows a retry banner, not an empty tenant" do
    SalixStore.S3.Fake.set_fault({:fail, 503, :list, agents_prefix()})

    {:ok, view, html} = live(authed_conn(), "/dash/agents")

    assert html =~ "agents-load-error"
    assert html =~ "Failed to load agents"
    refute html =~ "No agents"
    refute html =~ "agents-skeleton"

    # The injected fault is one-shot, so retry succeeds and clears the banner.
    html = view |> element("[data-role=agents-load-error] button") |> render_click()

    refute html =~ "agents-load-error"
    assert html =~ "IdxAgent"
  end

  test "a load failure after a successful load keeps the last-good rows" do
    {:ok, view, html} = live(authed_conn(), "/dash/agents")
    assert html =~ "IdxAgent"

    SalixStore.S3.Fake.set_fault({:fail, 503, :list, agents_prefix()})

    html =
      view
      |> element("form[phx-change=filter]")
      |> render_change(%{"status" => "idle", "group_id" => ""})

    assert html =~ "agents-load-error"
    assert html =~ "may be stale"
    assert html =~ "IdxAgent"
  end
end
