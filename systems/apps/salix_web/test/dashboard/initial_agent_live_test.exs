defmodule SalixWeb.Dashboard.InitialAgentLiveTest do
  @moduledoc "Initial-agent slot list + create/edit via LiveView."
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SalixWeb.DashboardEndpoint

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Template dashboard test"})
    Process.put(:template_dashboard_tenant, tenant["tenant_id"])
    :ok
  end

  defp tenant_id, do: Process.get(:template_dashboard_tenant)

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  defp template(name) do
    {:ok, t} = SalixAgent.Templates.create(%{"name" => name, "model" => "gpt-test"})
    t
  end

  @tag :private_template
  test "initial Agent seed selects and materializes a private template in its tenant" do
    {:ok, private} =
      SalixAgent.Templates.create_private(
        %{"name" => "Private seed model", "model" => "gpt-seed"},
        tenant_id()
      )

    {:ok, foreign} =
      SalixAgent.Templates.create_private(
        %{"name" => "Foreign seed model", "model" => "gpt-foreign"},
        SalixStore.Ids.new_tenant_id()
      )

    {:ok, view, html} = live(authed_conn(), "/dash/initial-agents/new")
    assert html =~ private["name"]
    refute html =~ foreign["name"]

    {:ok, _, _} =
      view
      |> form("form[phx-submit=save]", %{
        "slot" => "private-worker",
        "display_name" => "Private seeded worker",
        "template_id" => private["template_id"],
        "enabled" => "true"
      })
      |> render_submit()
      |> follow_redirect(authed_conn())

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Private seed group"}, tenant_id())

    assert {:ok, agent} =
             Salix.Control.InitialAgentSeeds.materialize_slot(
               group["group_id"],
               "private-worker",
               tenant_id()
             )

    assert agent["template_id"] == private["template_id"]
    assert {:ok, llm} = SalixAgent.Templates.resolve_llm_for_agent(agent["agent_id"])
    assert llm["model"] == "gpt-seed"

    assert {:error, {:bad_request, "template not found"}} =
             Salix.Control.InitialAgentSeeds.put(
               "foreign",
               %{"template_id" => foreign["template_id"]},
               tenant_id()
             )
  end

  test "create an initial-agent slot via the new form" do
    t = template("IA New Template-#{System.unique_integer([:positive])}")
    slot = "main-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(authed_conn(), "/dash/initial-agents/new")

    {:ok, _edit_view, html} =
      view
      |> form("form[phx-submit=save]", %{
        "slot" => slot,
        "display_name" => "Bridge Worker",
        "template_id" => t["template_id"],
        "is_default" => "true",
        "enabled" => "true",
        "sort_order" => "0"
      })
      |> render_submit()
      |> follow_redirect(authed_conn())

    assert html =~ "Bridge Worker"
    assert html =~ slot
  end

  test "index lists configured slots" do
    t = template("IA List Template-#{System.unique_integer([:positive])}")
    slot = "router-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Salix.Control.InitialAgentSeeds.put(
        slot,
        %{
          "template_id" => t["template_id"],
          "display_name" => "Listed Slot",
          "is_router" => true
        },
        tenant_id()
      )

    {:ok, _view, html} = live(authed_conn(), "/dash/initial-agents")
    assert html =~ "Listed Slot"
    assert html =~ slot
  end

  test "editing a slot loads its current values and saves changes" do
    t = template("IA Edit Template-#{System.unique_integer([:positive])}")
    slot = "edit-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Salix.Control.InitialAgentSeeds.put(
        slot,
        %{"template_id" => t["template_id"], "display_name" => "Before"},
        tenant_id()
      )

    {:ok, view, html} = live(authed_conn(), "/dash/initial-agents/#{slot}")
    assert html =~ "Before"

    view
    |> form("form[phx-submit=save]", %{
      "display_name" => "After",
      "template_id" => t["template_id"],
      "enabled" => "true",
      "sort_order" => "5"
    })
    |> render_submit()

    {:ok, updated} = Salix.Control.InitialAgentSeeds.get(slot, tenant_id())
    assert updated["display_name"] == "After"
    assert updated["sort_order"] == 5
  end

  test "index deletes a slot" do
    t = template("IA Del Template-#{System.unique_integer([:positive])}")
    slot = "del-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Salix.Control.InitialAgentSeeds.put(
        slot,
        %{"template_id" => t["template_id"], "display_name" => "Delete Me"},
        tenant_id()
      )

    {:ok, view, html} = live(authed_conn(), "/dash/initial-agents")
    assert html =~ "Delete Me"

    html = render_click(view, "delete", %{"slot" => slot})
    refute html =~ "Delete Me"
    assert {:error, :not_found} = Salix.Control.InitialAgentSeeds.get(slot, tenant_id())
  end

  test "surfaces a validation error for an invalid default/router combination" do
    t = template("IA Bad Template-#{System.unique_integer([:positive])}")
    slot = "bad-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(authed_conn(), "/dash/initial-agents/new")

    html =
      view
      |> form("form[phx-submit=save]", %{
        "slot" => slot,
        "template_id" => t["template_id"],
        "is_default" => "true",
        "is_router" => "true",
        "enabled" => "true",
        "sort_order" => "0"
      })
      |> render_submit()

    assert html =~ "default initial agent role must be worker"
  end
end
