defmodule BridgeForTeamsWeb.Dashboard.InformationFlowLiveTest do
  @moduledoc """
  LiveView tests for `/orgs/:org/information-flow`
  (`docs/verification.md` §3.6, §10).

  Two things matter here and neither is about markup: that a write reaches
  Salix with the org's own group id, and that turning the check on is a
  deliberate act the page describes honestly. The Salix seam is scripted, so
  what is asserted is what actually crossed it.

  These swap the global `:salix_client` app env, so they run serially.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Projects

  defmodule Stub do
    @moduledoc false
    use Agent

    def start_link(responses),
      do: Agent.start_link(fn -> %{responses: responses, calls: []} end, name: __MODULE__)

    def call(key, default) do
      Agent.get_and_update(__MODULE__, fn state ->
        {Map.get(state.responses, key, default), %{state | calls: [key | state.calls]}}
      end)
    end

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  end

  defmodule Client do
    @moduledoc """
    Overrides the information-flow calls; everything else falls through to the
    real client so the dashboard chrome still renders under the swap.
    """
    alias BridgeForTeamsWeb.Dashboard.InformationFlowLiveTest.Stub

    @overridden [
      ifc_overview: 2,
      ifc_put_scope_label: 5,
      ifc_delete_scope_label: 4,
      ifc_put_tag_clearance: 5,
      ifc_delete_tag_clearance: 5,
      ifc_put_placement_override: 5,
      update_group: 3
    ]

    for {name, arity} <- BridgeForTeams.Salix.Client.behaviour_info(:callbacks),
        {name, arity} not in @overridden do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: apply(BridgeForTeams.Salix.Erpc, unquote(name), unquote(args))
    end

    def ifc_overview(_tenant_id, group_id),
      do: Stub.call({:overview, group_id}, {:ok, empty_overview(group_id)})

    def ifc_put_scope_label(_tenant, group_id, connect_id, scope_id, attrs),
      do: Stub.call({:put_scope_label, group_id, connect_id, scope_id, attrs}, {:ok, :ok})

    def ifc_delete_scope_label(_tenant, group_id, connect_id, scope_id),
      do: Stub.call({:delete_scope_label, group_id, connect_id, scope_id}, {:ok, :ok})

    def ifc_put_tag_clearance(_tenant, group_id, connect_id, tag, user_id),
      do: Stub.call({:put_clearance, group_id, connect_id, tag, user_id}, {:ok, :ok})

    def ifc_delete_tag_clearance(_tenant, group_id, connect_id, tag, principal_key),
      do: Stub.call({:delete_clearance, group_id, connect_id, tag, principal_key}, {:ok, :ok})

    def ifc_put_placement_override(_tenant, group_id, connect_id, user_id, placement),
      do: Stub.call({:put_placement, group_id, connect_id, user_id, placement}, {:ok, :ok})

    # Same argument order as the behaviour and `BridgeForTeams.Salix.Erpc`:
    # a stub that takes them in another order lets a caller that swaps them
    # pass here and fail against Salix.
    def update_group(group_id, tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs),
      do: Stub.call({:update_group, group_id, attrs}, {:ok, %{}})

    def empty_overview(group_id) do
      %{
        "group_id" => group_id,
        "mode" => "off",
        "modes" => ~w(off audit enforce),
        "language" => "zh",
        "languages" => ~w(zh en),
        "audience_modes" => ~w(space members),
        "connects" => []
      }
    end
  end

  setup %{conn: conn} do
    %{conn: conn, org: org, user: user} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Bridge", "slug" => "bridge-#{unique()}"})

    %{conn: conn, org: org, user: user, project: project}
  end

  defp use_stub(responses) do
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    start_supervised!({Stub, responses})
    Application.put_env(:bridge_for_teams_core, :salix_client, Client)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)
    end)
  end

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  defp overview(group_id, overrides) do
    Map.merge(Client.empty_overview(group_id), overrides)
  end

  defp connect(overrides \\ %{}) do
    Map.merge(
      %{
        "connect_id" => "cnx1",
        "provider" => "slack",
        "name" => "Acme",
        "available" => true,
        "scopes" => [],
        "clearances" => [],
        "principals" => []
      },
      overrides
    )
  end

  describe "who may open it" do
    test "a member is denied without being told the page exists", %{conn: conn, org: org} do
      use_stub(%{})
      %{conn: member_conn} = register_and_log_in_user(%{conn: conn})

      assert {:error, {:redirect, %{to: "/orgs"}}} =
               live(member_conn, ~p"/orgs/#{org.slug}/information-flow")
    end
  end

  describe "the mode" do
    test "says plainly that nothing is checked while it is off", %{
      conn: conn,
      org: org,
      project: project
    } do
      use_stub(%{{:overview, project.salix_group_id} => {:ok, Client.empty_overview("g")}})

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/information-flow")

      assert html =~ "Nothing on this page has any effect while checking is off"
    end

    test "turning on enforce writes it through the group control API", %{
      conn: conn,
      org: org,
      project: project
    } do
      use_stub(%{{:overview, project.salix_group_id} => {:ok, Client.empty_overview("g")}})

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/information-flow")

      view
      |> element("form[phx-change='set-mode']")
      |> render_change(%{"mode" => "enforce"})

      assert {:update_group, group_id, %{"ifc" => %{"mode" => "enforce"}}} =
               Enum.find(Stub.calls(), &match?({:update_group, _, _}, &1))

      # The group id that crossed the seam is this org's, not anything the
      # form supplied.
      assert group_id == project.salix_group_id
    end

    test "an enforcing Group says what it is doing", %{
      conn: conn,
      org: org,
      project: project
    } do
      use_stub(%{
        {:overview, project.salix_group_id} =>
          {:ok, overview(project.salix_group_id, %{"mode" => "enforce"})}
      })

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/information-flow")

      assert html =~ "refusing to carry information to people who could not already see it"
    end

    test "the language the assistant explains itself in is set here", %{
      conn: conn,
      org: org,
      project: project
    } do
      use_stub(%{{:overview, project.salix_group_id} => {:ok, Client.empty_overview("g")}})

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/information-flow")

      view
      |> element("form[phx-change='set-language']")
      |> render_change(%{"language" => "en"})

      # A settings write, not a mode write: the group control API merges it, so
      # the operator who changes the language does not reset the mode from a
      # form that never showed it.
      assert {:update_group, group_id, %{"ifc" => %{"language" => "en"}} = attrs} =
               Enum.find(Stub.calls(), &match?({:update_group, _, _}, &1))

      refute Map.has_key?(attrs["ifc"], "mode")
      assert group_id == project.salix_group_id
    end
  end

  describe "classifying a conversation" do
    test "sends the tags, audience and sealed flag as the operator set them", %{
      conn: conn,
      org: org,
      project: project
    } do
      scopes = [
        %{
          "scope_id" => "C_LEGAL",
          "kind" => "room",
          "display_name" => "legal",
          "observed_at" => "2026-09-08T00:00:00Z",
          "members_complete" => true,
          "tags" => [],
          "audience_mode" => "space",
          "sealed" => false,
          "classified" => false
        }
      ]

      use_stub(%{
        {:overview, project.salix_group_id} =>
          {:ok,
           overview(project.salix_group_id, %{
             "mode" => "audit",
             "connects" => [connect(%{"scopes" => scopes})]
           })}
      })

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/information-flow")

      # An unclassified conversation is shown as being on its defaults, not as
      # though someone had configured it.
      assert html =~ "legal"
      assert html =~ "private channel"

      view
      |> element("form[phx-submit='classify']")
      |> render_submit(%{
        "connect" => "cnx1",
        "scope" => "C_LEGAL",
        "tags" => "counsel, board",
        "audience_mode" => "members",
        "sealed" => "true"
      })

      assert {:put_scope_label, group_id, "cnx1", "C_LEGAL", attrs} =
               Enum.find(Stub.calls(), &match?({:put_scope_label, _, _, _, _}, &1))

      assert group_id == project.salix_group_id
      assert attrs["tags"] == ["counsel", "board"]
      assert attrs["audience_mode"] == "members"
      assert attrs["sealed"] == true
    end
  end

  describe "clearances" do
    test "granting one names the tag and the provider user", %{
      conn: conn,
      org: org,
      project: project
    } do
      use_stub(%{
        {:overview, project.salix_group_id} =>
          {:ok, overview(project.salix_group_id, %{"mode" => "audit", "connects" => [connect()]})}
      })

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/information-flow")

      view
      |> element("form[phx-submit='clear-principal']")
      |> render_submit(%{"connect" => "cnx1", "tag" => "counsel", "user" => "U01ABC"})

      assert {:put_clearance, group_id, "cnx1", "counsel", "U01ABC"} =
               Enum.find(Stub.calls(), &match?({:put_clearance, _, _, _, _}, &1))

      assert group_id == project.salix_group_id
    end

    test "an existing clearance shows the person, not the encoded principal", %{
      conn: conn,
      org: org,
      project: project
    } do
      clearances = [%{"tag" => "counsel", "principals" => ["provider_user|cnx1|U01ABC"]}]

      use_stub(%{
        {:overview, project.salix_group_id} =>
          {:ok,
           overview(project.salix_group_id, %{
             "mode" => "audit",
             "connects" => [connect(%{"clearances" => clearances})]
           })}
      })

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/information-flow")

      # Shown as the person. The encoded key is still what the withdraw button
      # sends back, because that is what the store is keyed by — but it is an
      # attribute, never something the operator has to read.
      assert html =~ ~s(phx-value-principal="provider_user|cnx1|U01ABC")
      refute html =~ ">\n                provider_user|cnx1|U01ABC"
      assert html =~ "U01ABC"
    end
  end

  describe "placements" do
    test "shows the provider's answer beside the override, and can clear it", %{
      conn: conn,
      org: org,
      project: project
    } do
      principals = [
        %{
          "user_id" => "U_GUEST",
          "placement_observed" => "external",
          "placement_override" => "internal"
        }
      ]

      use_stub(%{
        {:overview, project.salix_group_id} =>
          {:ok,
           overview(project.salix_group_id, %{
             "mode" => "audit",
             "connects" => [connect(%{"principals" => principals})]
           })}
      })

      {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/information-flow")

      assert html =~ "Provider says: outside"

      view
      |> element("form[phx-change='set-placement']")
      |> render_change(%{"connect" => "cnx1", "user" => "U_GUEST", "placement" => ""})

      # A blank placement drops the override rather than writing an empty one.
      assert {:put_placement, _group, "cnx1", "U_GUEST", nil} =
               Enum.find(Stub.calls(), &match?({:put_placement, _, _, _, _}, &1))
    end
  end

  describe "when Salix cannot answer" do
    test "the page says so instead of rendering empty settings", %{
      conn: conn,
      org: org,
      project: project
    } do
      use_stub(%{{:overview, project.salix_group_id} => {:error, :unavailable}})

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/information-flow")

      assert html =~ "could not be read just now"
      assert html =~ "Nothing has changed"
    end

    test "one unavailable connect degrades one card", %{
      conn: conn,
      org: org,
      project: project
    } do
      use_stub(%{
        {:overview, project.salix_group_id} =>
          {:ok,
           overview(project.salix_group_id, %{
             "mode" => "audit",
             "connects" => [connect(%{"available" => false, "name" => "Broken"})]
           })}
      })

      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/information-flow")

      assert html =~ "Broken"
      assert html =~ "could not be read just now"
    end
  end
end
