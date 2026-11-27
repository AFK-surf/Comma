defmodule BridgeForTeamsWeb.DashboardAPILarkTriageTest do
  @moduledoc """
  The Feishu / Lark triage API behind `/orgs/:org/lark-triage`: owners and
  admins only, a shared group another Swarm watches answers 409 with that
  Swarm's name, the Timeline carries no message text, and a reveal shows text
  only after its audit rows are stored.

  Salix answers come from a scripted client (`:salix_client`), so the tests
  run serially.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  import Ecto.Query

  alias BridgeForTeams.{Agents, Memberships, Repo}
  alias BridgeForTeams.Schema.AuditLog

  defmodule Client do
    @moduledoc """
    Scripted `lark_suite_triage/2`; every other callback goes to the real
    Erpc client, so org, project and Agent reads keep working.
    """

    for {name, arity} <- BridgeForTeams.Salix.Client.behaviour_info(:callbacks),
        {name, arity} != {:lark_suite_triage, 2} do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: apply(BridgeForTeams.Salix.Erpc, unquote(name), unquote(args))
    end

    def lark_suite_triage(function, request) do
      script = SystemsRuntime.fetch_env!(:bridge_for_teams_core, :lark_triage_test_script)
      SystemsRuntime.Proc.send(script.owner, {:salix, function, request})
      answer(function, request, script)
    end

    defp answer(:overview, request, script),
      do:
        {:ok,
         %{
           router_agent_id: script.routers[request.group_id],
           connects: [
             %{
               connect_id: "con_feishu",
               provider: "feishu",
               app_name: "研发助手",
               enabled: true,
               chats: [%{chat_id: "oc_rd", chat_name: "研发群", enabled: true}]
             }
           ]
         }}

    defp answer(:add_chats, %{chats: chats}, script) do
      {shared, other} = Enum.split_with(chats, &(&1.chat_id == "oc_shared"))

      {:ok,
       %{
         added: Enum.map(other, & &1.chat_id),
         conflicts:
           for(
             chat <- shared,
             do: %{
               chat_id: chat.chat_id,
               chat_name: "跨部门群",
               group_id: script.finance_group,
               connect_id: "con_fin"
             }
           ),
         failed: []
       }}
    end

    # A Salix answer that still held text must not reach the page.
    defp answer(:activity, _request, _script),
      do:
        {:ok,
         %{
           items: [
             %{
               id: "ltb_1",
               provider: "feishu",
               chat_id: "oc_rd",
               chat_name: "研发群",
               state: "applied",
               decision_kind: "reply",
               reason_code: nil,
               reaction_emoji: nil,
               task_title: nil,
               task_conversation_id: nil,
               error_code: nil,
               target_message_id: "om_1",
               inserted_at: ~N[2026-11-19 08:00:00.000000],
               settled_at: ~N[2026-11-19 08:00:04.000000],
               messages_json: [
                 %{
                   "message_id" => "om_1",
                   "sender_name" => "王小明",
                   "sent_at_ms" => 1,
                   "text" => "secret plan"
                 }
               ]
             }
           ],
           next_cursor: {1_795_080_000_000_000, "ltb_1"}
         }}

    defp answer(:reveal, %{batch_id: "ltb_1"}, _script),
      do:
        {:ok,
         %{
           batch_id: "ltb_1",
           connect_id: "con_feishu",
           reply_text: "Here is the plan.",
           messages: [
             %{message_id: "om_1", sender_name: "王小明", sent_at_ms: 1, text: "secret plan"}
           ]
         }}

    defp answer(:reveal, _request, _script), do: {:error, :not_found}

    defp answer(:set_source, %{connect_id: "con_no_bot", enabled: true}, _script),
      do: {:error, :bot_identity_missing}

    defp answer(_function, _request, _script), do: {:ok, %{enabled: true}}
  end

  setup %{conn: conn} do
    SalixAgent.TestSupport.configure_platform_models!()
    %{conn: conn, org: org, user: user} = register_and_log_in_user(%{conn: conn})

    projects =
      for {name, slug} <- [{"研发部", "rd"}, {"财务部", "fin"}] do
        {:ok, project} =
          BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
            "name" => name,
            "slug" => "#{slug}-#{SystemsRuntime.Proc.unique_integer([:positive])}"
          })

        router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))
        {project, router}
      end

    [{rd, rd_router}, {fin, fin_router}] = projects

    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, Client)

    SystemsRuntime.put_env(:bridge_for_teams_core, :lark_triage_test_script, %{
      owner: SystemsRuntime.Proc.self(),
      finance_group: fin.salix_group_id,
      routers: %{
        rd.salix_group_id => rd_router.salix_agent_id,
        fin.salix_group_id => fin_router.salix_agent_id
      }
    })

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client)

      SystemsRuntime.delete_env(:bridge_for_teams_core, :lark_triage_test_script)
      SystemsRuntime.delete_env(:bridge_for_teams_core, :lark_suite_triage_audit_writer)
    end)

    %{conn: conn, org: org, user: user, rd: rd, router: rd_router}
  end

  defp lark_path(org, suffix \\ ""), do: "/dashboard/api/v1/orgs/#{org.slug}/lark-triage#{suffix}"

  test "only owners and admins reach it; members get the non-member 404", ctx do
    assert %{"data" => %{"agents" => agents}} =
             ctx.conn |> get(lark_path(ctx.org)) |> json_response(200)

    assert [
             %{
               "project_name" => "研发部",
               "sources" => [%{"provider" => "feishu", "chats" => [%{"name" => "研发群"}]}]
             },
             _
           ] =
             Enum.sort_by(agents, &(&1["project_name"] != "研发部"))

    member =
      user_fixture(
        email: "lark-triage-member-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"
      )

    {:ok, _} = Memberships.put_org_member(ctx.org.id, member.id, "member")
    member_conn = log_in_user(build_conn(), member)

    for request <- [
          &get(&1, lark_path(ctx.org)),
          &get(&1, lark_path(ctx.org, "/activity"), %{"agent" => ctx.router.id}),
          &post(&1, lark_path(ctx.org, "/reveal"), %{"agent" => ctx.router.id, "batch" => "ltb_1"})
        ] do
      assert %{"error" => %{"code" => "org_not_found"}} =
               member_conn |> request.() |> json_response(404)
    end

    refute_received {:salix, :reveal, _request}
  end

  test "a group another Swarm watches is refused with that Swarm's name", ctx do
    body =
      ctx.conn
      |> post(lark_path(ctx.org, "/sources/con_feishu/chats"), %{
        "agent" => ctx.router.id,
        "chats" => [%{"id" => "oc_shared"}]
      })
      |> json_response(409)

    assert %{"error" => %{"code" => "chat_already_claimed", "message" => message}} = body
    assert message =~ "财务部"
    assert message =~ "跨部门群"
    assert_received {:salix, :add_chats, %{group_id: group_id, connect_id: "con_feishu"}}
    assert group_id == ctx.rd.salix_group_id

    assert %{"data" => %{"notice" => _}} =
             ctx.conn
             |> post(lark_path(ctx.org, "/sources/con_feishu/chats"), %{
               "agent" => ctx.router.id,
               "chats" => [%{"id" => "oc_new", "name" => "新群"}]
             })
             |> json_response(200)
  end

  test "the timeline has no message text; a reveal is audited first", ctx do
    data =
      ctx.conn
      |> get(lark_path(ctx.org, "/activity"), %{"agent" => ctx.router.id, "kind" => "reply"})
      |> json_response(200)
      |> Map.fetch!("data")

    refute Jason.encode!(data) =~ "secret plan"
    assert [%{"kind" => "reply", "messages" => [%{"sender_name" => "王小明"}]}] = data["items"]
    assert data["next_cursor"] == "1795080000000000:ltb_1"

    assert %{
             "data" => %{
               "messages" => [%{"text" => "secret plan"}],
               "reply_text" => "Here is the plan."
             }
           } =
             ctx.conn
             |> post(lark_path(ctx.org, "/reveal"), %{
               "agent" => ctx.router.id,
               "batch" => "ltb_1"
             })
             |> json_response(200)

    assert [%{resource_id: "ltb_1:om_1", actor_user_id: actor, result: "ok"}] =
             Repo.all(
               from(a in AuditLog,
                 where:
                   a.org_id == ^ctx.org.id and
                     a.action == "integration.lark_suite.triage_text_revealed"
               )
             )

    assert actor == ctx.user.id

    SystemsRuntime.put_env(:bridge_for_teams_core, :lark_suite_triage_audit_writer, fn _rows ->
      {:error, :down}
    end)

    body =
      ctx.conn
      |> post(lark_path(ctx.org, "/reveal"), %{"agent" => ctx.router.id, "batch" => "ltb_1"})
      |> json_response(503)

    assert %{"error" => %{"code" => "audit_unavailable"}} = body
    refute Jason.encode!(body) =~ "secret plan"
  end

  test "enabling a source without bot identity returns 422 bot_identity_missing", ctx do
    body =
      ctx.conn
      |> put(lark_path(ctx.org, "/sources/con_no_bot"), %{
        "agent" => ctx.router.id,
        "enabled" => true
      })
      |> json_response(422)

    assert %{"error" => %{"code" => "bot_identity_missing", "message" => message}} = body
    assert is_binary(message) and message != ""
  end
end
