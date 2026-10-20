defmodule SalixWeb.Dashboard.InitialAgentLiveTest do
  @moduledoc "Initial-agent slot list + create/edit via LiveView."
  use SystemsClock.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Initial agent dashboard test"})
    Process.put(:initial_agent_dashboard_tenant, tenant["tenant_id"])
    :ok
  end

  defp tenant_id, do: Process.get(:initial_agent_dashboard_tenant)

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  test "initial Agent seed stores and materializes a catalog model choice" do
    {:ok, view, _html} = live(authed_conn(), "/dash/initial-agents/new")

    {:ok, _, _} =
      view
      |> form("form[phx-submit=save]", %{
        "slot" => "catalog-worker",
        "display_name" => "Catalog worker",
        "model" => "gpt-5.5",
        "enabled" => "true"
      })
      |> render_submit()
      |> follow_redirect(authed_conn())

    {:ok, seed} = Salix.Control.InitialAgentSeeds.get("catalog-worker", tenant_id())
    assert %{"kind" => "catalog", "model" => "gpt-5.5"} = seed["model"]

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Catalog seed group"}, tenant_id())

    assert {:ok, agent} =
             Salix.Control.InitialAgentSeeds.materialize_slot(
               group["group_id"],
               "catalog-worker",
               tenant_id()
             )

    assert agent["model"] == seed["model"]
    assert {:ok, %{"model" => "gpt-5.5"}, :pinned} = SalixAgent.AgentModel.resolve(agent)

    assert {:error, {:bad_request, "template_id is not supported; give model"}} =
             Salix.Control.InitialAgentSeeds.put(
               "legacy",
               %{"template_id" => "tmpl-legacy"},
               tenant_id()
             )
  end

  test "editing a slot loads its current values and saves changes" do
    slot = "edit-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _} =
      Salix.Control.InitialAgentSeeds.put(
        slot,
        %{"model" => %{"kind" => "catalog", "model" => "gpt-5.5"}, "display_name" => "Before"},
        tenant_id()
      )

    {:ok, view, html} = live(authed_conn(), "/dash/initial-agents/#{slot}")
    assert html =~ "Before"

    view
    |> form("form[phx-submit=save]", %{
      "display_name" => "After",
      "model" => "",
      "enabled" => "true",
      "sort_order" => "5"
    })
    |> render_submit()

    {:ok, updated} = Salix.Control.InitialAgentSeeds.get(slot, tenant_id())
    assert updated["display_name"] == "After"
    assert updated["sort_order"] == 5
    # The empty option follows the platform model of the role.
    assert updated["model"] == nil
  end

  test "index deletes a slot" do
    slot = "del-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _} =
      Salix.Control.InitialAgentSeeds.put(
        slot,
        %{"display_name" => "Delete Me"},
        tenant_id()
      )

    {:ok, view, html} = live(authed_conn(), "/dash/initial-agents")
    assert html =~ "Delete Me"
    assert html =~ slot

    html = render_click(view, "delete", %{"slot" => slot})
    refute html =~ "Delete Me"
    assert {:error, :not_found} = Salix.Control.InitialAgentSeeds.get(slot, tenant_id())
  end
end
