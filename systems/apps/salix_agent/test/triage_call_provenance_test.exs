defmodule SalixAgent.TriageCallProvenanceTest do
  @moduledoc """
  Regression for the old activation-wide/latest-origin stamp: a Task selected
  from A could execute and resume as B, and discovery/restart lost A entirely.
  Uses the actual tool dispatcher, owner stores and actors with local provider
  seams; no model or provider network calls are made.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{
    AsyncToolResults,
    DependencyJob,
    ExternalSessionActor,
    ExternalSessionStore,
    InternalSessionStore,
    Repair,
    SessionToolExecution,
    ToolCallProvenance,
    ToolDisclosure,
    Tools
  }

  alias SalixAgent.InternalSession
  alias SalixStore.{Ids, RuntimeIds, S3}

  @task_create "im_api.internal.task.create"
  @session_id "ses1_0000000000000000908"
  @device_runtime_id RuntimeIds.device_runtime_id("triage-device", "codex", "triage-runtime")

  defmodule Provider do
    @behaviour SalixAgent.Tools.ImRouter

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"provider" => "internal", "connect_id" => "internal"}]}

    @impl true
    def provider_manual("internal") do
      {:ok,
       %{
         "provider" => "internal",
         "apis" => [
           %{
             "name" => "internal.task.create",
             "roles" => ["router"],
             "safety" => "write",
             "description" => "Create a Task for one selected source.",
             "required_params" => ["content"],
             "parameters" => %{
               "content" => "Task command",
               "source_message_id" => "Current human source selector",
               "triage_delegation_ref" => "Current Triage handoff selector"
             }
           }
         ]
       }}
    end

    def provider_manual(_), do: {:error, :unsupported}

    @impl true
    def call_api(_agent_id, "internal", "internal.task.create", args) do
      send(Application.fetch_env!(:salix_agent, :triage_call_test_owner), {
        :triage_provider_call,
        self(),
        args
      })

      receive do
        {:triage_provider_return, result} -> {:ok, result}
      after
        5_000 -> {:error, :test_provider_timeout}
      end
    end
  end

  defmodule OAuthStore do
    def agent_oauth_context(agent_id) do
      {:ok, %{group_id: SalixStore.Ids.group_id_from_agent!(agent_id)}}
    end

    def bindings_for_group(_group_id), do: {:ok, []}
    def provider_app(_tenant, _provider), do: {:error, :not_configured}
    def public_base_url, do: nil
    def delete_binding(_tenant, _group_id, _binding_id), do: :ok
  end

  defmodule RuntimeEnvironment do
    @behaviour SalixAgent.RuntimeEnvironment

    @impl true
    def resolve_external_runtime_binding(config, _tenant, _group) do
      {:ok,
       Map.merge(config, %{
         "connector_id" => "triage-connector",
         "connector_run_id" => "triage-connector-run",
         "command" => "codex"
       })}
    end

    @impl true
    def external_runtime_binding_status(config, _tenant, _group),
      do:
        {:ok,
         %{
           "status" => "ready",
           "connector_run_id" => "triage-connector-run",
           "device_id" => config["device_id"],
           "device_runtime_id" => config["device_runtime_id"]
         }}
  end

  defmodule Runtime do
    @behaviour SalixAgent.ExternalRuntime

    @impl true
    def run(request) do
      send(Application.fetch_env!(:salix_agent, :triage_call_test_owner), {
        :triage_runtime_request,
        self(),
        request
      })

      receive do
        :triage_runtime_accept -> {:accepted, %{"dispatch_id" => request.dispatch_id}}
      after
        5_000 -> {:error, :test_runtime_timeout}
      end
    end
  end

  setup do
    overrides = [
      {:salix_store, :s3_backend, S3.Fake},
      {:salix_agent, :im_provider_mod, Provider},
      {:salix_agent, :oauth_store_mod, OAuthStore},
      {:salix_agent, :runtime_environment_mod, RuntimeEnvironment},
      {:salix_agent, :external_runtime_driver, Runtime},
      {:salix_agent, :llm, SalixAgent.LLM.Mock},
      {:salix_agent, :triage_call_test_owner, self()},
      {:salix_agent, :group_context_mod, SalixAgent.TestSupport.GroupContext}
    ]

    previous =
      Enum.map(overrides, fn {app, key, _} -> {app, key, Application.fetch_env(app, key)} end)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    Enum.each(overrides, fn {app, key, value} -> Application.put_env(app, key, value) end)
    SalixAgent.TestSupport.stop_all_agents()
    if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)
    start_supervised!(SalixAgent.LLM.Mock)
    SalixAgent.LLM.Mock.script([])

    agent_id = SalixAgent.TestSupport.new_agent_id()
    agent = SalixAgent.TestSupport.create_control_agent!(agent_id, %{"role" => "router"})
    group_id = agent["group_id"]

    ctx =
      %{
        agent_id: agent_id,
        session_id: @session_id,
        tenant_id: Ids.tenant_id_from_group!(group_id),
        group_id: group_id,
        role: "router",
        runtime_kind: :internal,
        llm_tool_envelope: true
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx = Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("router", :internal, ctx))
    a = origin(ctx, "obligation-a", 0)
    b = origin(ctx, "obligation-b", 0)
    {:ok, ctx: activation(ctx, [a, b]), a: a, b: b, router_session_id: agent["router_session_id"]}
  end

  test "explicit A selects A despite latest B and distinguishes two ordinals", %{ctx: ctx, a: a} do
    assert {:ok, selected} = ToolCallProvenance.select(task_call("a", a), ctx)
    assert selected.trusted_origin == a
    assert selected.trusted_origins == [a]
    assert selected.source_message_ids == [ref(a)]

    second = origin(ctx, "obligation-a", 1)
    both = activation(ctx, [a, second])

    for origin <- [a, second] do
      assert {:ok, selected} = ToolCallProvenance.select(task_call("ordinal", origin), both)
      assert selected.trusted_origin == origin
    end
  end

  test "missing, forged, duplicate and mismatched sources never reach a provider", %{
    ctx: ctx,
    a: a
  } do
    wrong_router = put_in(a, ["triage_delegation", "router_agent_id"], "other-router")
    wrong_group = put_in(a, ["triage_delegation", "group_id"], "other-group")
    wrong_source = Map.put(a, "source_message_id", "other-source")
    wrong_actor = Map.put(a, "source_actor_type", "provider_user")
    invalid_slot = put_in(a, ["triage_delegation", "index"], 2)
    no_sources = Map.put(ctx, :source_message_ids, [])

    cases = [
      {ctx, task_params(nil), "triage_delegation_ref_required"},
      {ctx, task_params("copied-ref"), "triage_delegation_ref_unknown"},
      {activation(ctx, []), task_params(ref(a)), "triage_delegation_ref_unknown"},
      {activation(ctx, [a, a]), task_params(ref(a)), "triage_delegation_ref_ambiguous"},
      {activation(ctx, [wrong_router]), task_params(ref(a)), "triage_delegation_origin_invalid"},
      {activation(ctx, [wrong_group]), task_params(ref(a)), "triage_delegation_origin_invalid"},
      {activation(ctx, [wrong_source]), task_params(ref(a)), "triage_delegation_origin_invalid"},
      {activation(ctx, [wrong_actor]), task_params(ref(a)), "triage_delegation_origin_invalid"},
      {activation(ctx, [invalid_slot]), task_params(ref(a)), "triage_delegation_origin_invalid"},
      {no_sources, task_params(ref(a)), "triage_delegation_origin_invalid"}
    ]

    for {context, params, expected} <- cases do
      assert [synchronous] =
               Tools.execute([envelope("reject-sync", @task_create, params)], context)

      assert synchronous.error_class == expected

      assert {[result], []} =
               Tools.execute_with_async_window(
                 [envelope("reject", @task_create, params)],
                 context
               )

      assert result.error
      assert result.error_class == expected
      refute_receive {:triage_provider_call, _, _}, 0
    end
  end

  test "mixed human and Triage activation requires a selector while ordinary calls are unchanged",
       %{ctx: ctx, a: a} do
    human = %{"source_actor_type" => "provider_user", "source_message_id" => "human-input"}
    mixed = activation(ctx, [a, human])

    assert {:error, "triage_delegation_ref_required"} =
             ToolCallProvenance.select(task_call("human", nil), mixed)

    ordinary = activation(ctx, [human])
    assert {:ok, ^ordinary} = ToolCallProvenance.select(task_call("human", nil), ordinary)
    assert {:ok, ^mixed} = ToolCallProvenance.select(%{name: "agent.list", args: %{}}, mixed)
  end

  test "an explicit human source isolates Task admission without borrowing a Triage origin", %{
    ctx: ctx,
    a: a
  } do
    human = %{
      "source_actor_type" => "provider_user",
      "source_message_id" => "human-input",
      "agent_group_id" => ctx.group_id
    }

    mixed = activation(ctx, [human, a])
    params = Map.put(task_params(nil), "source_message_id", "human-input")
    call = %{id: "human", name: @task_create, args: params}

    assert {:ok, selected} = ToolCallProvenance.select(call, mixed)
    assert selected.trusted_origin == human
    assert selected.trusted_origins == [human]
    assert selected.source_message_id == "human-input"
    assert selected.source_message_ids == ["human-input"]

    for {context, args, reason} <- [
          {mixed, Map.put(params, "source_message_id", "invented"), "task_source_unknown"},
          {mixed, Map.put(params, "source_message_id", ref(a)), "task_source_invalid"},
          {mixed, Map.put(params, "triage_delegation_ref", ref(a)), "task_source_conflict"},
          {Map.put(mixed, :source_message_ids, [ref(a)]), params, "task_source_invalid"},
          {activation(ctx, [human, human, a]), params, "task_source_ambiguous"},
          {activation(ctx, [Map.put(human, "agent_group_id", "foreign"), a]), params,
           "task_source_invalid"},
          {activation(ctx, [Map.put(human, "source_actor_type", "provider_system"), a]), params,
           "task_source_invalid"}
        ] do
      assert {:error, ^reason} = ToolCallProvenance.select(%{call | args: args}, context)
    end

    assert {[early], [pending]} =
             Tools.execute_with_async_window([envelope("human", @task_create, params)], mixed)

    assert_receive {:triage_provider_call, pid, args}, 1_000
    assert args["tool_context"]["trusted_origins"] == [human]
    send(pid, {:triage_provider_return, %{"conversation_id" => "human-task"}})
    assert {:ok, result} = DependencyJob.yield(pending.dependency_job, 1_000)
    refute result.error
    assert_source(pending, [human])

    events = early.events ++ AsyncToolResults.internal_events(pending, result)
    assert_source(List.last(events)["payload"], [human])
    assert_source(Enum.find(events, &(&1["type"] == "async_tool_call_completed")), [human])
  end

  test "batched A and B freeze their own execution, pending, start and terminal provenance", %{
    ctx: ctx,
    a: a,
    b: b
  } do
    calls = [
      envelope("create-a", @task_create, task_params(ref(a))),
      envelope("create-b", @task_create, task_params(ref(b)))
    ]

    assert {[early_a, early_b], [pending_a, pending_b]} =
             Tools.execute_with_async_window(calls, ctx)

    received =
      for _ <- 1..2 do
        assert_receive {:triage_provider_call, pid, args}, 1_000
        {get_in(args, ["params", "triage_delegation_ref"]), {pid, args}}
      end
      |> Map.new()

    for {origin, early, pending} <- [{a, early_a, pending_a}, {b, early_b, pending_b}] do
      {pid, args} = Map.fetch!(received, ref(origin))
      assert args["tool_context"]["trusted_origin"] == origin
      assert args["tool_context"]["trusted_origins"] == [origin]
      assert args["tool_context"]["source_message_ids"] == [ref(origin)]
      assert_source(pending, [origin])
      assert_source(Enum.find(early.events, &(&1["type"] == "async_tool_call_started")), [origin])
      send(pid, {:triage_provider_return, %{"created" => true}})
      assert {:ok, completed} = DependencyJob.yield(pending.dependency_job, 1_000)

      internal = AsyncToolResults.internal_events(pending, completed)
      assert_source(Enum.find(internal, &(&1["type"] == "async_tool_call_completed")), [origin])
      assert_source(List.last(internal)["payload"], [origin])
      assert_source(List.last(AsyncToolResults.external_events(pending, completed)), [origin])
    end

    wait = Enum.find_value(early_a.events ++ early_b.events, & &1["wait"])
    assert_source(wait, [a, b])
  end

  test "async agent.list retains A and B after ACK, completion materialization and store replay",
       %{ctx: ctx, a: a, b: b} do
    pause_worker_discovery!(ctx)

    assert {[early], [pending]} =
             Tools.execute_with_async_window(
               [envelope("discovery", "agent.list", %{"limit" => 3})],
               ctx
             )

    await(&S3.Fake.paused?/0)
    assert_source(pending, [a, b])
    assert :ok = S3.Fake.release_pause()
    assert {:ok, completed} = DependencyJob.yield(pending.dependency_job, 1_000)
    refute completed.error

    original_inputs =
      Enum.with_index([a, b], 1)
      |> Enum.map(fn {origin, id} ->
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => id,
          "role" => "user",
          "source_message_id" => ref(origin),
          "trusted_origin" => origin,
          "content" => "Original handoff"
        }
      end)

    events =
      original_inputs ++
        [%{"type" => "ack", "last_ack_message_id" => 2}] ++
        early.events ++ AsyncToolResults.internal_events(pending, completed)

    state = InternalSession.new(ctx.agent_id, @session_id) |> InternalSession.apply_events(events)
    {materialized, true, _} = InternalSession.materialize_pending_input_events(state)
    state = InternalSession.apply_events(state, materialized)
    assert :ok = InternalSessionStore.prepare_seed(ctx.agent_id, state)
    assert {:ok, restored} = InternalSessionStore.read(ctx.agent_id, @session_id)
    ids = ToolCallProvenance.current_source_ids(restored)
    assert MapSet.new(ids) == MapSet.new([ref(a), ref(b)])

    candidates =
      Enum.flat_map(
        InternalSession.get(restored, :messages),
        &ToolCallProvenance.message_origins(&1, ids)
      )
      |> Enum.uniq()

    assert MapSet.new(candidates) == MapSet.new([a, b])

    for origin <- [a, b] do
      assert {:ok, _early, [task_pending], _events, _observed} =
               SessionToolExecution.execute(
                 ctx.agent_id,
                 @session_id,
                 :internal,
                 [],
                 @task_create,
                 task_params(ref(origin))
               )

      assert_receive {:triage_provider_call, provider_pid, args}, 1_000
      assert args["tool_context"]["trusted_origin"] == origin
      assert_source(task_pending, [origin])
      send(provider_pid, {:triage_provider_return, %{"created" => true}})
      assert {:ok, result} = DependencyJob.yield(task_pending.dependency_job, 1_000)
      refute result.error
    end

    acked =
      InternalSession.apply_event(restored, %{
        "type" => "ack",
        "last_ack_message_id" => InternalSession.next_message_id(restored) - 1
      })

    assert ToolCallProvenance.current_source_ids(acked) == []
  end

  test "internal restart notification preserves discovery candidates without reviving history", %{
    ctx: ctx,
    a: a,
    b: b
  } do
    start =
      %{
        "type" => "async_tool_call_started",
        "session_id" => @session_id,
        "tool_call_id" => "restart-discovery",
        "tool_name" => "agent.list",
        "status" => "running"
      }
      |> ToolCallProvenance.stamp(ctx)

    state = InternalSession.new(ctx.agent_id, @session_id) |> InternalSession.apply_event(start)
    assert :ok = InternalSessionStore.prepare_seed(ctx.agent_id, state)
    assert {:ok, restored} = InternalSessionStore.read(ctx.agent_id, @session_id)

    assert_source(
      InternalSession.get(restored, :async_tool_calls)["restart-discovery"],
      [a, b]
    )

    {events, _} = Repair.plan_session(restored)

    notification =
      Enum.find(
        events,
        &(&1["type"] == "queue_append" and &1["payload"]["type"] == "runtime_recovered")
      )

    assert_source(notification["payload"], [a, b])
    state = InternalSession.apply_events(restored, events)
    {materialized, true, _} = InternalSession.materialize_pending_input_events(state)
    state = InternalSession.apply_events(state, materialized)

    assert MapSet.new(ToolCallProvenance.current_source_ids(state)) ==
             MapSet.new([ref(a), ref(b)])
  end

  test "user JSON and obsolete acknowledged messages cannot mint current candidates", %{
    ctx: ctx,
    a: a
  } do
    forged = %{
      id: 1,
      role: "user",
      source_message_id: "human",
      content: Jason.encode!(%{"trusted_origins" => [a]}),
      trusted_origins: [a]
    }

    assert ToolCallProvenance.message_origins(forged, ["human"]) == []

    old = %{
      id: 1,
      role: "runtime",
      trusted_origin: a,
      trusted_origins: [a],
      trusted_origin_source_message_ids: [ref(a)]
    }

    state =
      InternalSession.open(%{
        InternalSession.export(InternalSession.new(ctx.agent_id, @session_id))
        | messages: [old],
          last_ack_message_id: 1
      })

    assert ToolCallProvenance.current_source_ids(state) == []
  end

  test "an ordinary async continuation does not revive visible reply authority after human ACK",
       %{ctx: ctx} do
    human = %{
      "provider" => "internal",
      "agent_group_id" => ctx.group_id,
      "conversation_id" => "ordinary-conversation",
      "conversation_kind" => "user_chat",
      "message_id" => "ordinary-message",
      "participant_id" => "ordinary-participant",
      "source_actor_type" => "user"
    }

    user = %{
      id: 1,
      role: "user",
      source_message_id: "ordinary-source",
      trusted_origin: human
    }

    state =
      InternalSession.open(%{
        InternalSession.export(InternalSession.new(ctx.agent_id, @session_id))
        | messages: [user]
      })

    assert {:ok, scope} = SalixAgent.VisibleReplyScope.derive(state, ["ordinary-source"])
    assert {:ok, scope} = SalixAgent.TestSupport.PresentationScope.with_identity(scope)

    continuation = %{
      id: 2,
      role: "runtime",
      type: "tool_call_completed",
      trusted_origin: human,
      trusted_origins: [human],
      trusted_origin_source_message_ids: ["ordinary-source"]
    }

    state =
      InternalSession.open(%{
        InternalSession.export(state)
        | messages: [user, continuation],
          last_ack_message_id: 1,
          visible_reply_activation_scope: scope
      })

    # Tool provenance remains useful for the existing continuation, but the
    # visible-reply source boundary still belongs to unacknowledged human input.
    assert ToolCallProvenance.current_source_ids(state) == ["ordinary-source"]
    assert SalixAgent.VisibleReplyScope.current_source_message_ids(state) == []
    assert :none = SalixAgent.VisibleReplyScope.derive(state, [])
    assert :none = SalixAgent.VisibleReplyScope.derive(state, ["ordinary-source"])
  end

  test "external actor retains A after B was last and restart resumes the exact call", %{ctx: ctx} do
    {actor, external_ctx} = external_actor(ctx)
    a = origin(external_ctx, "external-a", 0)
    b = origin(external_ctx, "external-b", 0)
    stage_external(actor, a, true)
    stage_external(actor, b, false)
    accept_runtime(external_ctx)

    assert {:ok, early} =
             ExternalSessionActor.execute_tool(actor, @task_create, task_params(ref(a)))

    assert early.status == "async_running"
    assert_receive {:triage_provider_call, provider_pid, args}, 1_000
    assert args["tool_context"]["trusted_origin"] == a
    assert args["tool_context"]["trusted_origins"] == [a]

    assert {:ok, state} =
             ExternalSessionStore.get_session_record(external_ctx.agent_id, @session_id)

    assert_source(state["async_tool_calls"][early.id], [a])

    GenServer.stop(actor, :normal)

    assert {:ok, restarted} =
             ExternalSessionActor.start_link(
               agent_id: external_ctx.agent_id,
               session_id: @session_id,
               process_on_init: true
             )

    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted, :normal) end)

    assert_receive {:triage_runtime_request, runtime_pid, request}, 2_000
    continuation = Enum.find(request.input_messages, &(&1["role"] == "runtime"))
    assert_source(continuation, [a])
    send(runtime_pid, :triage_runtime_accept)
    refute Process.alive?(provider_pid)

    assert {:ok, public} = ExternalSessionStore.get_session(external_ctx.agent_id, @session_id)

    for call <- Map.values(public["async_tool_calls"] || %{}) do
      refute Map.has_key?(call, "trusted_origin")
      refute Map.has_key?(call, "trusted_origins")
    end
  end

  test "external async discovery preserves both sources for later individual Task calls", %{
    ctx: ctx
  } do
    {actor, external_ctx} = external_actor(ctx)
    a = origin(external_ctx, "external-discovery", 0)
    b = origin(external_ctx, "external-discovery", 1)
    stage_external(actor, a, true)
    stage_external(actor, b, false)
    accept_runtime(external_ctx)

    pause_worker_discovery!(external_ctx)
    assert {:ok, early} = ExternalSessionActor.execute_tool(actor, "agent.list", %{"limit" => 3})
    assert early.status == "async_running"
    await(&S3.Fake.paused?/0)
    assert :ok = S3.Fake.release_pause()
    assert_receive {:triage_runtime_request, runtime_pid, request}, 2_000
    continuation = Enum.find(request.input_messages, &(&1["role"] == "runtime"))
    assert_source(continuation, [a, b])
    send(runtime_pid, :triage_runtime_accept)

    await(fn ->
      {:ok, state} = ExternalSessionStore.get_session_record(external_ctx.agent_id, @session_id)
      state["input_message_queue"] == []
    end)

    for origin <- [a, b] do
      assert {:ok, early} =
               ExternalSessionActor.execute_tool(actor, @task_create, task_params(ref(origin)))

      assert early.status == "async_running"
      assert_receive {:triage_provider_call, provider_pid, args}, 1_000
      assert args["tool_context"]["trusted_origin"] == origin
      assert args["tool_context"]["source_message_ids"] == [ref(origin)]

      assert {:ok, state} =
               ExternalSessionStore.get_session_record(external_ctx.agent_id, @session_id)

      assert_source(state["async_tool_calls"][early.id], [origin])
      send(provider_pid, {:triage_provider_return, %{"created" => true}})
    end
  end

  defp pause_worker_discovery!(ctx) do
    worker_id = Ids.new_agent_id(ctx.group_id)
    SalixAgent.TestSupport.create_control_agent!(worker_id, %{"role" => "worker"})
    # agent.list now reads the canonical Worker page, not OAuth context.
    # Pause that real read so both source identities cross an async boundary.
    assert :ok = S3.Fake.set_fault({:pause, :get, SalixStore.Keys.ctl_agent(worker_id)})
  end

  test "Round resumes both discovery sources from a runtime notification after original input ACK",
       %{ctx: ctx, a: a, b: b, router_session_id: session_id} do
    pending =
      %{session_id: session_id, tool_call_id: "before-round", tool_name: "agent.list"}
      |> ToolCallProvenance.stamp(ctx)

    completed = %{error: false, content: "Found eligible workers", status: "completed"}

    state =
      InternalSession.new(ctx.agent_id, session_id)
      |> InternalSession.apply_events(AsyncToolResults.internal_events(pending, completed))

    {materialized, true, _} = InternalSession.materialize_pending_input_events(state)
    state = InternalSession.apply_events(state, materialized)
    assert :ok = InternalSessionStore.prepare_seed(ctx.agent_id, state)

    SalixAgent.LLM.Mock.script([
      {:assistant, "",
       [
         envelope("round-a", @task_create, task_params(ref(a))),
         envelope("round-b", @task_create, task_params(ref(b)))
       ]},
      {:final, "handled"}
    ])

    assert :ok = SalixAgent.InternalSessionFleet.wake(ctx.agent_id, session_id)

    actual =
      for _ <- 1..2 do
        assert_receive {:triage_provider_call, provider_pid, args}, 2_000
        origin = args["tool_context"]["trusted_origin"]
        assert args["tool_context"]["source_message_ids"] == [ref(origin)]
        send(provider_pid, {:triage_provider_return, %{"created" => true}})
        origin
      end

    assert MapSet.new(actual) == MapSet.new([a, b])

    await(fn ->
      {:ok, state} = InternalSessionStore.read(ctx.agent_id, session_id)
      InternalSession.work_reasons(state) == []
    end)
  end

  test "external completion retires Triage selectors and preserves ordinary source provenance", %{
    ctx: ctx
  } do
    {actor, external_ctx} = external_actor(ctx)
    triage = origin(external_ctx, "completed", 0)

    human = %{
      "source_actor_type" => "provider_user",
      "provider" => "slack",
      "source_message_id" => "ordinary-source",
      "agent_group_id" => external_ctx.group_id
    }

    stage_external(actor, triage, true)
    stage_external(actor, human, false)
    accept_runtime(external_ctx)
    assert {:ok, state} = ExternalSessionActor.complete_session(actor, %{})
    assert state["active_external_trusted_origins"] == %{ref(human) => human}
    assert state["active_external_source_message_ids"] == [ref(human)]

    assert {:ok, result} =
             ExternalSessionActor.execute_tool(actor, @task_create, task_params(ref(triage)))

    assert result.error_class == "triage_delegation_ref_unknown"
    refute_receive {:triage_provider_call, _, _}, 0
  end

  test "only an effective native terminal retires current Triage; a late old batch cannot clear new input",
       %{ctx: ctx} do
    {actor, external_ctx} = external_actor(ctx)
    a = origin(external_ctx, "settled-a", 0)
    b = origin(external_ctx, "settled-b", 0)
    stage_external(actor, a, false)
    first = accept_runtime(external_ctx)
    native_event(actor, first, "execution-a", "running")
    stage_external(actor, b, false)
    second = accept_runtime(external_ctx)
    native_event(actor, second, "execution-b", "running")

    for {request, execution, status} <- [
          {first, "execution-a", "settled"},
          {second, "wrong-execution", "failed"}
        ] do
      native_event(actor, request, execution, status)

      assert {:ok, state} =
               ExternalSessionStore.get_session_record(external_ctx.agent_id, @session_id)

      assert state["active_external_trusted_origins"] == %{ref(b) => b}
    end

    # The owner commit path accepts already-admitted events; non-lifecycle
    # statuses are retained diagnostically but do not project a terminal.
    native_event(actor, second, "execution-b", "invalid")

    assert {:ok, state} =
             ExternalSessionStore.get_session_record(external_ctx.agent_id, @session_id)

    assert state["active_external_trusted_origins"] == %{ref(b) => b}

    assert {:ok, state} =
             ExternalSessionActor.fail_session(actor, :late_dispatch_error, %{
               "dispatch_id" => second.dispatch_id,
               "terminal" => true
             })

    assert state["active_external_trusted_origins"] == %{ref(b) => b}

    native_event(actor, second, "execution-b", "settled")

    assert {:ok, state} =
             ExternalSessionStore.get_session_record(external_ctx.agent_id, @session_id)

    assert state["active_external_trusted_origins"] == %{}

    assert {:ok, denied} =
             ExternalSessionActor.execute_tool(actor, @task_create, task_params(ref(b)))

    assert denied.error_class == "triage_delegation_ref_unknown"
    refute_receive {:triage_provider_call, _, _}, 0
  end

  defp native_event(actor, request, execution, state) do
    result =
      ExternalSessionActor.commit_connector_event(
        actor,
        request.binding["runtime_capability"],
        %{
          "connector_run_id" => request.binding["connector_run_id"],
          "event" => %{
            "type" => "status",
            "provider" => "codex",
            "name" => "turn/state",
            "state" => state,
            "dispatch_id" => request.dispatch_id,
            "execution_id" => execution,
            "work_state" => state
          }
        }
      )

    assert result == {:ok, %{"ok" => true}}
  end

  defp external_actor(ctx) do
    agent_id = SalixAgent.TestSupport.new_agent_id()

    agent =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "role" => "router",
        "runtime_config" => %{
          "kind" => "external",
          "provider" => "codex",
          "device_id" => "triage-device",
          "runtime_id" => "triage-runtime",
          "device_runtime_id" => @device_runtime_id
        }
      })

    {:ok, actor} =
      ExternalSessionActor.start_link(
        agent_id: agent_id,
        session_id: @session_id,
        process_on_init: false
      )

    on_exit(fn -> if Process.alive?(actor), do: GenServer.stop(actor, :normal) end)
    {actor, %{ctx | agent_id: agent_id, group_id: agent["group_id"], runtime_kind: :external}}
  end

  defp stage_external(actor, origin, no_wake) do
    assert {:ok, :committed} =
             ExternalSessionActor.stage_delivery(actor, %{
               "source_message_id" => ref(origin),
               "payload" => %{
                 "session_id" => @session_id,
                 "role" => "user",
                 "content" => "Investigate #{ref(origin)}",
                 "trusted_origin" => origin,
                 "no_wake" => no_wake
               }
             })
  end

  defp accept_runtime(ctx) do
    assert_receive {:triage_runtime_request, pid, request}, 2_000
    send(pid, :triage_runtime_accept)

    await(fn ->
      case ExternalSessionStore.get_session_record(ctx.agent_id, @session_id) do
        {:ok, state} -> state["input_message_queue"] == []
        _ -> false
      end
    end)

    request
  end

  defp await(fun, attempts \\ 100)
  defp await(_fun, 0), do: flunk("owner did not reach expected durable state")

  defp await(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(fun, attempts - 1)
        )
  end

  defp origin(ctx, obligation_id, index) do
    ref = "triage-delegation:#{obligation_id}:#{index}"

    %{
      "source_actor_type" => "provider_system",
      "provider" => "slack",
      "source_message_id" => ref,
      "agent_group_id" => ctx.group_id,
      "triage_delegation" => %{
        "schema" => "comma.triage-delegation-origin.v1",
        "namespace_key" => "triage-test",
        "obligation_id" => obligation_id,
        "index" => index,
        "request_id" => ref,
        "router_agent_id" => ctx.agent_id,
        "group_id" => ctx.group_id
      }
    }
  end

  defp activation(ctx, origins),
    do:
      Map.merge(ctx, %{
        trusted_origin: List.last(origins),
        trusted_origins: origins,
        source_message_ids: Enum.map(origins, & &1["source_message_id"])
      })

  defp ref(origin), do: origin["source_message_id"]

  defp task_params(nil),
    do: %{"connect_id" => "internal", "content" => "Investigate with evidence"}

  defp task_params(ref), do: Map.put(task_params(nil), "triage_delegation_ref", ref)
  defp task_call(id, nil), do: %{id: id, name: @task_create, args: task_params(nil)}
  defp task_call(id, origin), do: %{id: id, name: @task_create, args: task_params(ref(origin))}

  defp envelope(id, tool, params),
    do: %{id: id, name: "call", args: %{"tool" => tool, "params" => params}}

  defp assert_source(record, origins) do
    assert is_map(record)
    assert MapSet.new(record["trusted_origins"]) == MapSet.new(origins)

    assert MapSet.new(record["trusted_origin_source_message_ids"]) ==
             MapSet.new(Enum.map(origins, &ref/1))

    if length(origins) == 1, do: assert(record["trusted_origin"] == hd(origins))
  end
end
