defmodule BridgeForTeams.TriageInvestigationContextTest do
  use ExUnit.Case, async: false

  alias BridgeForTeams.TriageInvestigationContext, as: Context
  alias SalixIM.Provider
  alias SalixStore.{CasRecord, Ids, Keys}

  @source_root "1788775500.000000"
  @settings [
    {:bridge_for_teams_core, :triage_investigation_context_state},
    {:salix_agent, :im_provider_mod},
    {:salix_im, :slack_triage_clickhouse_reader_mod},
    {:salix_im, :slack_message_mirror_mod}
  ]

  setup do
    previous =
      for {app, key} <-
            @settings ++
              [
                {:salix_store, :s3_backend},
                {:bridge_for_teams_core, :triage_acceptance_owner},
                {:bridge_for_teams_core, :triage_acceptance_thread}
              ],
          do: {app, key, Application.fetch_env(app, key)}

    on_exit(fn -> restore(previous) end)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    unless Process.whereis(SalixStore.S3.Fake), do: start_supervised!(SalixStore.S3.Fake)
    unless Process.whereis(Ids), do: start_supervised!(Ids)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    worker = worker!(tenant, group)

    connect = %{
      "provider" => "slack",
      "tenant_id" => tenant,
      "group_id" => group,
      "connect_id" => Ids.new_connect_id(),
      "connect_generation" => "local-context-generation",
      "workspace_id" => "TLOCALCONTEXT",
      "approved_channel_id" => "CLOCALSOURCE",
      "app_id" => "ALOCALCONTEXT",
      "bot_token" => "local-context-token",
      "oauth_completed_at" => 1
    }

    assert {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group, connect["connect_id"]), connect)
    state = start_supervised!({Agent, fn -> %{} end})

    context =
      Context.build(connect, "Why did this request expire?", "INC-local-context", @source_root)

    %{worker: worker, connect: connect, state: state, context: context}
  end

  test "channel-batch Triage reads only the frozen source through the investigation fixture",
       ctx do
    on_exit(Context.install!(ctx.state, ctx.context))
    Application.put_env(:bridge_for_teams_core, :triage_acceptance_owner, self())
    [original | _] = ctx.context.messages
    BridgeForTeams.TriageEngineFixture.put_thread([original])
    {:ok, root_us} = SalixIM.SlackMessageMirror.Row.slack_ts_micros(@source_root)
    window = %{"oldest_ts_us" => root_us, "thread_roots" => [@source_root]}
    source_scope = scope(ctx, "CLOCALSOURCE")

    assert {:ok, %{messages: [row], complete?: true}} =
             Context.read_channel(source_scope, window, limit: 200)

    assert row["text"] == original["text"]
    assert_receive {:clickhouse_read, "clickhouse.channel_current", ^source_scope, ^window}
    refute row["text"] =~ "refresh result=success"
  end

  test "provider observer captures the exact real coverage wrapper under the argument's Worker identity",
       ctx do
    on_exit(Context.install!(ctx.state, ctx.context))

    args = %{
      "connect_id" => ctx.connect["connect_id"],
      "params" => %{
        "channel" => ctx.context.context_channel,
        "ts" => ctx.context.context_root,
        "query" => String.duplicate("x", 4_097),
        "token" => "not-for-observation"
      },
      "tool_context" => %{"agent_id" => "not-the-authorized-worker"},
      "headers" => %{"authorization" => "not-for-observation"}
    }

    assert {:ok, %{"incomplete" => %{"reason" => "not_synced"}} = actual_page} =
             Provider.call_api(ctx.worker, "slack", "slack.get_thread_replies", args)

    assert {:ok, ^actual_page} =
             Context.call_api(ctx.worker, "slack", "slack.get_thread_replies", args)

    assert [event] = Agent.get(ctx.state, & &1.provider_responses)

    assert event == %{
             agent_id: ctx.worker,
             api: "slack.get_thread_replies",
             params: %{
               "channel" => ctx.context.context_channel,
               "ts" => ctx.context.context_root,
               "query" => "[omitted: outside fixture observation bound]"
             },
             response: actual_page
           }

    assert Agent.get(ctx.state, & &1.context) == ctx.context
    refute Jason.encode!(event) =~ "not-for-observation"
  end

  test "provider observer delegates discovery with the same actual Worker role", ctx do
    on_exit(Context.install!(ctx.state, ctx.context))
    assert Context.list_connects(ctx.worker) == Provider.list_connects(ctx.worker)
    assert Context.group_providers(ctx.worker) == Provider.group_providers(ctx.worker)
    assert Context.provider_manual("slack") == Provider.provider_manual("slack")

    assert Context.provider_manual("slack", ctx.worker) ==
             Provider.provider_manual("slack", ctx.worker)

    assert {:ok, %{"apis" => apis}} = Context.provider_manual("slack", ctx.worker)
    assert Enum.any?(apis, &(&1["name"] == "slack.get_thread_replies"))
    refute Enum.any?(apis, &(&1["name"] == "slack.post_message"))
    assert Agent.get(ctx.state, &Map.get(&1, :provider_responses, [])) == []
  end

  test "ordinary Worker history and thread reads expose seeded context with its own receipt",
       ctx do
    on_exit(Context.install!(ctx.state, ctx.context))

    assert {:ok, %{"messages" => [source], "has_more" => false}} =
             read(ctx, "get_channel_history", %{"channel" => "CLOCALSOURCE"})

    assert source["ts"] == @source_root
    assert source["text"] == "Why did this request expire?"

    assert {:ok, %{"messages" => [^source, link]}} =
             read(ctx, "get_thread_replies", %{"channel" => "CLOCALSOURCE", "ts" => @source_root})

    assert link["text"] =~ "CLOCALCONTEXT"
    assert link["text"] =~ ctx.context.incident

    assert [%{operation: :history} = history, %{operation: :replies} = replies] =
             Agent.get(ctx.state, & &1.context_reads)

    for receipt <- [history, replies] do
      assert receipt.agent_id == ctx.worker
      assert receipt.scope == scope(ctx, "CLOCALSOURCE")
    end

    assert replies.root == @source_root
    assert List.last(replies.messages)["text"] == link["text"]
    assert Provider.current_tool_context() == %{}
  end

  test "normal replies preserve oldest-first pagination, cursor continuation and time bounds",
       ctx do
    on_exit(Context.install!(ctx.state, ctx.context))
    params = %{"channel" => ctx.context.context_channel, "ts" => ctx.context.context_root}

    assert {:ok, %{"messages" => [root], "has_more" => true, "next_cursor" => cursor}} =
             read(ctx, "get_thread_replies", Map.put(params, "limit", 1))

    assert root["ts"] == ctx.context.context_root

    assert {:ok, %{"messages" => [refresh, failure], "has_more" => false} = last} =
             read(ctx, "get_thread_replies", Map.put(params, "cursor", cursor))

    refute Map.has_key?(last, "next_cursor")
    assert refresh["text"] =~ "refresh result=success"
    assert failure["text"] =~ "used_access_ref=#{ctx.context.old_ref}"
    assert failure["text"] =~ "does not identify which cache or update step"

    assert {:ok, %{"messages" => [^refresh]}} =
             read(
               ctx,
               "get_thread_replies",
               Map.merge(params, %{
                 "oldest" => root["ts"],
                 "latest" => failure["ts"],
                 "inclusive" => false
               })
             )

    assert {:ok, %{"messages" => [^root, ^refresh, ^failure]}} =
             read(
               ctx,
               "get_thread_replies",
               Map.merge(params, %{
                 "oldest" => root["ts"],
                 "latest" => failure["ts"],
                 "inclusive" => true
               })
             )

    assert {:ok, %{"messages" => [^refresh]}} =
             read(
               ctx,
               "get_thread_replies",
               Map.merge(params, %{
                 "before_ts" => failure["ts"],
                 "root_already_preloaded" => true
               })
             )

    assert {:ok, %{"messages" => []}} =
             read(ctx, "get_thread_replies", Map.put(params, "oldest", failure["ts"]))
  end

  test "unseeded coordinates and changed continuation requests fail instead of succeeding empty",
       ctx do
    on_exit(Context.install!(ctx.state, ctx.context))

    params = %{
      "channel" => ctx.context.context_channel,
      "ts" => ctx.context.context_root,
      "limit" => 1
    }

    assert {:ok, %{"next_cursor" => cursor}} = read(ctx, "get_thread_replies", params)

    for changed <- [
          %{"channel" => "CLOCALSOURCE", "ts" => @source_root, "cursor" => cursor},
          Map.merge(params, %{"oldest" => ctx.context.context_root, "cursor" => cursor}),
          Map.put(params, "cursor", "local-context:not-a-cursor"),
          Map.put(params, "ts", "1788775599.000000")
        ] do
      assert {:error, error} = read(ctx, "get_thread_replies", changed)
      assert error =~ "local_fixture_context_unavailable"
    end

    assert {:error, error} = read(ctx, "get_channel_history", %{"channel" => "CUNSEEDED"})
    assert error =~ "local_fixture_context_unavailable"

    assert {:error, error} =
             read(ctx, "get_channel_history", %{
               "channel" => "CLOCALSOURCE",
               "oldest" => "not-a-timestamp"
             })

    assert error =~ "local_fixture_context_unavailable"
    assert length(Agent.get(ctx.state, & &1.context_reads)) == 1
  end

  test "fixture scope and the production Worker role and Group gates remain enforced", ctx do
    on_exit(Context.install!(ctx.state, ctx.context))

    for field <- ~w(tenant_id workspace_id) do
      assert {:error, :local_fixture_context_unavailable} =
               Context.history(Map.put(scope(ctx, "CLOCALSOURCE"), field, "foreign"), [])
    end

    foreign = %{
      ctx
      | worker: worker!(ctx.connect["tenant_id"], Ids.new_group_id(ctx.connect["tenant_id"]))
    }

    assert {:error, "connect not found"} =
             read(foreign, "get_channel_history", %{"channel" => "CLOCALSOURCE"})

    assert {:error, "operation is not available to this agent role"} =
             read(ctx, "post_message", %{"channel" => "CLOCALSOURCE", "text" => "not permitted"})

    assert Agent.get(ctx.state, &Map.get(&1, :context_reads, [])) == []
    assert Agent.get(ctx.state, &Map.get(&1, :provider_responses, [])) == []

    # Internal results are authored/control-plane material, not independent
    # Slack read evidence; even their original error result passes unchanged.
    internal_args = %{"connect_id" => "internal", "params" => %{}}

    assert Context.call_api(ctx.worker, "internal", "internal.not_seeded", internal_args) ==
             Provider.call_api(ctx.worker, "internal", "internal.not_seeded", internal_args)

    assert Agent.get(ctx.state, &Map.get(&1, :provider_responses, [])) == []
  end

  test "Triage's frozen reads never receive the supplemental investigation corpus", ctx do
    frozen = [%{"ts" => @source_root, "text" => "Frozen Triage source only", "user" => "UHUMAN"}]
    Application.put_env(:bridge_for_teams_core, :triage_acceptance_owner, self())
    Application.put_env(:bridge_for_teams_core, :triage_acceptance_thread, frozen)
    on_exit(Context.install!(ctx.state, ctx.context))
    source_scope = scope(ctx, "CLOCALSOURCE")

    assert {:ok, tail} = Context.tail(source_scope)
    assert {:ok, %{messages: [source]}} = Context.read_thread(source_scope, @source_root, [])
    assert source["text"] == "Frozen Triage source only"
    assert {:ok, states} = Context.latest_states(source_scope, [source["message_ts_us"]])
    assert Map.values(states) == [source]

    assert {:ok, %{rows: [^source], has_more?: false}} =
             Context.list_changes(
               source_scope,
               %{"lower_bound" => tail, "tail" => tail, "page_after" => nil},
               10
             )

    assert length(ctx.context.messages) == 5
    assert length(ctx.context.evidence) == 4
    refute Enum.any?(ctx.context.evidence, &(&1["ts"] == @source_root))

    assert {:ok, %{messages: diagnostics}} =
             Context.replies(
               scope(ctx, ctx.context.context_channel),
               ctx.context.context_root,
               []
             )

    assert length(diagnostics) == 3
    refute Enum.any?(diagnostics, &(&1["text"] == source["text"]))
    assert Application.fetch_env!(:bridge_for_teams_core, :triage_acceptance_thread) == frozen
  end

  test "cleanup restores absent settings, explicit nil and existing modules exactly", ctx do
    Application.delete_env(:bridge_for_teams_core, :triage_investigation_context_state)
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, nil)
    Application.put_env(:salix_im, :slack_message_mirror_mod, SalixIM.SlackMessageMirror.Noop)
    Application.put_env(:salix_agent, :im_provider_mod, nil)
    expected = for {app, key} <- @settings, do: {app, key, Application.fetch_env(app, key)}
    cleanup = Context.install!(ctx.state, ctx.context)
    assert Application.fetch_env!(:salix_im, :slack_triage_clickhouse_reader_mod) == Context
    assert Application.fetch_env!(:salix_agent, :im_provider_mod) == Context
    cleanup.()

    assert for({app, key} <- @settings, do: {app, key, Application.fetch_env(app, key)}) ==
             expected
  end

  test "receipt exhaustion fails closed without terminating the shared corpus", ctx do
    on_exit(Context.install!(ctx.state, ctx.context))
    Agent.update(ctx.state, &Map.put(&1, :context_reads, List.duplicate(%{}, 200)))
    assert {:error, error} = read(ctx, "get_channel_history", %{"channel" => "CLOCALSOURCE"})
    assert error =~ "local_fixture_context_receipts_full"
    assert Process.alive?(ctx.state)
    assert length(Agent.get(ctx.state, & &1.context_reads)) == 200
  end

  test "provider response observation exhaustion is explicit and preserves Provider errors",
       ctx do
    on_exit(Context.install!(ctx.state, ctx.context))
    Agent.update(ctx.state, &Map.put(&1, :provider_responses, List.duplicate(%{}, 200)))

    assert {:error, "local fixture provider response observation limit exceeded"} =
             read(ctx, "get_channel_history", %{"channel" => "CLOCALSOURCE"})

    assert {:error, "operation is not available to this agent role"} =
             read(ctx, "post_message", %{"channel" => "CLOCALSOURCE", "text" => "not permitted"})

    assert Process.alive?(ctx.state)
    assert length(Agent.get(ctx.state, & &1.provider_responses)) == 200
  end

  defp read(ctx, api, params) do
    provider = Application.fetch_env!(:salix_agent, :im_provider_mod)

    provider.call_api(ctx.worker, "slack", "slack." <> api, %{
      "connect_id" => ctx.connect["connect_id"],
      "params" => params,
      # This is the same server-owned metadata populated by ImRouter, not a
      # tool permission or an agent-visible fixture-specific parameter.
      "tool_context" => %{"agent_id" => ctx.worker}
    })
  end

  defp scope(ctx, channel),
    do: Map.take(ctx.connect, ~w(tenant_id workspace_id)) |> Map.put("channel_id", channel)

  defp worker!(tenant, group) do
    assert {:ok, _} =
             CasRecord.create(Keys.ctl_group(group), %{
               "tenant_id" => tenant,
               "group_id" => group,
               "router_agent_id" => Ids.new_agent_id(group),
               "router_conversation_id" => Ids.new_conversation_id()
             })

    worker = Ids.new_agent_id(group)

    assert {:ok, _} =
             CasRecord.create(Keys.ctl_agent(worker), %{
               "agent_id" => worker,
               "tenant_id" => tenant,
               "group_id" => group,
               "role" => "worker",
               "heartbeat_schedule_id" => Ids.new_schedule_id()
             })

    worker
  end

  defp restore(settings) do
    Enum.each(settings, fn
      {app, key, {:ok, value}} -> Application.put_env(app, key, value)
      {app, key, :error} -> Application.delete_env(app, key)
    end)
  end
end

defmodule BridgeForTeams.TriageInvestigationContextScenarioTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.TriageInvestigationContext, as: Context

  @authority %{
    "tenant_id" => "scenario-tenant",
    "group_id" => "scenario-group",
    "connect_id" => "scenario-connect",
    "connect_generation" => "scenario-generation",
    "workspace_id" => "TSCENARIO",
    "approved_channel_id" => "CSCENARIOSOURCE"
  }
  @source "INC-42: orion meet bot received token_expired. Please investigate."
  @incident "INC-42"
  @source_root "1788775500.000000"

  test "build/4 keeps the positive correlated corpus and its original evidence identities" do
    context = Context.build(@authority, @source, @incident, @source_root)
    assert context == Context.build(@authority, @source, @incident, @source_root, :positive)
    assert context.scenario == :positive
    assert context.incident == @incident
    assert context.evidence_incident == @incident
    assert context.session == context.evidence_session
    assert context.session == "session-INC-42"
    assert context.old_ref == context.evidence_old_ref
    assert context.old_ref == "access-old-INC-42"
    assert context.new_ref == context.evidence_new_ref
    assert context.new_ref == "access-new-INC-42"
    assert context.evidence_marker == context.new_ref
    assert length(context.messages) == 5
    assert length(context.evidence) == 4
    assert hd(context.messages)["text"] == @source
  end

  test "sparse provides only the unchanged original question, without absence claims" do
    context = Context.build(@authority, @source, @incident, @source_root, :sparse)
    assert context.scenario == :sparse
    assert context.incident == @incident
    assert context.evidence == []
    assert is_nil(context.evidence_marker)

    assert context.messages == [
             %{
               "type" => "message",
               "channel" => @authority["approved_channel_id"],
               "ts" => @source_root,
               "thread_ts" => @source_root,
               "user" => "U_CAPTURED_HUMAN",
               "text" => @source,
               "reply_count" => 0
             }
           ]

    for field <-
          ~w(evidence_incident evidence_session evidence_old_ref evidence_new_ref session old_ref new_ref)a do
      assert is_nil(Map.fetch!(context, field))
    end

    source_scope = scope(@authority["approved_channel_id"])

    assert {:ok, %{messages: messages, has_more?: false}} =
             Context.page(context.messages, :replies, source_scope, @source_root, [])

    assert messages == context.messages

    assert {:error, :local_fixture_context_unavailable} =
             Context.page(
               context.messages,
               :replies,
               scope(context.context_channel),
               context.context_root,
               []
             )

    assert {:error, :local_fixture_context_unavailable} =
             Context.page(context.messages, :history, scope(context.context_channel), nil, [])
  end

  test "wrong-session linked records consistently concern a different incident of the same bot" do
    context = Context.build(@authority, @source, @incident, @source_root, :wrong_session)
    assert context.scenario == :wrong_session
    assert context.incident == @incident
    assert context.evidence_incident == "other-INC-42"
    assert context.evidence_incident != context.incident
    assert context.session == context.evidence_session
    assert context.session == "session-other-INC-42"
    assert context.old_ref == context.evidence_old_ref
    assert context.old_ref == "access-old-other-INC-42"
    assert context.new_ref == context.evidence_new_ref
    assert context.new_ref == "access-new-other-INC-42"
    assert context.evidence_marker == context.new_ref

    assert [source, followup, diagnostic, refresh, request] = context.messages
    assert source["text"] == @source
    assert source["ts"] == @source_root
    assert context.evidence == [followup, diagnostic, refresh, request]
    assert followup["text"] =~ "#{context.evidence_incident} 排查"
    assert followup["text"] =~ "/archives/#{context.context_channel}/"
    assert followup["thread_ts"] == @source_root

    for row <- [diagnostic, refresh, request] do
      assert row["channel"] == context.context_channel
      assert row["thread_ts"] == context.context_root
      assert row["text"] =~ "orion meet bot"
      assert row["text"] =~ context.evidence_incident
      assert row["text"] =~ context.evidence_session
      refute row["text"] =~ "session-INC-42"
    end

    assert refresh["text"] =~ "refresh result=success"
    assert refresh["text"] =~ "old_access_ref=#{context.evidence_old_ref}"
    assert refresh["text"] =~ "issued_access_ref=#{context.evidence_new_ref}"
    assert request["text"] =~ "used_access_ref=#{context.evidence_old_ref}"
    assert request["text"] =~ "response=401 token_expired"
  end

  test "release observation correlates fixed rollout and request rows without token identities" do
    source =
      "REL-204：staging 的 atlas-api 发布任务显示成功，但我验证接口时看到的还是 rev-203。现在到底发布到了什么状态？请查清现有记录能确认什么，以及还需核对什么。初始导出在发布诊断 Worker 的 /diagnostics/release-observation.json；请通过 Task 回复完整结果，并附上未改动的原文件。只读排查，不做部署或回滚。"

    root = "1787019000.000001"
    context = Context.build(@authority, source, "REL-204", root, :release_observation)
    assert context.scenario == :release_observation
    assert context.incident == "REL-204"
    assert context.evidence_incident == context.incident
    assert context.evidence_marker == "edge-trace-204-1"
    refute source =~ context.evidence_marker

    for field <- ~w(evidence_session evidence_old_ref evidence_new_ref session old_ref new_ref)a do
      assert is_nil(Map.fetch!(context, field))
    end

    assert [original, followup, diagnostic, deployment, request] = context.messages
    assert original["text"] == source
    assert original["ts"] == root
    assert context.evidence == [followup, diagnostic, deployment, request]
    assert followup["ts"] == "1787019010.000000"
    assert followup["thread_ts"] == root
    assert followup["text"] =~ "/archives/CLOCALRELEASE/p1787019005000000"
    assert diagnostic["ts"] == "1787019005.000000"
    assert deployment["ts"] == "1787019006.000000"
    assert request["ts"] == "1787019007.000000"

    for row <- [diagnostic, deployment, request] do
      assert row["channel"] == context.context_channel
      assert row["thread_ts"] == context.context_root
      assert row["text"] =~ "REL-204 / staging / atlas-api"
    end

    assert deployment["text"] =~
             "observed_at=2026-08-18T02:09:30Z; desired_revision=rev-204; desired_replicas=3; updated_replicas=2; ready_replicas=3"

    assert request["text"] =~
             "trace_id=#{context.evidence_marker}; request_id=probe-204-1; request_at=2026-08-18T02:09:58Z; backend_instance=atlas-api-old-1; backend_revision=rev-203; http_status=200"

    assert {:ok, %{messages: rows}} =
             Context.page(
               context.messages,
               :replies,
               scope(context.context_channel),
               context.context_root,
               []
             )

    assert rows == [diagnostic, deployment, request]

    assert %{"ok" => true, "channel" => %{"name" => "release-diagnostics"}} =
             Context.slack_response(context, "conversations.info", %{
               "channel" => context.context_channel
             })
  end

  test "web fixture exposes labeled release definitions and preserves the auth page" do
    release =
      Context.build(
        @authority,
        "Release question",
        "REL-204",
        "1787019000.000001",
        :release_observation
      )

    auth = Context.build(@authority, @source, @incident, @source_root)

    for {context, query, title} <- [
          {release, "staging deployment revision",
           "Release observation field definitions (local fixture)"},
          {auth, "token refresh", "Session refresh diagnostics"}
        ] do
      expected = %{"url" => context.runbook_url, "title" => title, "text" => context.runbook}

      for {path, params} <- [
            {"/search", %{"query" => query}},
            {"/contents", %{"urls" => [context.runbook_url]}}
          ] do
        assert %Req.Response{status: 200, body: body} =
                 Context.web_response(context, %{method: :post, path: path, json: params})

        assert Jason.decode!(body) == %{"results" => [expected]}
      end
    end

    refute release.runbook =~ "REL-204"
    refute release.runbook =~ "edge-trace-204-1"
    refute release.runbook =~ "rev-203"
    assert release.runbook =~ "updated_replicas"
  end

  defp scope(channel),
    do: Map.take(@authority, ~w(tenant_id workspace_id)) |> Map.put("channel_id", channel)
end
