defmodule BridgeForTeamsWeb.DashboardAPITriageTest do
  @moduledoc """
  The Slack triage API behind the React pages at `/orgs/:org/triage`,
  `/triage/timeline` and `/triage/knowledge`: the Agent roster and its Slack
  sources, monitoring and channel writes with their audit rows, AI evaluation
  status, the Worker for Triage, the Timeline page and its batch details,
  audited message reveals, the heatmap and Knowledge. Owners and admins only.

  Salix answers come from a scripted client, so these tests swap the global
  `:salix_client` and share the node-local `ReadCache` table: they run
  serially.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Agents, Memberships, Observability, ProjectKnowledge}
  alias BridgeForTeams.Salix.ReadCache

  @obligation "triage-product-" <> String.duplicate("d", 64)

  defmodule Stub do
    @moduledoc "Scripted Salix responses plus a log of the calls that crossed the seam."
    use Agent

    def start_link(responses),
      do: Agent.start_link(fn -> %{responses: responses, calls: []} end, name: __MODULE__)

    def call(key, default) do
      Agent.get_and_update(__MODULE__, fn state ->
        {Map.get(state.responses, key, default), %{state | calls: [key | state.calls]}}
      end)
    end

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def put(key, value), do: Agent.update(__MODULE__, &put_in(&1, [:responses, key], value))
  end

  defmodule TriageClient do
    @moduledoc """
    Overrides the Triage reads and writes; every other `Client` callback goes
    to the real Erpc client, so org, project and Agent reads keep working.
    """
    alias BridgeForTeamsWeb.DashboardAPITriageTest.Stub

    @overridden [
      triage_connect_posture: 2,
      triage_list_slack_channels: 5,
      triage_ring_status: 1,
      triage_product_activity: 4,
      triage_product_heatmap: 3,
      triage_source_presentation: 2,
      triage_processing_detail: 2,
      triage_delegation_task: 5,
      get_group_conversation_with_messages: 3,
      triage_knowledge_context: 4,
      triage_recent_window: 3,
      triage_set_enabled: 4,
      triage_set_channel_enabled: 5,
      triage_provision: 4,
      list_project_knowledge_uses: 2,
      page_group_agents: 3
    ]

    for {name, arity} <- BridgeForTeams.Salix.Client.behaviour_info(:callbacks),
        {name, arity} not in @overridden do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: apply(BridgeForTeams.Salix.Erpc, unquote(name), unquote(args))
    end

    # `{:slow, ms, result}` sleeps outside the Agent, so a fan-out test sees
    # real concurrency.
    def triage_connect_posture(_tenant_id, group_id) do
      case Stub.call({:posture, group_id}, {:ok, []}) do
        {:slow, ms, result} ->
          Process.sleep(ms)
          result

        result ->
          result
      end
    end

    def triage_ring_status(refs) do
      _recorded = Stub.call({:ring_refs, refs}, :recorded)
      reply(Stub.call(:ring, {:error, :unavailable}))
    end

    def triage_processing_detail(group, ref),
      do: reply(Stub.call({:processing_detail, group, ref}, {:error, :unavailable}))

    # Each router-Agent roster read pages every project's Agents once.
    def page_group_agents(tenant_id, group_id, opts) do
      _ = Stub.call({:roster_page, group_id}, :recorded)
      BridgeForTeams.Salix.Erpc.page_group_agents(tenant_id, group_id, opts)
    end

    # `:crash` raises, as a broken Salix client does.
    defp reply(:crash), do: raise("Salix client crashed")
    defp reply(result), do: result

    def triage_source_presentation(_group, refs),
      do: Stub.call({:source_presentation, refs}, Stub.call(:source_presentation, {:ok, %{}}))

    def triage_product_activity(_project_id, _group_id, _agent_id, opts) do
      _ = Stub.call({:activity_opts, opts}, :recorded)
      reply(Stub.call(:product_activity, {:ok, %{outcomes: [], context: []}}))
    end

    def triage_product_heatmap(_project_id, _group_id, _agent_id) do
      _ = Stub.call(:heatmap_read, :recorded)
      Stub.call(:product_heatmap, {:error, :unavailable})
    end

    def triage_delegation_task(project_id, group_id, agent_id, obligation_id, index),
      do:
        Stub.call(
          {:delegation_task, project_id, group_id, agent_id, obligation_id, index},
          {:error, :unavailable}
        )

    def get_group_conversation_with_messages(group_id, conversation_id, opts),
      do: Stub.call({:task_snapshot, group_id, conversation_id, opts}, {:error, :unavailable})

    def triage_knowledge_context(_project_id, _group_id, _agent_id, _opts),
      do: Stub.call(:triage_knowledge, {:ok, %{items: [], complete: true}})

    def triage_list_slack_channels(_tenant_id, group_id, connect_id, cursor, limit),
      do:
        Stub.call(
          {:channels, group_id, connect_id, cursor, limit},
          {:ok, %{channels: [], next_cursor: nil}}
        )

    def triage_recent_window(_namespace, _since_ms, _opts),
      do: Stub.call(:window, {:error, :unavailable})

    def triage_set_enabled(_tenant_id, group_id, connect_id, enabled?),
      do: Stub.call({:set_enabled, group_id, connect_id, enabled?}, :ok)

    def triage_set_channel_enabled(_tenant_id, group_id, connect_id, channel_id, enabled?),
      do: Stub.call({:set_channel_enabled, group_id, connect_id, channel_id, enabled?}, :ok)

    def triage_provision(_tenant_id, group_id, connect_id, channel_id),
      do: Stub.call({:provision, group_id, connect_id, channel_id}, {:ok, %{}})

    def list_project_knowledge_uses(agent_id, _opts),
      do:
        Stub.call(
          {:knowledge_uses, agent_id},
          {:ok,
           %{
             "uses" => [],
             "complete" => true,
             "history_truncated" => false,
             "sessions_scanned" => 0
           }}
        )
  end

  setup %{conn: conn} do
    %{conn: conn, org: org, user: user} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Bridge",
        "slug" => "bridge-#{unique()}"
      })

    router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))
    Process.put(:default_inbound_agent_id, router.salix_agent_id)
    if :ets.whereis(ReadCache) != :undefined, do: :ets.delete_all_objects(ReadCache)
    %{conn: conn, org: org, user: user, project: project, router: router}
  end

  describe "access" do
    test "only owners and admins reach Slack triage; members get the non-member 404",
         %{conn: conn, org: org, project: project, router: router} do
      use_stub(%{{:posture, project.salix_group_id} => {:ok, [posture("c-1")]}})
      assert %{"agents" => [_]} = conn |> get(triage_path(org)) |> json_response(200) |> data()

      member = user_fixture(email: "triage-member-#{unique()}@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
      member_conn = log_in_user(build_conn(), member)

      for path <- [
            triage_path(org),
            triage_path(org, "/activity", agent: router.id),
            triage_path(org, "/knowledge", agent: router.id)
          ] do
        assert %{"error" => %{"code" => "org_not_found"}} =
                 member_conn |> get(path) |> json_response(404)
      end

      assert %{"error" => %{"code" => "org_not_found"}} =
               member_conn
               |> put(triage_path(org, "/sources/c-1"), %{"agent" => router.id, "enabled" => true})
               |> json_response(404)

      refute Enum.any?(Stub.calls(), &match?({:set_enabled, _, _, _}, &1))

      assert %{"error" => %{"code" => "agent_not_found"}} =
               conn
               |> get(triage_path(org, "/activity", agent: Ecto.UUID.generate()))
               |> json_response(404)
    end

    test "the React pages, and the retired Context, Memory and Raw data addresses, are served",
         %{conn: conn, org: org} do
      for page <- ["", "/timeline", "/knowledge", "/context", "/memory", "/data"] do
        assert html_response(get(conn, "/orgs/#{org.slug}/triage#{page}"), 200) =~
                 ~s(<div id="root">)
      end
    end

    test "the LiveView sidebar links Slack triage for owners and not for members",
         %{conn: conn, org: org, project: project} do
      {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")
      assert html =~ ~s(href="/orgs/#{org.slug}/triage")

      member = user_fixture(email: "triage-nav-member-#{unique()}@example.com")
      {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
      {:ok, _} = Memberships.put_project_member(project.id, member.id, "user")

      {:ok, _view, html} =
        build_conn()
        |> log_in_user(member)
        |> live(~p"/orgs/#{org.slug}/projects/#{project.id}/plugins")

      refute html =~ "/orgs/#{org.slug}/triage"
    end

    test "writes need the page's CSRF token", %{
      conn: conn,
      org: org,
      project: project,
      router: router
    } do
      use_stub(%{{:posture, project.salix_group_id} => {:ok, [posture("c-1")]}})
      conn = get(conn, ~p"/orgs/#{org.slug}/triage")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)
      body = %{"agent" => router.id, "enabled" => true}

      assert_error_sent(403, fn -> put(conn, triage_path(org, "/sources/c-1"), body) end)
      refute Enum.any?(Stub.calls(), &match?({:set_enabled, _, _, _}, &1))

      assert %{"ok" => true} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> put(triage_path(org, "/sources/c-1"), body)
               |> json_response(200)
    end
  end

  describe "overview" do
    test "lists every router Agent with its exact Slack sources and public names",
         %{conn: conn, org: org, project: project, router: current} do
      {:ok, current} = Agents.update_agent(current, %{"name" => "Support Lead"})
      previous = insert_router_agent(project)

      use_stub(%{
        {:posture, project.salix_group_id} =>
          {:ok,
           [
             posture("connect-z", %{
               app_name: "Zulu Private",
               bot_username: "aaa_private",
               workspace_name: "Peng's Slack",
               configured_channels: [
                 %{channel_id: "C777", channel_name: "triage-room", enabled: true},
                 %{channel_id: "C888", channel_name: "product", enabled: false}
               ]
             }),
             posture("connect-b", %{
               app_name: "Bridge For Teams (Staging)",
               bot_username: "bridge_for_teams_stag",
               workspace_name: "Comma",
               triage_enabled: true
             }),
             posture("secret-connect-id", %{
               inbound_agent_id: "other-agent",
               bot_username: nil,
               workspace_name: nil
             })
           ]}
      })

      data = conn |> get(triage_path(org)) |> json_response(200) |> data()
      assert data["agents_status"] == "ok"
      assert data["has_sources"]
      agents = Map.new(data["agents"], &{&1["id"], &1})

      assert %{"name" => "Support Lead", "project_name" => "Bridge", "state" => "ready"} =
               agents[current.id]

      # Public bot names order the sources, not usernames or connect ids.
      assert [
               %{
                 "connect_id" => "connect-b",
                 "bot_name" => "Bridge For Teams (Staging)",
                 "bot_username" => "bridge_for_teams_stag",
                 "enabled" => true
               },
               %{"connect_id" => "connect-z", "channels" => channels}
             ] = agents[current.id]["sources"]

      assert channels == [
               %{"id" => "C777", "name" => "triage-room", "enabled" => true},
               %{"id" => "C888", "name" => "product", "enabled" => false}
             ]

      # The internal "Router" name is not an identity; it goes by its project.
      assert %{"name" => "Bridge", "state" => "empty", "sources" => []} = agents[previous.id]
      refute Jason.encode!(data) =~ "noise"
    end

    test "an unreadable project is reported, not shown as an Agent without Slack",
         %{conn: conn, org: org, project: project, router: router} do
      use_stub(%{{:posture, project.salix_group_id} => {:error, :unavailable}})
      data = conn |> get(triage_path(org)) |> json_response(200) |> data()

      assert data["unavailable_projects"] == ["Bridge"]
      assert [%{"id" => id, "state" => "unavailable", "sources" => []}] = data["agents"]
      assert id == router.id
    end

    test "one request builds the org scope once and a Salix outage costs one timeout",
         %{conn: conn, org: org, project: project} do
      others = for i <- 1..23, do: sick_project(org, "Down #{i}")
      groups = [project.salix_group_id | Enum.map(others, & &1.salix_group_id)]
      use_stub(Map.new(groups, &{{:posture, &1}, {:slow, 30_000, {:error, :unavailable}}}))

      {elapsed_us, conn} = :timer.tc(fn -> get(conn, triage_path(org)) end)
      data = conn |> json_response(200) |> data()

      # 24 sequential 30s reads would be twelve minutes; the bound is one
      # per-group timeout and one concurrency window of reads.
      assert div(elapsed_us, 1000) < 15_000
      assert posture_calls() <= 16
      assert data["unavailable_projects"] != []
    end
  end

  describe "AI evaluation" do
    test "readiness is separate from monitoring and refresh reads it again",
         %{conn: conn, org: org, router: router} do
      use_stub(%{:ring => {:ok, ring(:unavailable)}})
      path = triage_path(org, "/evaluation", agent: router.id)

      assert %{"readiness" => "unavailable", "checked_at_ms" => checked} =
               conn |> get(path) |> json_response(200) |> data()

      assert is_integer(checked)

      assert Enum.any?(
               Stub.calls(),
               &match?(
                 {:ring_refs, %{evaluation_agent_id: id}} when id == router.salix_agent_id,
                 &1
               )
             )

      Stub.put(:ring, {:ok, ring(:ready)})
      # Cached for its TTL, until an explicit refresh.
      assert %{"readiness" => "unavailable"} = conn |> get(path) |> json_response(200) |> data()

      assert %{"readiness" => "ready"} =
               conn
               |> get(triage_path(org, "/evaluation", agent: router.id, refresh: "1"))
               |> json_response(200)
               |> data()
    end

    test "an incomplete or old evaluator answer is unknown, never unavailable",
         %{conn: conn, org: org, router: router} do
      for ring <- [ring(:unknown), Map.delete(ring(:ready), :evaluation_readiness)] do
        use_stub(%{:ring => {:ok, ring}})

        assert %{"readiness" => "unknown"} =
                 conn
                 |> get(triage_path(org, "/evaluation", agent: router.id, refresh: "1"))
                 |> json_response(200)
                 |> data()

        stop_supervised!(Stub)
      end
    end
  end

  describe "monitoring and channels" do
    test "turning a source on and off reaches the seam once and is audited",
         %{conn: conn, org: org, user: user, project: project, router: router} do
      use_stub(%{{:posture, project.salix_group_id} => {:ok, [posture("c-1")]}})

      assert %{"notice" => "Triage monitoring enabled for this assistant."} =
               conn
               |> put(triage_path(org, "/sources/c-1"), %{"agent" => router.id, "enabled" => true})
               |> json_response(200)
               |> data()

      assert {:set_enabled, project.salix_group_id, "c-1", true} in Stub.calls()

      assert [audit] =
               Observability.list_audit_logs(org.id, action: "integration.slack.triage_enabled")

      assert {audit.result, audit.actor_user_id, audit.resource_id} == {"ok", user.id, "c-1"}

      Stub.put(
        {:posture, project.salix_group_id},
        {:ok, [posture("c-1", %{triage_enabled: true})]}
      )

      :ets.delete_all_objects(ReadCache)

      assert %{"notice" => notice} =
               conn
               |> put(triage_path(org, "/sources/c-1"), %{
                 "agent" => router.id,
                 "enabled" => false
               })
               |> json_response(200)
               |> data()

      assert notice =~ "Explicit human @bot commands remain available"
      assert {:set_enabled, project.salix_group_id, "c-1", false} in Stub.calls()
    end

    test "enabling needs a ready source with a channel; disabling an unreadable one stays safe",
         %{conn: conn, org: org, project: project, router: router} do
      use_stub(%{
        {:posture, project.salix_group_id} =>
          {:ok,
           [
             posture("c-empty", %{
               configured_channels: [],
               channel_controls_available?: false,
               authority_valid?: false
             }),
             posture("c-unreadable", %{
               triage_enabled: true,
               posture_complete?: false,
               authority_valid?: false
             })
           ]}
      })

      for body <- [%{"enabled" => true}, %{"enabled" => "delete"}] do
        assert %{"error" => %{"message" => message}} =
                 conn
                 |> put(triage_path(org, "/sources/c-empty"), Map.put(body, "agent", router.id))
                 |> json_response(422)

        assert message == "Only organization owners and admins can change Triage switches."
      end

      refute Enum.any?(Stub.calls(), &match?({:set_enabled, _, "c-empty", _}, &1))

      assert %{"ok" => true} =
               conn
               |> put(triage_path(org, "/sources/c-unreadable"), %{
                 "agent" => router.id,
                 "enabled" => false
               })
               |> json_response(200)

      assert {:set_enabled, project.salix_group_id, "c-unreadable", false} in Stub.calls()
    end

    test "a write that times out says the result is unconfirmed",
         %{conn: conn, org: org, project: project, router: router} do
      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        {:set_enabled, project.salix_group_id, "c-1", true} => {:error, :timeout}
      })

      assert %{"error" => %{"code" => "unconfirmed", "message" => message}} =
               conn
               |> put(triage_path(org, "/sources/c-1"), %{"agent" => router.id, "enabled" => true})
               |> json_response(504)

      assert message =~ "unconfirmed"
      refute message =~ "could not be changed"
    end

    test "a channel pauses alone, and only while channel controls are complete",
         %{conn: conn, org: org, user: user, project: project, router: router} do
      channels = [
        %{channel_id: "C123", channel_name: "triage-room", enabled: true},
        %{channel_id: "C456", channel_name: "product", enabled: true}
      ]

      use_stub(%{
        {:posture, project.salix_group_id} =>
          {:ok,
           [
             posture("c-1", %{triage_enabled: true, configured_channels: channels}),
             posture("c-2", %{configured_channels: channels, channel_scope_complete?: false})
           ]}
      })

      pause = %{"agent" => router.id, "enabled" => false}

      assert %{"notice" => "This channel is paused. Other configured channels are unchanged."} =
               conn
               |> put(triage_path(org, "/sources/c-1/channels/C123"), pause)
               |> json_response(200)
               |> data()

      assert [{:set_channel_enabled, _, "c-1", "C123", false}] =
               Enum.filter(Stub.calls(), &match?({:set_channel_enabled, _, _, _, _}, &1))

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "integration.slack.triage_channel_paused"
               )

      assert {audit.actor_user_id, audit.metadata["channel_id"]} == {user.id, "C123"}

      for path <- ["/sources/c-2/channels/C123", "/sources/c-1/channels/C-UNKNOWN"] do
        assert conn |> put(triage_path(org, path), pause) |> json_response(422)
      end

      assert length(Enum.filter(Stub.calls(), &match?({:set_channel_enabled, _, _, _, _}, &1))) ==
               1
    end

    test "channels are added from bounded Slack pages, each through one audited write",
         %{conn: conn, org: org, project: project, router: router} do
      group = project.salix_group_id

      use_stub(%{
        {:posture, group} => {:ok, [posture("c-1", %{configured_channels: []})]},
        {:channels, group, "c-1", nil, 100} =>
          {:ok,
           %{
             channels: [%{id: "C999", name: "triage-room", private?: false}],
             next_cursor: "page-2"
           }},
        {:channels, group, "c-1", "page-2", 100} =>
          {:ok, %{channels: [%{id: "C998", name: "product", private?: true}], next_cursor: nil}}
      })

      assert %{
               "channels" => [%{"id" => "C999", "name" => "triage-room", "private" => false}],
               "next_cursor" => "page-2"
             } =
               conn
               |> get(triage_path(org, "/channels", agent: router.id, connect: "c-1"))
               |> json_response(200)
               |> data()

      assert %{"channels" => [%{"id" => "C998", "private" => true}], "next_cursor" => nil} =
               conn
               |> get(
                 triage_path(org, "/channels", agent: router.id, connect: "c-1", cursor: "page-2")
               )
               |> json_response(200)
               |> data()

      add = fn ids ->
        post(conn, triage_path(org, "/sources/c-1/channels"), %{
          "agent" => router.id,
          "channel_ids" => ids
        })
      end

      # Blank, malformed and oversized requests never open the one-way door.
      for ids <- [["   "], %{"not" => "a list"}, Enum.map(1..21, &"C#{&1}")] do
        assert %{"error" => %{"message" => "Choose one or more Slack channels from the list."}} =
                 ids |> add.() |> json_response(422)
      end

      refute Enum.any?(Stub.calls(), &match?({:provision, _, _, _}, &1))

      assert %{"notice" => "2 Slack channels added."} =
               ["C999", "C998", "C999"] |> add.() |> json_response(200) |> data()

      assert [{:provision, ^group, "c-1", "C999"}, {:provision, ^group, "c-1", "C998"}] =
               Enum.filter(Stub.calls(), &match?({:provision, _, _, _}, &1))
    end

    test "a failed Slack channel read is unavailable, not an empty list",
         %{conn: conn, org: org, project: project, router: router} do
      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        {:channels, project.salix_group_id, "c-1", nil, 100} => {:error, :unavailable}
      })

      assert %{"error" => %{"message" => message}} =
               conn
               |> get(triage_path(org, "/channels", agent: router.id, connect: "c-1"))
               |> json_response(503)

      assert message =~ "channel list cannot be refreshed right now"
    end

    test "writes reach only the selected Agent's own sources in this org",
         %{conn: conn, org: org, project: project, router: router} do
      other = insert_router_agent(project)
      foreign_router = foreign_router_agent()

      use_stub(%{
        {:posture, project.salix_group_id} =>
          {:ok, [posture("c-1"), posture("c-2", %{inbound_agent_id: other.salix_agent_id})]}
      })

      writes = fn agent, connect ->
        [
          put(conn, triage_path(org, "/sources/#{connect}"), %{
            "agent" => agent.id,
            "enabled" => true
          }),
          put(conn, triage_path(org, "/sources/#{connect}/channels/C123"), %{
            "agent" => agent.id,
            "enabled" => false
          }),
          post(conn, triage_path(org, "/sources/#{connect}/channels"), %{
            "agent" => agent.id,
            "channel_ids" => ["C999"]
          })
        ]
      end

      # Another Agent's source in the same org.
      for response <- writes.(router, "c-2") do
        assert %{"error" => %{"code" => "source_not_found"}} = json_response(response, 404)
      end

      # An Agent of another org, even with this org's source.
      for response <- writes.(foreign_router, "c-1") do
        assert %{"error" => %{"code" => "agent_not_found"}} = json_response(response, 404)
      end

      refute Enum.any?(
               Stub.calls(),
               &match?(
                 {tag, _, _, _} when tag in [:set_enabled, :provision],
                 &1
               )
             )

      refute Enum.any?(Stub.calls(), &match?({:set_channel_enabled, _, _, _, _}, &1))
    end
  end

  describe "Worker for Triage" do
    test "an administrator selects the Worker through an audited, revision-checked save",
         %{conn: conn, org: org, project: project, router: router, user: user} do
      workers =
        for name <- ["First investigator", "Second investigator"] do
          {:ok, worker} =
            BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
              project.id,
              %{
                role: "worker",
                name: name
              }
            )

          worker
        end

      [first, second] = workers
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "admin")
      use_stub(%{})

      view =
        conn
        |> get(triage_path(org, "/worker", agent: router.id, query: "investigator"))
        |> json_response(200)
        |> data()

      assert %{"can_manage" => true, "worker_id" => nil, "revision" => revision} = view
      assert first.salix_agent_id in Enum.map(view["candidates"], & &1["id"])

      save = fn worker, revision ->
        put(conn, triage_path(org, "/worker"), %{
          "agent" => router.id,
          "worker_id" => worker,
          "revision" => revision
        })
      end

      assert %{"notice" => "Triage Worker updated. Existing assignments keep their Worker."} =
               first.salix_agent_id |> save.(revision) |> json_response(200) |> data()

      assert {:ok, binding} = Salix.Bindings.TriageWorker.get(project.salix_group_id)

      assert {binding["worker_agent_id"], binding["actor_user_id"]} ==
               {first.salix_agent_id, user.id}

      assert [audit] =
               Observability.list_audit_logs(org.id,
                 action: "integration.slack.triage_worker_change_attempted"
               )

      assert audit.request_id == binding["request_id"]

      # A page that read the old revision cannot overwrite the new choice.
      assert %{"error" => %{"code" => "worker_conflict"}} =
               second.salix_agent_id |> save.(revision) |> json_response(409)

      assert {:ok, %{"worker_agent_id" => kept}} =
               Salix.Bindings.TriageWorker.get(project.salix_group_id)

      assert kept == first.salix_agent_id

      %{"revision" => current, "worker" => %{"name" => "First investigator"}} =
        conn |> get(triage_path(org, "/worker", agent: router.id)) |> json_response(200) |> data()

      assert %{"ok" => true} = second.salix_agent_id |> save.(current) |> json_response(200)

      # A revoked administrator is refused before any mutation.
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      assert nil |> save.(current + 1) |> json_response(404)

      assert {:ok, %{"worker_agent_id" => worker}} =
               Salix.Bindings.TriageWorker.get(project.salix_group_id)

      assert worker == second.salix_agent_id
    end

    test "a Worker change stops before mutation when the audit store is unavailable",
         %{conn: conn, org: org, project: project, router: router} do
      {:ok, worker} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
          role: "worker",
          name: "Investigator"
        })

      use_stub(%{})
      use_failing_audit_writer()

      assert %{"error" => %{"code" => "audit_unavailable"}} =
               conn
               |> put(triage_path(org, "/worker"), %{
                 "agent" => router.id,
                 "worker_id" => worker.salix_agent_id,
                 "revision" => 0
               })
               |> json_response(503)

      assert {:ok, %{"revision" => 0}} = Salix.Bindings.TriageWorker.get(project.salix_group_id)
    end
  end

  describe "Timeline" do
    test "a page lists outcomes and received messages without Slack text or internals",
         %{conn: conn, org: org, project: project, router: router} do
      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        :product_activity => {:ok, activity_page()}
      })

      data =
        conn
        |> get(triage_path(org, "/activity", agent: router.id))
        |> json_response(200)
        |> data()

      body = Jason.encode!(data)

      for private <- [
            "Original <@U123> message",
            "Could someone verify",
            "internal-run",
            "private transport"
          ],
          do: refute(body =~ private)

      assert [
               %{"kind" => "processing", "id" => "receipt-two", "state" => "settled"},
               %{"kind" => "outcome", "id" => "triage-public-event"} = outcome
             ] = data["items"]

      assert %{
               "communication" => %{"kind" => "reply", "text" => "I checked the rollout."},
               "effect" => %{"adapter" => "audit_sink"},
               "messages" => [
                 %{"ref" => "receipt-one", "speaker" => "Peng Xiao", "files" => files}
               ],
               "delegations" => [%{"index" => 0, "status" => "created", "task" => "Check"}],
               "source" => %{
                 "channel_id" => "C123",
                 "url" => "https://app.slack.com/client/T1/C123"
               }
             } = outcome

      assert files == %{
               "total" => 2,
               "truncated" => true,
               "items" => [%{"name" => "transcript.txt", "kind" => "text"}]
             }

      assert data["next_cursor"] == "server-second"
      assert [%{"kind" => "follow_up", "state" => "active"}] = data["follow_ups"]
      refute :ring in Stub.calls()
    end

    test "pages and filters pass server cursors; other pages carry no received messages",
         %{conn: conn, org: org, project: project, router: router} do
      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        :product_activity => {:ok, activity_page()}
      })

      for {params, expected} <- [
            {[kind: "silence"], [kind: "silence"]},
            {[cursor: "server-second"], [cursor: "server-second", kind: "all"]},
            {[channel: "C123", before: "1700000000000"],
             [channel_id: "C123", before_ms: 1_700_000_000_000]},
            {[channel: "C-FORGED", kind: "bogus"], [kind: "all"]}
          ] do
        data =
          conn
          |> get(triage_path(org, "/activity", [agent: router.id] ++ params))
          |> json_response(200)
          |> data()

        {:activity_opts, opts} =
          Stub.calls() |> Enum.filter(&match?({:activity_opts, _}, &1)) |> List.last()

        for {key, value} <- expected, do: assert(opts[key] == value)
        if params[:channel] == "C-FORGED", do: refute(Keyword.has_key?(opts, :channel_id))

        processing? = Enum.any?(data["items"], &(&1["kind"] == "processing"))
        assert processing? == (params[:kind] in [nil, "bogus"] and is_nil(params[:cursor]))
      end
    end

    test "a page costs the same queries whatever its number of outcomes",
         %{conn: conn, org: org, project: project, router: router} do
      page = activity_page()
      [outcome] = page.outcomes
      use_stub(%{{:posture, project.salix_group_id} => {:ok, [posture("c-1")]}})
      path = triage_path(org, "/activity", agent: router.id)

      Stub.put(:product_activity, {:ok, page})
      one = query_count(conn, path)

      many = for i <- 1..20, do: %{outcome | event_ref: "event-#{i}"}
      Stub.put(:product_activity, {:ok, %{page | outcomes: many}})
      assert query_count(conn, path) == one
    end

    test "a reveal is audited per message before the text is returned",
         %{conn: conn, org: org, user: user, project: project, router: router} do
      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        :product_activity => {:ok, activity_page()},
        :source_presentation =>
          {:ok, %{"receipt-two" => %{speaker_label: "Peng", mentions: %{"U123" => "codex-3720"}}}}
      })

      reveal = fn refs ->
        post(conn, triage_path(org, "/reveal"), %{
          "agent" => router.id,
          "refs" => refs,
          "activity" => %{"kind" => "all"}
        })
      end

      assert %{"messages" => messages} =
               ["receipt-two", "receipt-one", "s3://not-on-this-page"]
               |> reveal.()
               |> json_response(200)
               |> data()

      assert Map.keys(messages) |> Enum.sort() == ["receipt-one", "receipt-two"]

      assert %{
               "speaker" => "Peng",
               "parts" => [
                 %{"kind" => "text", "text" => "Original "},
                 %{"kind" => "mention", "text" => "@codex-3720"},
                 %{"kind" => "text", "text" => " message\nsee "},
                 %{
                   "kind" => "link",
                   "url" => "https://github.com/AFK-surf/Comma/pull/1602",
                   "text" => "PR #1602"
                 },
                 %{"kind" => "text", "text" => " "},
                 %{"kind" => "mention", "text" => "@Slack participant"},
                 %{"kind" => "text", "text" => " <javascript:alert(1)|click> <script>"}
               ]
             } = messages["receipt-two"]

      audits =
        Observability.list_audit_logs(org.id, action: "integration.slack.triage_text_revealed")

      assert audits |> Enum.map(& &1.resource_id) |> Enum.sort() == ["receipt-one", "receipt-two"]

      assert Enum.all?(
               audits,
               &(&1.actor_user_id == user.id and &1.metadata["surface"] == "triage_timeline")
             )

      refute Enum.any?(audits, &Map.has_key?(&1.metadata, "text"))

      assert %{"error" => %{"code" => "message_not_found"}} =
               ["s3://not-on-this-page"] |> reveal.() |> json_response(404)

      assert reveal.(Enum.map(1..21, &"r#{&1}")) |> json_response(404)
    end

    test "a reveal reads the Timeline page it was shown on, with numbers from a JSON body",
         %{conn: conn, org: org, project: project, router: router} do
      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        :product_activity => {:ok, activity_page()}
      })

      for {activity, expected} <- [
            {%{"kind" => "all", "channel" => "C123", "before" => 1_700_000_000_000},
             [channel_id: "C123", before_ms: 1_700_000_000_000]},
            {%{"kind" => "all", "before" => 1_700_000_000_000, "cursor" => "server-second"},
             [cursor: "server-second", before_ms: nil]}
          ] do
        body = %{"agent" => router.id, "refs" => ["receipt-one"], "activity" => activity}

        assert %{"messages" => %{"receipt-one" => _}} =
                 conn
                 |> put_req_header("content-type", "application/json")
                 |> post(triage_path(org, "/reveal"), Jason.encode!(body))
                 |> json_response(200)
                 |> data()

        {:activity_opts, opts} =
          Stub.calls() |> Enum.filter(&match?({:activity_opts, _}, &1)) |> List.last()

        for {key, value} <- expected, do: assert(opts[key] == value)
      end
    end

    test "a reveal whose audit row fails returns no text",
         %{conn: conn, org: org, project: project, router: router} do
      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        :product_activity => {:ok, activity_page()}
      })

      use_failing_audit_writer()

      assert %{"error" => %{"message" => message}} =
               conn
               |> post(triage_path(org, "/reveal"), %{
                 "agent" => router.id,
                 "refs" => ["receipt-one"],
                 "activity" => %{"kind" => "all"}
               })
               |> json_response(503)

      assert message =~ "the access record failed to write"
      refute message =~ "Could someone verify"
    end

    test "Knowledge reveals a received message from the last 7 days with its own audit surface",
         %{conn: conn, org: org, project: project, router: router} do
      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        :window => {:ok, window([receipt("c-1", "secret standup text")])}
      })

      assert %{
               "messages" => %{
                 "s3://receipt-c-1" => %{"parts" => [%{"text" => "secret standup text"}]}
               }
             } =
               conn
               |> post(triage_path(org, "/reveal"), %{
                 "agent" => router.id,
                 "refs" => ["s3://receipt-c-1"]
               })
               |> json_response(200)
               |> data()

      assert [%{metadata: %{"surface" => "triage_knowledge"}}] =
               Observability.list_audit_logs(org.id,
                 action: "integration.slack.triage_text_revealed"
               )
    end

    test "Knowledge reveals only messages the selected Agent's own Slack sources received",
         %{conn: conn, org: org, project: project, router: router} do
      other = insert_router_agent(project)

      use_stub(%{
        {:posture, project.salix_group_id} =>
          {:ok, [posture("c-1"), posture("c-2", %{inbound_agent_id: other.salix_agent_id})]},
        :window =>
          {:ok, window([receipt("c-1", "own standup"), receipt("c-2", "other Agent's standup")])}
      })

      reveal = fn agent, ref ->
        post(conn, triage_path(org, "/reveal"), %{"agent" => agent.id, "refs" => [ref]})
      end

      assert %{"error" => %{"code" => "message_not_found"}} =
               router |> reveal.("s3://receipt-c-2") |> json_response(404)

      assert %{"messages" => %{"s3://receipt-c-1" => _}} =
               router |> reveal.("s3://receipt-c-1") |> json_response(200) |> data()

      assert %{"messages" => %{"s3://receipt-c-2" => _}} =
               other |> reveal.("s3://receipt-c-2") |> json_response(200) |> data()

      audits =
        Observability.list_audit_logs(org.id, action: "integration.slack.triage_text_revealed")

      assert audits |> Enum.map(& &1.resource_id) |> Enum.sort() ==
               ["s3://receipt-c-1", "s3://receipt-c-2"]
    end

    test "a crashing Salix client is unavailable, not a server error",
         %{conn: conn, org: org, project: project, router: router} do
      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        :product_activity => :crash,
        :ring => :crash,
        {:processing_detail, project.salix_group_id, "receipt-two"} => :crash
      })

      for path <- [
            triage_path(org, "/activity", agent: router.id),
            triage_path(org, "/processing", agent: router.id, ref: "receipt-two")
          ] do
        assert %{"error" => %{"code" => "runtime_unavailable"}} =
                 conn |> get(path) |> json_response(503)
      end

      assert %{"readiness" => "unknown"} =
               conn
               |> get(triage_path(org, "/evaluation", agent: router.id))
               |> json_response(200)
               |> data()
    end

    test "batch details, delegations and reveals read the Agent roster once",
         %{conn: conn, org: org, project: project, router: router} do
      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        :product_activity => {:ok, activity_page()},
        {:processing_detail, project.salix_group_id, "receipt-two"} =>
          {:ok, %{state: :terminal, diagnostics: %{}}},
        {:delegation_task, project.id, project.salix_group_id, router.id, @obligation, 0} =>
          {:ok, %{"disposition" => "not_created"}}
      })

      # Warm the cached Slack source scope, which is not the roster.
      conn |> get(triage_path(org)) |> json_response(200)

      for request <- [
            &get(&1, triage_path(org, "/processing", agent: router.id, ref: "receipt-two")),
            &get(
              &1,
              triage_path(org, "/delegation", agent: router.id, obligation: @obligation, index: 0)
            ),
            &post(&1, triage_path(org, "/reveal"), %{
              "agent" => router.id,
              "refs" => ["receipt-two"],
              "activity" => %{"kind" => "all"}
            })
          ] do
        before = roster_reads()
        assert conn |> request.() |> json_response(200)
        assert roster_reads() - before == 1
      end
    end

    test "the heatmap is one cached read per Agent", %{
      conn: conn,
      org: org,
      project: project,
      router: router
    } do
      cell = %{
        connect_id: "c-1",
        channel_id: "C123",
        at_ms: 1_000,
        reply: 1,
        reaction: 0,
        silence: 2,
        total: 3
      }

      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        :product_heatmap =>
          {:ok, %{since_ms: 0, bucket_ms: 3_600_000, truncated: false, cells: [cell]}}
      })

      for _ <- 1..2 do
        assert %{
                 "since_ms" => 0,
                 "cells" => [%{"channel_id" => "C123", "total" => 3, "reply" => 1}]
               } =
                 conn
                 |> get(triage_path(org, "/heatmap", agent: router.id))
                 |> json_response(200)
                 |> data()
      end

      assert Enum.count(Stub.calls(), &(&1 == :heatmap_read)) == 1
    end

    test "batch evidence is read for one received message, and a failure keeps it unavailable",
         %{conn: conn, org: org, project: project, router: router} do
      key = {:processing_detail, project.salix_group_id, "receipt-two"}

      use_stub(%{
        key =>
          {:ok,
           %{
             state: :terminal,
             terminal_status: "failed",
             suggested_action: nil,
             diagnostics: %{
               source: %{addressing_kind: "ambient", source_mode: "callback", thread_ts: "1.2"},
               milestones: %{received_at_ms: 1_000, settled_at_ms: 2_500},
               trace_ref: "triage-failed-sample",
               decision_reason: "evaluation_unavailable",
               evaluator: nil
             }
           }}
      })

      path = triage_path(org, "/processing", agent: router.id, ref: "receipt-two")

      assert %{
               "state" => "terminal",
               "terminal_status" => "failed",
               "decision_reason" => "evaluation_unavailable",
               "milestones" => %{"received_at_ms" => 1_000, "settled_at_ms" => 2_500},
               "source" => %{"addressing_kind" => "ambient"},
               "evaluator" => nil
             } = conn |> get(path) |> json_response(200) |> data()

      Stub.put(key, {:error, :unavailable})

      assert %{
               "error" => %{
                 "message" =>
                   "Batch evidence is unavailable. The recorded processing status is still shown."
               }
             } =
               conn |> get(path) |> json_response(503)
    end
  end

  describe "delegations" do
    test "an opened delegation reads its exact Task and latest messages",
         %{conn: conn, org: org, project: project, router: router} do
      task_id = SalixStore.Ids.new_conversation_id()
      key = {:delegation_task, project.id, project.salix_group_id, router.id, @obligation, 1}

      use_stub(%{
        key => {:ok, %{"disposition" => "created", "conversation_id" => task_id}},
        {:task_snapshot, project.salix_group_id, task_id, [limit: 20, tail: 20]} =>
          {:ok,
           %{
             "conversation" => %{
               "conversation_id" => task_id,
               "kind" => "agent_task",
               "title" => "Inspect the rollout",
               "status" => "escalated",
               "metadata" => %{
                 "triage_investigation_state" => %{
                   "delivery_error" => %{"reason" => "private transport detail"}
                 }
               }
             },
             "messages" => [
               %{
                 "message_id" => "task-message-1",
                 "actor_type" => "agent",
                 "agent_name" => "Team Worker",
                 "content" => [%{"type" => "text", "text" => "The deployment finished."}],
                 "metadata" => %{
                   "triage_investigation_result" => %{
                     "payload" => %{
                       "communication" => %{
                         "kind" => "silence",
                         "reason_code" => "insufficient_evidence"
                       }
                     }
                   }
                 }
               }
             ]
           }}
      })

      path =
        triage_path(org, "/delegation", agent: router.id, obligation: @obligation, index: "1")

      data = conn |> get(path) |> json_response(200) |> data()

      assert %{
               "state" => "created",
               "href" => href,
               "preview" => %{
                 "title" => "Inspect the rollout",
                 "status" => "escalated",
                 "delivery_error" => true,
                 "participation" => %{
                   "kind" => "silence",
                   "reason_code" => "insufficient_evidence"
                 },
                 "messages" => [
                   %{
                     "id" => "task-message-1",
                     "actor" => "Team Worker",
                     "text" => "The deployment finished."
                   }
                 ]
               }
             } = data

      assert href == "/orgs/#{org.slug}/projects/#{project.id}/tasks/#{task_id}"
      refute Jason.encode!(data) =~ "private transport detail"
      assert delegation_lookups() == [key]
    end

    test "not created, unavailable and failed lookups stay distinct; bad locators never cross",
         %{conn: conn, org: org, project: project, router: router, user: user} do
      key = {:delegation_task, project.id, project.salix_group_id, router.id, @obligation, 0}
      use_stub(%{})

      path =
        triage_path(org, "/delegation", agent: router.id, obligation: @obligation, index: "0")

      for {response, expected} <- [
            {{:ok, %{"disposition" => "not_created"}}, %{"state" => "not_created"}},
            {{:ok, %{"disposition" => "reserved_task_unavailable"}}, %{"state" => "unavailable"}}
          ] do
        Stub.put(key, response)

        assert ^expected =
                 conn |> get(path) |> json_response(200) |> data() |> Map.take(["state"])
      end

      Stub.put(key, {:error, {:unavailable, "private lookup diagnostic"}})
      body = conn |> get(path) |> json_response(503)
      assert body["error"]["message"] == "Task lookup is unavailable. Try again."
      refute Jason.encode!(body) =~ "private lookup diagnostic"

      lookups = length(delegation_lookups())

      for params <- [
            [obligation: @obligation, index: "2"],
            [obligation: @obligation, index: "00"],
            [obligation: "", index: "0"],
            [obligation: @obligation]
          ] do
        params = [agent: router.id] ++ params

        assert %{"error" => %{"message" => "That delegation is no longer available."}} =
                 conn |> get(triage_path(org, "/delegation", params)) |> json_response(404)
      end

      assert length(delegation_lookups()) == lookups

      # Access is checked on every lookup.
      {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
      assert conn |> get(path) |> json_response(404)
      assert length(delegation_lookups()) == lookups
    end
  end

  describe "Knowledge" do
    test "people, projects and decisions keep their sources and accepted Agent use",
         %{conn: conn, org: org, user: user, project: project, router: router} do
      {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")

      fact =
        seed_assertion(
          project,
          user,
          "fact",
          "Dana owns the launch checklist",
          "s3://receipt-fact"
        )

      seed_assertion(project, user, "decision", "Ship on Friday", "s3://receipt-decision")

      use_stub(%{
        {:knowledge_uses, router.salix_agent_id} =>
          {:ok,
           %{
             "uses" =>
               for(
                 session <- ["ses-first", "ses-second"],
                 do: %{
                   "session_id" => session,
                   "retrieval_id" => "ret-shared",
                   "assistant_message_id" => "msg-#{session}",
                   "assistant_excerpt" => "I routed the launch checklist to Dana.",
                   "used_at" => 1_700_000_000,
                   "assertions" => [%{"id" => fact.id}]
                 }
               ),
             "complete" => true,
             "history_truncated" => false,
             "sessions_scanned" => 2
           }},
        :triage_knowledge =>
          {:ok,
           %{
             items: [
               %{
                 context_ref: "triage-active-decision",
                 kind: "decision",
                 state: :active,
                 subject: "Rollout owner",
                 value: "Peng owns the staging rollout",
                 confidence: "explicit",
                 source_count: 2,
                 inserted_at_ms: 1,
                 updated_at_ms: 2
               }
             ],
             complete: true
           }}
      })

      data =
        conn
        |> get(triage_path(org, "/knowledge", agent: router.id))
        |> json_response(200)
        |> data()

      assert %{"status" => "ok", "usage" => "available", "retained_status" => "available"} = data
      assertions = Map.new(data["assertions"], &{&1["content"], &1})

      assert %{
               "kind" => "fact",
               "source" => %{"type" => "slack_receipt", "ref" => "s3://receipt-fact"},
               "uses" => uses
             } = assertions["Dana owns the launch checklist"]

      assert uses |> Enum.map(& &1["session_id"]) |> Enum.sort() == ["ses-first", "ses-second"]
      assert assertions["Ship on Friday"]["kind"] == "decision"
      assert [%{"id" => user_id, "role" => "user"}] = data["members"]
      assert user_id == user.id

      assert [
               %{
                 "id" => "triage-active-decision",
                 "kind" => "decision",
                 "name" => "Rollout owner"
               }
             ] =
               data["retained"]

      assert data["imported"]["status"] in ["off", "ok"]
      refute :product_activity in Stub.calls()
    end

    test "unavailable evidence is reported, and another project's knowledge never leaks",
         %{conn: conn, org: org, user: user, project: project, router: router} do
      seed_assertion(project, user, "fact", "Bridge-only knowledge", "s3://receipt-bridge")

      {:ok, other} =
        BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
          "name" => "Atlas",
          "slug" => "atlas-#{unique()}"
        })

      other_router = Enum.find(Agents.list_agents(other.id), &(&1.role == "router"))
      seed_assertion(other, user, "fact", "Atlas-only knowledge", "s3://receipt-atlas")

      use_stub(%{
        {:knowledge_uses, router.salix_agent_id} => {:error, :unavailable},
        :triage_knowledge => {:error, :unavailable}
      })

      data =
        conn
        |> get(triage_path(org, "/knowledge", agent: router.id))
        |> json_response(200)
        |> data()

      assert %{"usage" => "unavailable", "retained_status" => "unavailable"} = data
      assert Enum.map(data["assertions"], & &1["content"]) == ["Bridge-only knowledge"]

      other_data =
        conn
        |> get(triage_path(org, "/knowledge", agent: other_router.id))
        |> json_response(200)
        |> data()

      assert Enum.map(other_data["assertions"], & &1["content"]) == ["Atlas-only knowledge"]
    end
  end

  # ---- helpers ----

  defp triage_path(org, rest \\ "", params \\ []) do
    query = if params == [], do: "", else: "?" <> URI.encode_query(params)
    "/dashboard/api/v1/orgs/#{org.slug}/triage#{rest}#{query}"
  end

  defp data(%{"data" => data}), do: data
  defp unique, do: System.unique_integer([:positive])

  defp use_stub(responses) do
    start_supervised!({Stub, responses})
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, TriageClient)
    on_exit(fn -> restore(:bridge_for_teams_core, :salix_client, previous) end)
    if :ets.whereis(ReadCache) != :undefined, do: :ets.delete_all_objects(ReadCache)
    :ok
  end

  # The audit writer is read from app env so the strict path is reachable:
  # "the access record failed to write" cannot otherwise be produced.
  defp use_failing_audit_writer do
    previous = Application.get_env(:bridge_for_teams_core, :triage_audit_writer)

    Application.put_env(:bridge_for_teams_core, :triage_audit_writer, fn _ ->
      {:error, :offline}
    end)

    on_exit(fn -> restore(:bridge_for_teams_core, :triage_audit_writer, previous) end)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp query_count(conn, path) do
    test_pid = self()
    handler = "triage-query-count-#{unique()}"

    :ok =
      :telemetry.attach(
        handler,
        [:bridge_for_teams, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test_pid, do: send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      conn |> get(path) |> json_response(200)
      count_messages(0)
    after
      :telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    receive do
      :repo_query -> count_messages(count + 1)
    after
      0 -> count
    end
  end

  defp posture_calls, do: Enum.count(Stub.calls(), &match?({:posture, _}, &1))
  defp roster_reads, do: Enum.count(Stub.calls(), &match?({:roster_page, _}, &1))

  # The router Agent of a project in another org.
  defp foreign_router_agent do
    %{org: foreign_org} = register_and_log_in_user(%{conn: build_conn()})

    {:ok, foreign} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        foreign_org.id,
        %{
          "name" => "Foreign",
          "slug" => "foreign-#{unique()}"
        }
      )

    Enum.find(Agents.list_agents(foreign.id), &(&1.role == "router"))
  end

  defp delegation_lookups,
    do: Enum.filter(Stub.calls(), &match?({:delegation_task, _, _, _, _, _}, &1))

  defp posture(connect_id, overrides \\ %{}) do
    Map.merge(
      %{
        connect_id: connect_id,
        posture_complete?: true,
        source_ready?: true,
        provisioned?: true,
        triage_enabled: false,
        approved_channel_id: "C123",
        approved_channel_name: nil,
        configured_channels: [%{channel_id: "C123", channel_name: "triage-room", enabled: true}],
        channel_scope_complete?: true,
        channel_controls_available?: true,
        authority_valid?: true,
        inbound_agent_id: Process.get(:default_inbound_agent_id),
        connect_generation: "gen-1",
        workspace_id: "T_AUTHORIZED",
        bot_username: "bridge-bot",
        workspace_name: "Acme",
        app_id: "A_AUTHORIZED"
      },
      overrides
    )
  end

  defp ring(readiness) do
    %{
      evaluation_readiness: readiness,
      runtime: %{
        evaluation_readiness: readiness,
        observed_at_ms: System.system_time(:millisecond)
      },
      recovery: %{cursor: nil}
    }
  end

  defp window(receipts) do
    %{
      receipts: receipts,
      scanned_pages: 1,
      legacy_count: 0,
      invalid_count: 0,
      unavailable_count: 0,
      unattributed_count: 0,
      scope_complete: true,
      truncated: false
    }
  end

  defp receipt(connect_id, text) do
    %{
      "connect_id" => connect_id,
      "receipt_ref" => "s3://receipt-#{connect_id}",
      "triage_event" => %{"text" => text, "message_ts" => "1700000000.000100"}
    }
  end

  defp activity_page do
    now = System.system_time(:millisecond)

    received = %{
      receipt_ref: "receipt-one",
      outcome_ref: "triage-public-event",
      connect_id: "c-1",
      state: :finalizing,
      received_at_ms: now - 5_000,
      source_at_ms: now - 5_000,
      source_message_ts: "1787019000.000100",
      source_channel: "C123",
      source_text: "Could someone verify the release observer?",
      terminal_status: nil,
      suggested_action: nil
    }

    %{
      outcomes: [
        %{
          event_ref: "triage-public-event",
          obligation_id: "obligation-1",
          source: %{
            connect_id: "c-1",
            channel_id: "C123",
            thread_ts: "1787019000.000100",
            message_count: 1,
            latest_activity_at_ms: now - 5_000,
            messages: [
              %{
                actor_kind: :human,
                excerpt: "Could someone verify the release observer?",
                message_ts: "1787019000.000100",
                occurred_at_ms: now - 5_000,
                speaker_label: "Peng Xiao",
                url: "https://app.slack.com/client/T1/C123",
                file_attachments: %{
                  "items" => [%{"name" => "transcript.txt", "kind" => "text"}],
                  "total_count" => 2,
                  "truncated" => true
                }
              }
            ]
          },
          evidence: %{communication_sources: 1, total_sources: 2},
          state: :applied,
          attempts: 1,
          communication: %{
            kind: :reply,
            text: "I checked the rollout.",
            reason: nil,
            status: "captured"
          },
          effect: %{
            adapter: "audit_sink",
            outcome: "applied",
            external_writes: 0,
            status: "captured"
          },
          context: %{candidates: 0, active: 0, proposed: 0},
          related_context: [],
          delegations: [%{index: 0, task: "Check", source_count: 1, status: "created"}],
          inserted_at_ms: now - 2_000,
          updated_at_ms: now - 1_000,
          run_id: "internal-run",
          raw_error: "private transport detail"
        }
      ],
      context: [],
      follow_ups:
        {:ok,
         [
           %{
             context_ref: "follow-up",
             kind: "follow_up",
             state: :active,
             subject: "Rollout",
             value: "Check again",
             confidence: "explicit",
             source_count: 1
           }
         ]},
      next_cursor: "server-second",
      intake:
        {:ok,
         %{
           items: [
             received,
             %{
               received
               | receipt_ref: "receipt-two",
                 outcome_ref: nil,
                 state: :settled,
                 received_at_ms: now - 500,
                 terminal_status: "failed",
                 source_text:
                   "Original <@U123> message\nsee <https://github.com/AFK-surf/Comma/pull/1602|PR #1602> <@UNKNOWN1> <javascript:alert(1)|click> &lt;script&gt;"
             }
           ],
           truncated: false
         }}
    }
  end

  defp seed_assertion(project, user, kind, content, ref) do
    source = %{type: "slack_receipt", ref: ref, observed_at: DateTime.utc_now()}
    # An alias registered by an earlier assertion stays registered.
    _ = ProjectKnowledge.register_alias(project.id, {:person, user.id}, user.name, source)
    _ = ProjectKnowledge.register_alias(project.id, {:project, project.id}, project.name, source)

    {:ok, assertion} =
      ProjectKnowledge.append_assertion(
        project.id,
        kind,
        content,
        [{:person, user.id}, {:project, project.id}],
        source
      )

    assertion
  end

  defp sick_project(org, name) do
    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => name,
        "slug" => "down-#{unique()}"
      })

    project
  end

  defp insert_router_agent(project) do
    {:ok, agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
        role: "router",
        name: "Router"
      })

    agent
  end
end
