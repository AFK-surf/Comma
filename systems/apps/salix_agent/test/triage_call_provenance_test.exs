defmodule SalixAgent.TriageCallProvenanceTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Regression for the old activation-wide/latest-origin stamp: a Task selected
  from A could execute and resume as B, and discovery/restart lost A entirely.
  Uses the actual tool dispatcher, owner stores and actors with local provider
  seams; no model or provider network calls are made.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{
    AsyncToolResults,
    DependencyJob,
    InternalSessionStore,
    Repair,
    SessionToolExecution,
    ToolCallProvenance,
    ToolDisclosure,
    Tools
  }

  alias SalixAgent.InternalSession
  alias SalixStore.{Ids, S3}

  @task_create "im_api.internal.task.create"
  @session_id "ses1_0000000000000000908"

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
      SystemsRuntime.Proc.send(SystemsRuntime.fetch_env!(:salix_agent, :triage_call_test_owner), {
        :triage_provider_call,
        SystemsRuntime.Proc.self(),
        args
      })

      SystemsRuntime.Proc.receive do
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

  setup do
    overrides = [
      {:salix_store, :s3_backend, S3.Fake},
      {:salix_agent, :im_provider_mod, Provider},
      {:salix_agent, :oauth_store_mod, OAuthStore},
      {:salix_agent, :llm, SalixAgent.LLM.Mock},
      {:salix_agent, :triage_call_test_owner, SystemsRuntime.Proc.self()},
      {:salix_agent, :group_context_mod, SalixAgent.TestSupport.GroupContext}
    ]

    previous =
      Enum.map(overrides, fn {app, key, _} -> {app, key, SystemsRuntime.fetch_env(app, key)} end)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      Enum.each(previous, fn
        {app, key, {:ok, value}} -> SystemsRuntime.put_env(app, key, value)
        {app, key, :error} -> SystemsRuntime.delete_env(app, key)
      end)
    end)

    Enum.each(overrides, fn {app, key, value} -> SystemsRuntime.put_env(app, key, value) end)
    SalixAgent.TestSupport.stop_all_agents()
    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)
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

    assert_receive {:triage_provider_call, pid, args}
    assert args["tool_context"]["trusted_origins"] == [human]
    SystemsRuntime.Proc.send(pid, {:triage_provider_return, %{"conversation_id" => "human-task"}})
    assert {:ok, result} = DependencyJob.yield(pending.dependency_job, wait_limit())
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
        assert_receive {:triage_provider_call, pid, args}
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
      SystemsRuntime.Proc.send(pid, {:triage_provider_return, %{"created" => true}})
      assert {:ok, completed} = DependencyJob.yield(pending.dependency_job, wait_limit())

      internal = AsyncToolResults.internal_events(pending, completed)
      assert_source(Enum.find(internal, &(&1["type"] == "async_tool_call_completed")), [origin])
      assert_source(List.last(internal)["payload"], [origin])
    end

    wait = Enum.find_value(early_a.events ++ early_b.events, & &1["wait"])
    assert_source(wait, [a, b])
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

  # A dependency job answers when it is done: only the suite's shared limit for
  # a message that never comes (config/test.exs) stops the wait.
  defp wait_limit, do: ExUnit.configuration()[:assert_receive_timeout]

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
