defmodule BridgeForTeams.TriageDelegationProviderTest do
  @moduledoc """
  Deterministic production integration from an immutable PG obligation through
  the BFT Router handoff, Provider authorization and canonical Task owner.

  The settled obligation is seeded rather than produced by a model. The
  existing fixture replaces only the ClickHouse reader and Slack transport;
  current product/control, connect/channel/route and Freshness owners are real.
  Delivery persists the real Session input queue with model wakeup disabled.
  Tool context comes from that queued handoff, but the test invokes Provider directly:
  this is not model/tool-dispatch or online Slack E2E acceptance.
  """

  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.TriageDelegation
  alias BridgeForTeams.Schema.Agent, as: ProductAgent
  alias BridgeForTeams.TriageEngineFixture, as: Fixture

  alias SalixAgent.{
    AgentActor,
    AsyncToolResults,
    DependencyJob,
    InternalSessionStore,
    SessionToolExecution,
    Tools
  }

  alias SalixAgent.InternalSession
  alias SalixIM.{ConversationServer, Conversations, Provider}
  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixIM.Triage.{CanonicalJSON, ProductObligation}
  alias SalixStore.{Ids, RuntimeIds, TriageKeys, TriageProductRuntime, ULID}

  @moduletag :triage_delegation_provider
  @owner_key :triage_delegation_provider_owner

  defmodule NoWakeDelivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent_id, payload, opts),
      do: SalixAgent.deliver(agent_id, payload, Keyword.put(opts, :no_wake, true))

    def get_session(agent_id, session_id, opts),
      do: SalixAgent.Runtime.get_session(agent_id, session_id, opts)

    def get_session_messages(agent_id, session_id),
      do: SalixAgent.Runtime.get_session_messages(agent_id, session_id)
  end

  defmodule NoModel do
    def complete(_, _, _), do: unexpected_call()
    def complete_stream(_, _, _, _), do: unexpected_call()

    defp unexpected_call do
      send(
        Application.fetch_env!(:bridge_for_teams_core, :triage_delegation_provider_owner),
        :unexpected_model_call
      )

      raise "deterministic delegation integration must not call a model"
    end
  end

  defmodule PausedProvider do
    @behaviour SalixAgent.Tools.ImRouter
    defdelegate list_connects(agent_id), to: SalixIM.Provider
    defdelegate provider_manual(provider), to: SalixIM.Provider
    defdelegate provider_manual(provider, agent_id), to: SalixIM.Provider

    def call_api(agent_id, "slack", "slack.post_task_card", args) do
      record_call("slack", "slack.post_task_card", args)
      SalixIM.Provider.call_api(agent_id, "slack", "slack.post_task_card", args)
    end

    def call_api(agent_id, provider, method, args) do
      record_call(provider, method, args)

      send(Application.fetch_env!(:bridge_for_teams_core, :triage_delegation_provider_owner), {
        :paused_provider,
        self(),
        args
      })

      receive do
        :continue_provider -> SalixIM.Provider.call_api(agent_id, provider, method, args)
      after
        5_000 -> {:error, :test_provider_pause_timeout}
      end
    end

    defp record_call(provider, method, args) do
      send(
        Application.fetch_env!(:bridge_for_teams_core, :triage_delegation_provider_owner),
        {:provider_call, provider, method, args}
      )
    end
  end

  setup_all do
    # Keep the fake alive through the fixture's per-test source retirement.
    unless Process.whereis(SalixStore.S3.Fake), do: start_supervised!(SalixStore.S3.Fake)
    :ok
  end

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()
    SalixAgent.TestSupport.stop_all_agents()

    overrides = [
      {:bridge_for_teams_core, :salix_client, BridgeForTeams.Salix.Erpc},
      {:bridge_for_teams_core, @owner_key, self()},
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :group_context_mod, SalixAgent.TestSupport.GroupContext},
      {:salix_agent, :llm, NoModel},
      {:salix_agent, :im_provider_mod, PausedProvider},
      {:salix_im, :agent_delivery_mod, NoWakeDelivery},
      {:salix_im, :conversation_placement, SalixIM.ConversationPlacement.LocalFleet},
      {:salix_im, :task_create_mod, Salix.Bindings.AgentConversations},
      {:salix_im, :triage_delegation_mod, TriageDelegation}
    ]

    previous =
      Enum.map(overrides, fn {app, key, value} ->
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end)

    on_exit(fn ->
      for {app, key, old} <- previous do
        case old do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    # Runtime normally loads its reader before creating an obligation. This
    # seeded-obligation test starts at the Provider boundary instead.
    Code.ensure_loaded!(Fixture.ClickHouseReader)
    :ok = Fixture.install_clickhouse_reader!(self())

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SalixAgent.TestSupport.stop_all_agents()
    end)

    :ok
  end

  test "the production Provider retains one immutable Task across Router rotation and rejects stale or changed intent" do
    authority = Fixture.seed_authority!()
    project = Fixture.seed_project!(authority)
    router_id = authority["inbound_agent_id"]
    group_id = authority["group_id"]

    router =
      SalixAgent.TestSupport.create_control_agent!(router_id, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    worker = worker!(project, "Investigation Worker")
    other_worker = worker!(project, "Another eligible Worker")
    {:ok, session_id} = RuntimeIds.persisted_router_session_id(router)
    {:ok, _} = InternalSessionStore.prepare_create(router_id, session_id)
    root_ts = Fixture.root_ts()
    source = Fixture.mirrored_message(root_ts, "U_SOURCE", "Inspect the token-expired rollout.")
    Fixture.put_thread([source])
    original = seed_original!(authority, project)
    ref = "triage-delegation:#{original.obligation_id}:0"

    assert {:ok, prepared} = TriageDelegation.prepare(original, original.delegation, ref)
    assert {:ok, %{"disposition" => "routed"}} = TriageDelegation.commit(prepared)
    context = handoff_context!(router_id, session_id, ref)
    # This test starts at Provider admission, after the server's IFC decision.
    # Its evidence must survive the Triage-specific immutable source mapping.
    ifc_evidence = %{
      "sources_label" => ["scope|#{authority["connect_id"]}|#{authority["approved_channel_id"]}"],
      "requester" => "provider_user|#{authority["connect_id"]}|U_SOURCE"
    }

    context = Map.put(context, "ifc_evidence", ifc_evidence)
    assert_no_task!(group_id, ref)

    params = %{
      "triage_delegation_ref" => ref,
      "agent_id" => worker.salix_agent_id,
      "title" => "Inspect the rollout",
      "content" => "Read the token-expired rollout evidence and report only supported findings."
    }

    # The marker cannot authorize a different current activation or group.
    for bad_context <- [
          Map.put(context, "source_message_ids", []),
          put_in(context, ["trusted_origin", "triage_delegation", "group_id"], "foreign")
        ] do
      assert {:error, "triage_delegation_origin_invalid:" <> _} =
               create_task(router_id, params, bad_context, "wrong-source")

      assert_no_task!(group_id, ref)
    end

    # The BFT authority read must consult the canonical archive state before
    # admitting a Task. Keep the separate active Worker for changed-intent tests.
    archived = project |> worker!("Archived Worker") |> archive_agent_fixture!()

    assert {:error, "triage_delegation_authority_rejected:" <> _} =
             create_task(
               router_id,
               Map.put(params, "agent_id", archived.salix_agent_id),
               context,
               "archived-product-worker"
             )

    assert_no_task!(group_id, ref)

    # The real Freshness owner sees a new non-self source message beyond the
    # frozen cutoff; no reservation or canonical command may precede it.
    Fixture.put_thread([
      source,
      Fixture.mirrored_message(Fixture.ts(1), "U_SOURCE", "Pause; the incident changed.")
    ])

    assert {:error, "triage_delegation_source_stale: new_source_message"} =
             create_task(router_id, params, context, "stale-source")

    assert_no_task!(group_id, ref)
    Fixture.put_thread([source])

    assert {:ok, %{"conversation_id" => conversation_id, "message_id" => message_id}} =
             create_task(router_id, params, context, "first-create")

    assert_single_task!(group_id, conversation_id, message_id, original, params)
    assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
    assert task["source_refs"]["ifc_provenance"] == ifc_evidence["sources_label"]
    assert task["source_refs"]["ifc_members"] == [ifc_evidence["requester"]]

    assert {:ok, %{"conversation_id" => ^conversation_id, "message_id" => ^message_id}} =
             create_task(router_id, params, context, "lost-reply-retry")

    # Rotate through the actual Agent owner, then re-admit the same stable
    # source into the new Router Session. Session and tool-call identities
    # change without changing the obligation/ordinal or server-authored origin.
    assert {:ok, rotated} =
             AgentActor.switch_router_session(router_id, authority["tenant_id"], session_id)

    rotated_session_id = rotated["router_session_id"]
    refute rotated_session_id == session_id
    assert {:ok, %{"disposition" => "routed"}} = TriageDelegation.commit(prepared)

    rotated_context =
      handoff_context!(router_id, rotated_session_id, ref)
      |> Map.put("ifc_evidence", ifc_evidence)

    assert rotated_context["trusted_origin"] == context["trusted_origin"]

    assert {:ok, %{"conversation_id" => ^conversation_id, "message_id" => ^message_id}} =
             create_task(router_id, params, rotated_context, "rotated-session-create")

    assert_single_task!(group_id, conversation_id, message_id, original, params)

    for changed_params <- [
          Map.put(params, "agent_id", other_worker.salix_agent_id),
          Map.put(params, "content", "A different investigation command."),
          Map.put(params, "title", "A different investigation title")
        ] do
      assert {:error, conflict_json} =
               create_task(router_id, changed_params, rotated_context, "changed-intent")

      assert %{
               "error" => "triage_delegation_conflict",
               "existing_task" => %{
                 "disposition" => "created",
                 "conversation_id" => ^conversation_id
               }
             } = Jason.decode!(conflict_json)

      assert_single_task!(group_id, conversation_id, message_id, original, params)
    end

    assert {:ok, ^original} =
             TriageProductRuntime.fetch_delegation(
               original.namespace_key,
               original.obligation_id,
               0
             )

    refute_received :unexpected_model_call
    assert Fixture.collected_slack_calls() == []
  end

  test "generic Router updates cannot retarget product-owned investigation sources" do
    authority = Fixture.seed_authority!()
    project = Fixture.seed_project!(authority)
    router_id = authority["inbound_agent_id"]
    group_id = authority["group_id"]

    router =
      SalixAgent.TestSupport.create_control_agent!(router_id, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    worker = worker!(project, "Source-isolated Worker")
    {:ok, session_id} = RuntimeIds.persisted_router_session_id(router)
    {:ok, _} = InternalSessionStore.prepare_create(router_id, session_id)
    Fixture.put_thread([Fixture.mirrored_message(Fixture.root_ts(), "U_SOURCE", "Investigate.")])
    original = seed_original!(authority, project)
    ref = "triage-delegation:#{original.obligation_id}:0"
    assert {:ok, prepared} = TriageDelegation.prepare(original, original.delegation, ref)
    assert {:ok, %{"disposition" => "routed"}} = TriageDelegation.commit(prepared)
    context = handoff_context!(router_id, session_id, ref)

    params = %{
      "triage_delegation_ref" => ref,
      "agent_id" => worker.salix_agent_id,
      "title" => "Source isolation",
      "content" => "Investigate the original source."
    }

    assert {:ok, %{"conversation_id" => conversation_id, "message_id" => message_id}} =
             create_task(router_id, params, context, "source-isolation")

    assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)

    for {key, replacement} <- [
          {"triage_source_refs", ["slack://T_OTHER/C_OTHER/1787019000.000001/1787019000.000001"]},
          {"triage_obligation_id", "another-obligation"},
          {"triage_delegation_index", 1}
        ],
        requested <- [
          Map.put(task["source_refs"], key, replacement),
          Map.delete(task["source_refs"], key)
        ] do
      assert {:error, error} =
               Provider.call_api(router_id, "internal", "internal.update_conversation", %{
                 "connect_id" => "internal",
                 "params" => %{"conversation_id" => conversation_id, "source_refs" => requested}
               })

      assert error == "#{key} are product-owned"
      assert {:ok, unchanged} = Conversations.get_group_conversation(group_id, conversation_id)
      assert unchanged["source_refs"] == task["source_refs"]
    end

    assert {:ok, _} =
             Provider.call_api(router_id, "internal", "internal.update_conversation", %{
               "connect_id" => "internal",
               "params" => %{
                 "conversation_id" => conversation_id,
                 "source_refs" => Map.put(task["source_refs"], "ordinary_note", "editable")
               }
             })

    assert_single_task!(group_id, conversation_id, message_id, original, params)
    refute_received :unexpected_model_call
    assert Fixture.collected_slack_calls() == []
  end

  test "paused A and later B keep their own Worker read sources through async completion and retry" do
    authority = Fixture.seed_authority!()
    project = Fixture.seed_project!(authority)
    router_id = authority["inbound_agent_id"]
    group_id = authority["group_id"]

    router =
      SalixAgent.TestSupport.create_control_agent!(router_id, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    worker = worker!(project, "Shared investigation Worker")
    {:ok, session_id} = RuntimeIds.persisted_router_session_id(router)
    {:ok, _} = InternalSessionStore.prepare_create(router_id, session_id)

    # The finite mirror fixture exposes each exact frozen thread while its
    # corresponding real Provider check runs; no other check runs during the
    # switch. A pauses before Provider, while B is admitted and completes.
    source_a = Fixture.mirrored_message(Fixture.root_ts(), "U_A", "Investigate source A.")
    source_b = Fixture.mirrored_message(Fixture.ts(10), "U_B", "Investigate source B.")
    a = seed_original!(authority, project)
    b = seed_original!(authority, project, source_b["ts"])

    ctx =
      %{
        agent_id: router_id,
        session_id: session_id,
        tenant_id: authority["tenant_id"],
        group_id: group_id,
        role: "router",
        runtime_kind: :internal,
        llm_tool_envelope: true
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize("router", :internal, ctx)
      )

    admit = fn original ->
      ref = "triage-delegation:#{original.obligation_id}:0"
      assert {:ok, prepared} = TriageDelegation.prepare(original, original.delegation, ref)
      assert {:ok, %{"disposition" => "routed"}} = TriageDelegation.commit(prepared)
      handoff_context!(router_id, session_id, ref)["trusted_origin"]
    end

    params = fn original ->
      %{
        "connect_id" => "internal",
        "triage_delegation_ref" => "triage-delegation:#{original.obligation_id}:0",
        "agent_id" => worker.salix_agent_id,
        "title" => "Investigate " <> original.obligation_id,
        "content" => "Investigate with authorized evidence."
      }
    end

    call = fn id, original ->
      %{
        id: id,
        name: "call",
        args: %{"tool" => "im_api.internal.task.create", "params" => params.(original)}
      }
    end

    Fixture.put_thread([source_a])
    origin_a = admit.(a)

    ctx_a =
      Map.merge(ctx, %{
        trusted_origin: origin_a,
        trusted_origins: [origin_a],
        source_message_ids: [origin_a["source_message_id"]]
      })

    assert {[early_a], [pending_a]} =
             Tools.execute_with_async_window([call.("source-a", a)], ctx_a)

    assert_receive {:paused_provider, pid_a, args_a}, 1_000
    assert args_a["tool_context"]["trusted_origin"] == origin_a

    Fixture.put_thread([source_b])
    origin_b = admit.(b)

    ctx_ab =
      Map.merge(ctx, %{
        trusted_origin: origin_b,
        trusted_origins: [origin_a, origin_b],
        source_message_ids: [origin_a["source_message_id"], origin_b["source_message_id"]]
      })

    assert {[early_b], [pending_b]} =
             Tools.execute_with_async_window([call.("source-b", b)], ctx_ab)

    assert_receive {:paused_provider, pid_b, args_b}, 1_000
    assert args_b["tool_context"]["trusted_origin"] == origin_b
    send(pid_b, :continue_provider)
    assert {:ok, result_b} = DependencyJob.yield(pending_b.dependency_job, 2_000)
    refute result_b.error

    Fixture.put_thread([source_a])
    send(pid_a, :continue_provider)
    assert {:ok, result_a} = DependencyJob.yield(pending_a.dependency_job, 2_000)
    refute result_a.error

    # Commit the real pending and completion events after original inputs are
    # ACKed, then read the durable owner state back as a restart would.
    assert {:ok, before} = InternalSessionStore.read(router_id, session_id)
    {materialized, false, _} = InternalSession.materialize_pending_input_events(before)
    assert materialized != []
    stable = InternalSession.apply_events(before, materialized)

    completions =
      AsyncToolResults.internal_events(pending_b, result_b) ++
        AsyncToolResults.internal_events(pending_a, result_a)

    SalixAgent.TestSupport.stop_all_agents()

    assert {:ok, _} =
             InternalSessionStore.prepare_commit(
               router_id,
               session_id,
               materialized ++
                 [
                   %{
                     "type" => "ack",
                     "last_ack_message_id" => InternalSession.next_message_id(stable) - 1
                   }
                 ] ++
                 early_a.events ++ early_b.events ++ completions
             )

    assert {:ok, replayed} = InternalSessionStore.read(router_id, session_id)

    for {pending, origin} <- [{pending_a, origin_a}, {pending_b, origin_b}] do
      assert {:ok, completed} = InternalSession.lookup_async_call(replayed, pending.tool_call_id)
      assert completed["trusted_origin"] == origin
    end

    for {original, other, origin, source} <- [
          {a, b, origin_a, source_a},
          {b, a, origin_b, source_b}
        ] do
      ref = origin["source_message_id"]

      assert {:ok, %{"disposition" => "created", "conversation_id" => conversation_id}} =
               ConversationServer.lookup_task_create_request(group_id, ref)

      assert {:ok, [%{"message_id" => message_id}]} =
               Conversations.list_group_conversation_messages(group_id, conversation_id,
                 limit: 10
               )

      assert {:ok, %{"participants" => participants}} =
               Conversations.list_group_conversation_participants(group_id, conversation_id)

      participant = Enum.find(participants, &(&1["role_label"] == "worker"))
      worker_session_id = participant["payload"]["session_id"]
      assert summary = await_worker_summary!(worker.salix_agent_id, worker_session_id)
      assert summary["payload"]["content"] =~ hd(original.delegation["source_refs"])
      refute summary["payload"]["content"] =~ hd(other.delegation["source_refs"])

      assert {:ok, before_retry} =
               InternalSessionStore.read(worker.salix_agent_id, worker_session_id)

      Fixture.put_thread([source])

      retry_context = %{
        "session_id" => session_id,
        "source_message_ids" => [ref],
        "trusted_origin" => origin,
        "trusted_origins" => [origin]
      }

      assert {:ok, %{"conversation_id" => ^conversation_id, "message_id" => ^message_id}} =
               create_task(
                 router_id,
                 Map.delete(params.(original), "connect_id"),
                 retry_context,
                 "retry-" <> ref
               )

      assert {:ok, after_retry} =
               InternalSessionStore.read(worker.salix_agent_id, worker_session_id)

      after_retry_queue = InternalSession.get(after_retry, :input_queue)

      assert after_retry_queue == InternalSession.get(before_retry, :input_queue)
      assert length(after_retry_queue) == 2
    end

    refute_received :unexpected_model_call
    assert Fixture.collected_slack_calls() == []
  end

  test "mixed human and Triage calls keep separate canonical Tasks, async origins and card obligations" do
    authority = Fixture.seed_authority!()
    project = Fixture.seed_project!(authority)
    router_id = authority["inbound_agent_id"]
    group_id = authority["group_id"]

    router =
      SalixAgent.TestSupport.create_control_agent!(router_id, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    worker = worker!(project, "Mixed-source Worker")
    {:ok, session_id} = RuntimeIds.persisted_router_session_id(router)
    {:ok, _} = InternalSessionStore.prepare_create(router_id, session_id)
    Fixture.put_thread([Fixture.mirrored_message(Fixture.root_ts(), "U_SOURCE", "Investigate.")])
    original = seed_original!(authority, project)
    ref = "triage-delegation:#{original.obligation_id}:0"
    assert {:ok, prepared} = TriageDelegation.prepare(original, original.delegation, ref)
    assert {:ok, %{"disposition" => "routed"}} = TriageDelegation.commit(prepared)
    triage_origin = handoff_context!(router_id, session_id, ref)["trusted_origin"]

    human_id = "im_provider:slack:mixed-human-request"

    assert {:ok, _} =
             SalixIM.ProviderConnects.enqueue_group_router_im_provider_message(
               group_id,
               "Please investigate my separate request.",
               %{
                 "provider" => "slack",
                 "connect_id" => authority["connect_id"],
                 "channel_id" => authority["approved_channel_id"],
                 "thread_ts" => Fixture.ts(30),
                 "message_ts" => Fixture.ts(30),
                 "user_id" => "U_HUMAN",
                 "event_type" => "app_mention"
               },
               human_id
             )

    queued =
      Fixture.eventually(fn ->
        with {:ok, session} <- InternalSessionStore.read(router_id, session_id),
             true <- SalixAgent.InternalSession.input_dedupe_member?(session, human_id),
             do: session,
             else: (_ -> nil)
      end)

    assert queued

    human_input =
      Enum.find(
        SalixAgent.InternalSession.get(queued, :input_queue),
        &(&1["dedupe_key"] == human_id)
      )["payload"]

    human_origin = human_input["trusted_origin"]
    assert human_origin["source_actor_type"] == "provider_user"
    assert human_input["content"] =~ "source_message_id=" <> human_id

    ctx =
      %{
        agent_id: router_id,
        session_id: session_id,
        tenant_id: authority["tenant_id"],
        group_id: group_id,
        role: "router",
        runtime_kind: :internal,
        llm_tool_envelope: true,
        trusted_origin: triage_origin,
        trusted_origins: [human_origin, triage_origin],
        source_message_ids: [human_id, ref]
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize("router", :internal, ctx)
      )

    common = %{
      "connect_id" => "internal",
      "agent_id" => worker.salix_agent_id,
      "title" => "Investigate",
      "content" => "Investigate with authorized evidence."
    }

    human_params = Map.put(common, "source_message_id", human_id)
    triage_params = Map.put(common, "triage_delegation_ref", ref)

    call = fn id, params ->
      %{
        id: id,
        name: "call",
        args: %{"tool" => "im_api.internal.task.create", "params" => params}
      }
    end

    # Raw Provider admission remains fail-closed for an unselected mixed context.
    raw_context = Map.new(ctx, fn {key, value} -> {to_string(key), value} end)

    assert {:error, "triage_delegation_origin_invalid:" <> _} =
             create_task(router_id, human_params, raw_context, "unselected-mixed")

    assert_no_task!(group_id, ref)

    assert {[early_human, early_triage], [pending_human, pending_triage]} =
             Tools.execute_with_async_window(
               [call.("mixed-human", human_params), call.("mixed-triage", triage_params)],
               ctx
             )

    paused =
      for _ <- 1..2 do
        assert_receive {:paused_provider, pid, args}, 1_000
        {args["tool_context"]["source_message_id"], {pid, args}}
      end
      |> Map.new()

    completions =
      for {source, pending, expected_origin} <- [
            {human_id, pending_human, human_origin},
            {ref, pending_triage, triage_origin}
          ] do
        {pid, args} = Map.fetch!(paused, source)
        assert args["tool_context"]["trusted_origin"] == expected_origin
        assert args["tool_context"]["trusted_origins"] == [expected_origin]
        assert args["tool_context"]["source_message_ids"] == [source]
        send(pid, :continue_provider)
        assert {:ok, result} = DependencyJob.yield(pending.dependency_job, 2_000)
        refute result.error

        assert {:ok, events, _} =
                 SessionToolExecution.commit_async(
                   router_id,
                   session_id,
                   :internal,
                   pending,
                   result
                 )

        {source, Jason.decode!(result.content)["conversation_id"], events}
      end

    [{^human_id, human_task, human_events}, {^ref, triage_task, triage_events}] = completions
    refute human_task == triage_task
    assert {:ok, human} = Conversations.get_group_conversation(group_id, human_task)
    refute Map.has_key?(human["source_refs"], "triage_obligation_id")
    assert {:ok, triage} = Conversations.get_group_conversation(group_id, triage_task)
    assert triage["source_refs"]["triage_obligation_id"] == original.obligation_id
    assert triage["source_refs"]["triage_source_refs"] == original.delegation["source_refs"]
    refute Enum.any?(human_events, &(&1["type"] == "provider_card_obligation_added"))
    assert Enum.count(human_events, &(&1["type"] == "provider_reply_obligation_resolved")) == 2
    refute Enum.any?(triage_events, &(&1["type"] == "provider_card_obligation_added"))

    {materialized, false, _} = InternalSession.materialize_pending_input_events(queued)
    SalixAgent.TestSupport.stop_all_agents()

    assert {:ok, _} =
             InternalSessionStore.prepare_commit(
               router_id,
               session_id,
               materialized ++
                 early_human.events ++ early_triage.events ++ human_events ++ triage_events
             )

    assert {:ok, replayed} = InternalSessionStore.read(router_id, session_id)

    assert SalixAgent.ProviderReplyObligation.pending(replayed) == []

    refute Enum.any?(
             SalixAgent.ProviderReplyObligation.pending(replayed),
             &(&1["conversation_id"] == triage_task)
           )

    for {pending, origin} <- [{pending_human, human_origin}, {pending_triage, triage_origin}] do
      assert {:ok, completed} = InternalSession.lookup_async_call(replayed, pending.tool_call_id)
      assert completed["trusted_origins"] == [origin]
    end

    # Both creates have settled, so their synchronous child dispatches are
    # complete. Inspect the full provider record, not asynchronous HTTP timing.
    calls =
      for _ <- 1..3 do
        assert_receive {:provider_call, provider, method, args}
        {provider, method, args}
      end

    refute_received {:provider_call, _, _, _}

    assert Enum.count(calls, fn {p, m, _} -> p == "internal" and m == "internal.task.create" end) ==
             2

    assert [{"slack", "slack.post_task_card", card}] =
             Enum.reject(calls, fn {p, m, _} ->
               p == "internal" and m == "internal.task.create"
             end)

    assert card["connect_id"] == authority["connect_id"]
    assert card["params"]["conversation_id"] == human_task
    assert card["params"]["channel"] == authority["approved_channel_id"]
    assert card["params"]["thread_ts"] == Fixture.ts(30)
    assert card["tool_context"]["trusted_origin"] == human_origin
    assert card["tool_context"]["source_message_id"] == human_id
    refute_received :unexpected_model_call
  end

  defp create_task(router_id, params, context, tool_call_id) do
    Provider.call_api(router_id, "internal", "internal.task.create", %{
      "connect_id" => "internal",
      "params" => params,
      "tool_context" => context,
      "tool_call_id" => tool_call_id
    })
  end

  defp handoff_context!(router_id, session_id, ref) do
    session =
      Fixture.eventually(fn ->
        with {:ok, session} <- InternalSessionStore.read(router_id, session_id),
             true <- SalixAgent.InternalSession.input_dedupe_member?(session, ref),
             do: session,
             else: (_ -> nil)
      end)

    assert session

    # no_wake commits the input queue, not the model transcript. Read the exact
    # owner-persisted payload that normal activation would later materialize.
    assert [%{"dedupe_key" => ^ref, "wake" => false, "payload" => incoming}] =
             Enum.filter(
               SalixAgent.InternalSession.get(session, :input_queue),
               &(&1["dedupe_key"] == ref)
             )

    origin = incoming["trusted_origin"]
    assert origin["source_actor_type"] == "provider_system"
    assert origin["triage_delegation"]["request_id"] == ref

    %{
      "session_id" => session_id,
      "source_message_id" => ref,
      "source_message_ids" => [ref],
      "trusted_origin" => origin,
      "trusted_origins" => [origin]
    }
  end

  defp assert_no_task!(group_id, ref) do
    assert {:ok, %{"disposition" => "not_created"}} =
             ConversationServer.lookup_task_create_request(group_id, ref)

    assert {:ok, %{"data" => [], "has_more" => false}} =
             Conversations.list_group_conversations(group_id, kind: "agent_task", limit: 10)
  end

  defp assert_single_task!(group_id, conversation_id, message_id, original, params) do
    assert {:ok, %{"data" => [%{"conversation_id" => ^conversation_id}], "has_more" => false}} =
             Conversations.list_group_conversations(group_id, kind: "agent_task", limit: 10)

    assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
    assert task["title"] == params["title"]
    assert task["source_refs"]["triage_obligation_id"] == original.obligation_id
    assert task["source_refs"]["triage_delegation_index"] == 0
    refute Map.has_key?(task["source_refs"], "task_reply_source")
    assert task["source_refs"]["triage_source_refs"] == original.delegation["source_refs"]
    refute Map.has_key?(task["source_refs"], "origin_session_id")

    assert {:ok, [%{"message_id" => ^message_id} = command]} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert command["content"] == [%{"type" => "text", "text" => params["content"]}]
    assert command["client_request_id"] == "delegate-task-" <> conversation_id

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group_id, conversation_id)

    assert [%{"agent_id" => chosen} = worker] =
             Enum.filter(participants, &(&1["role_label"] == "worker"))

    assert chosen == params["agent_id"]
    session_id = worker["payload"]["session_id"]

    assert summary = await_worker_summary!(chosen, session_id)

    source_context = summary["payload"]["content"]
    assert source_context =~ "Read-only investigation sources"
    assert source_context =~ hd(original.delegation["source_refs"])
    refute source_context =~ original.obligation_id
    refute source_context =~ "triage_source_refs"
    refute source_context =~ "triage_delegation_index"
    refute source_context =~ "connect_generation"

    assert {:ok, session} = InternalSessionStore.read(chosen, session_id)
    assert length(SalixAgent.InternalSession.get(session, :input_queue)) == 2

    assert Enum.map(
             SalixAgent.InternalSession.get(session, :input_queue),
             &get_in(&1, ["payload", "role"])
           ) == ["summary", "user"]
  end

  defp await_worker_summary!(agent_id, session_id) do
    Fixture.eventually(fn ->
      with {:ok, session} <- InternalSessionStore.read(agent_id, session_id) do
        Enum.find(SalixAgent.InternalSession.get(session, :input_queue), fn item ->
          get_in(item, ["payload", "role"]) == "summary" and
            String.ends_with?(item["dedupe_key"] || "", ":source-context")
        end)
      else
        _ -> nil
      end
    end)
  end

  defp worker!(project, name) do
    agent_id = Ids.new_agent_id(project.salix_group_id)

    SalixAgent.TestSupport.create_control_agent!(agent_id, %{
      "name" => name,
      "role" => "worker",
      "runtime_config" => %{"kind" => "internal"}
    })

    Repo.insert!(%ProductAgent{
      project_id: project.id,
      salix_agent_id: agent_id,
      role: "worker",
      configuration_authority: "salix"
    })
  end

  defp seed_original!(authority, project, root_ts \\ Fixture.root_ts()) do
    run_id = "provider-delegation-" <> ULID.generate()
    namespace = "triage-delegation-provider-" <> run_id
    namespace_key = TriageKeys.namespace_key(namespace)
    router = Repo.get_by!(ProductAgent, salix_agent_id: authority["inbound_agent_id"])
    {:ok, root_ts_us} = SalixIM.SlackMessageMirror.Row.slack_ts_micros(root_ts)

    route_scope =
      authority
      |> Map.take(~w(tenant_id group_id connect_id connect_generation workspace_id))
      |> Map.put("channel_id", authority["approved_channel_id"])
      |> Map.put("root_thread_ts", root_ts)

    assert {:ok, identity} =
             ThreadRouteOwner.clickhouse_root_claim_identity(route_scope, root_ts_us)

    assert {:ok, :triage} = ThreadRouteOwner.claim_triage(route_scope, identity)

    base = %{
      "schema" => "comma.triage-product-obligation.v1",
      "namespace" => namespace,
      "fence_key" => "provider-fence://#{run_id}",
      "run_id" => run_id,
      "settled_at" => 1,
      "product_identity" => %{
        "project_id" => project.id,
        "project_salix_group_id" => project.salix_group_id,
        "agent_id" => router.id,
        "salix_agent_id" => router.salix_agent_id
      },
      "target" => %{
        "connect_id" => authority["connect_id"],
        "connect_generation" => authority["connect_generation"],
        "workspace_id" => authority["workspace_id"],
        "channel_id" => authority["approved_channel_id"],
        "thread_ts" => root_ts
      },
      "source_authority" => [
        %{
          "message_ts" => root_ts,
          "message_ts_us" => root_ts_us,
          "observed_version" => root_ts_us * 2
        }
      ],
      "source_messages" => [
        %{"actor_kind" => "human", "message_ts" => root_ts, "excerpt" => "Token-expired rollout."}
      ],
      "target_cutoff" => %{"event_message_timestamps" => [root_ts]},
      "communication" => %{"kind" => "silence", "reason" => "investigation", "source_refs" => []},
      "context_candidates" => [],
      "delegations" => [
        %{
          "task" => "Inspect the token-expired rollout",
          "source_refs" => ["slack://T_ATLAS/C_ATLAS/#{root_ts}/#{root_ts}"]
        }
      ]
    }

    {:ok, canonical_payload} = CanonicalJSON.encode(base)
    obligation_id = "triage-product-" <> CanonicalJSON.sha256(canonical_payload)
    payload = Map.put(base, "obligation_id", obligation_id)
    assert ProductObligation.valid?(payload)

    SalixStore.Repo.query!(
      "INSERT INTO triage_runs (record_key, namespace_key, run_id, body) VALUES ($1,$2,$3,$4)",
      [
        "provider-run://#{run_id}",
        namespace_key,
        run_id,
        %{
          "schema" => "comma.triage-run.v1",
          "run_id" => run_id,
          "authoritative" => true,
          "created_at" => 1,
          "status" => "evaluated"
        }
      ]
    )

    SalixStore.Repo.query!(
      """
      INSERT INTO triage_product_obligations (namespace_key, run_id, obligation_id, payload, state)
      VALUES ($1,$2,$3,$4,'applied')
      """,
      [namespace_key, run_id, obligation_id, payload]
    )

    assert {:ok, original} =
             TriageProductRuntime.fetch_delegation(namespace_key, obligation_id, 0)

    original
  end
end
