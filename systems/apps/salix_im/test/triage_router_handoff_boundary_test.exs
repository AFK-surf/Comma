defmodule SalixIM.TriageRouterHandoffBoundaryTest do
  @moduledoc """
  Durable regression coverage for the existing boundaries a Triage handoff can
  reuse. These are two separate runtime checks, not a model-driven handoff E2E:
  Router admission is Session-local, while canonical Task reservation is not.
  No Worker runs and no Slack participant is created.
  """

  use ExUnit.Case, async: false

  alias SalixAgent.{AgentActor, InternalSessionStore}
  alias SalixAgent.TestSupport.SessionData
  alias SalixIM.{ConversationServer, Conversations, TaskConversationInput}
  alias SalixIM.Triage.{DelegationAuthorization, ReadModel}
  alias SalixStore.{Crypto, Repo, RuntimeIds, TriageKeys}

  defmodule TargetAuthority do
    def authorize_target(original, router, worker) do
      send(self(), {:authorized_target, original.obligation_id, router, worker})
      Process.get(:triage_target_authority, :ok)
    end
  end

  defmodule SourceFreshness do
    def check(original, _opts) do
      send(self(), {:checked_source, original.obligation_id})
      Process.get(:triage_source_freshness, {:ok, %{status: :fresh}})
    end
  end

  defmodule MirroredSource do
    def get_slack_triage_authority(_tenant, _group, _connect, _channel),
      do: {:ok, Process.get(:mirrored_authority)}

    def lookup_claim(_scope), do: {:ok, :triage, String.duplicate("c", 64)}

    def read_thread(_scope, _root, _opts),
      do: {:ok, %{messages: Process.get(:mirrored_messages), reactions: [], complete?: true}}
  end

  defmodule NoModel do
    def complete(_, _, _), do: raise("boundary test must not call a model")
    def complete_stream(_, _, _, _), do: raise("boundary test must not stream a model")
  end

  defmodule NoWakeDelivery do
    # This fixture exercises Task settlement without admitting or running Worker input.
    def notify_conversation(_, _), do: :ok

    def get_session(agent_id, session_id, opts),
      do: SalixAgent.Runtime.get_session(agent_id, session_id, opts)

    def get_session_messages(agent_id, session_id),
      do: SalixAgent.Runtime.get_session_messages(agent_id, session_id)
  end

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()
    SalixAgent.TestSupport.stop_all_agents()

    overrides = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :llm, NoModel},
      {:salix_im, :agent_delivery_mod, NoWakeDelivery},
      {:salix_im, :conversation_placement, SalixIM.ConversationPlacement.LocalFleet}
    ]

    previous =
      Enum.map(overrides, fn {app, key, value} ->
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end)

    on_exit(fn ->
      try do
        SalixIM.TestSupport.Fleet.stop_all!()
        SalixAgent.TestSupport.stop_all_agents()
      after
        for {app, key, old} <- previous do
          case old do
            {:ok, value} -> Application.put_env(app, key, value)
            :error -> Application.delete_env(app, key)
          end
        end
      end
    end)

    start_supervised!(SalixStore.S3.Fake)

    agent_id = SalixAgent.TestSupport.new_agent_id()

    router =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    SalixAgent.TestSupport.create_control_group!(router["group_id"], %{
      "router_agent_id" => agent_id
    })

    {:ok, session_id} = RuntimeIds.persisted_router_session_id(router)
    {:ok, _} = InternalSessionStore.prepare_create(agent_id, session_id)
    %{router: router, session_id: session_id}
  end

  test "Router admission dedupes retries and actor restarts, but not explicit Session rotation",
       %{
         router: router,
         session_id: session_id
       } do
    agent_id = router["agent_id"]
    source = "triage-delegation:immutable-obligation:0"
    payload = %{content: "Investigate the same synthetic source read-only.", role: "user"}
    opts = [source_message_id: source, kind: "im_provider", no_wake: true, create: true]

    assert {:ok, :created} = SalixAgent.deliver(agent_id, payload, opts)

    # The caller loses the successful reply and repeats the exact same input.
    assert {:ok, :duplicate} = SalixAgent.deliver(agent_id, payload, opts)
    SalixAgent.TestSupport.stop_all_agents()
    assert {:ok, :duplicate} = SalixAgent.deliver(agent_id, payload, opts)
    assert source_count(agent_id, [session_id], source) == 1

    assert {:ok, rotated} =
             AgentActor.switch_router_session(agent_id, router["tenant_id"], session_id)

    new_session_id = rotated["router_session_id"]
    assert source_count(agent_id, [new_session_id], source) == 0
    assert {:ok, :created} = SalixAgent.deliver(agent_id, payload, opts)
    assert source_count(agent_id, [session_id, new_session_id], source) == 2
    assert {:ok, :duplicate} = SalixAgent.deliver(agent_id, payload, opts)
    assert tasks(router["group_id"]) == []
  end

  test "a stable Task request retains one Task, command and source trace across retries and rotation",
       %{
         router: router,
         session_id: session_id
       } do
    agent_id = router["agent_id"]
    group_id = router["group_id"]

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(router["tenant_id"], group_id, %{
        "role" => "worker"
      })

    attrs = %{
      "client_request_id" => "triage-delegation:immutable-task-obligation:0",
      "title" => "Inspect synthetic source",
      "content" => "Read-only inspection of synthetic source",
      "source_refs" => %{"triage_obligation_id" => "immutable-task-obligation"},
      "conversation_metadata" => %{"source" => "bft_triage"}
    }

    reserve = fn input ->
      ConversationServer.reserve_task_conversation_id(
        group_id,
        agent_id,
        worker["agent_id"],
        input
      )
    end

    assert {:ok, conversation_id} = reserve.(attrs)

    assert {:ok, %{"disposition" => "reserved_task_unavailable"}} =
             ConversationServer.lookup_task_create_request(group_id, attrs["client_request_id"])

    materialize = fn ->
      assert {:ok, ^conversation_id} = reserve.(attrs)

      TaskConversationInput.create_with_id(
        group_id,
        conversation_id,
        agent_id,
        worker["agent_id"],
        attrs
        |> Map.put("schedule", %{"schedule_id" => nil, "command" => attrs["content"]})
        |> Map.put("initial_message_attrs", %{
          "kind" => "message",
          "actor_type" => "agent",
          "agent_id" => agent_id,
          "content" => attrs["content"],
          "metadata" => %{"message_type" => "task_command"},
          "client_request_id" => "delegate-task-" <> conversation_id
        })
      )
    end

    assert {:ok, %{"conversation_id" => ^conversation_id}} = materialize.()
    assert_single_task_trace!(group_id, conversation_id, attrs)

    assert {:ok, %{"disposition" => "created", "conversation_id" => ^conversation_id}} =
             ConversationServer.lookup_task_create_request(group_id, attrs["client_request_id"])

    assert {:ok, %{"disposition" => "not_created"}} =
             ConversationServer.lookup_task_create_request(group_id, "unreserved-identity")

    # Discard success, retry, then stop both kinds of owner before retrying.
    assert {:ok, %{"conversation_id" => ^conversation_id}} = materialize.()
    SalixIM.TestSupport.Fleet.stop_all!()
    SalixAgent.TestSupport.stop_all_agents()
    assert {:ok, %{"conversation_id" => ^conversation_id}} = materialize.()
    assert_single_task_trace!(group_id, conversation_id, attrs)

    assert {:ok, _rotated} =
             AgentActor.switch_router_session(agent_id, router["tenant_id"], session_id)

    assert {:ok, %{"conversation_id" => ^conversation_id}} = materialize.()
    assert_single_task_trace!(group_id, conversation_id, attrs)

    assert {:error, {:conflict, _}} = reserve.(Map.put(attrs, "content", "Different command"))
    assert_single_task_trace!(group_id, conversation_id, attrs)
  end

  test "Task authorization selects the immutable obligation and fails closed on stale or foreign scope",
       %{router: router} do
    {namespace, obligation, project_id} = seed_original!(router)
    ref = "triage-delegation:#{obligation}:0"
    scope = %{group_id: router["group_id"], agent_id: router["agent_id"]}
    params = %{"triage_delegation_ref" => ref, "agent_id" => "chosen-worker"}

    origin = %{
      "provider" => "slack",
      "source_actor_type" => "provider_system",
      "source_message_id" => ref,
      "agent_group_id" => scope.group_id,
      "triage_delegation" => %{
        "schema" => "comma.triage-delegation-origin.v1",
        "namespace_key" => TriageKeys.namespace_key(namespace),
        "obligation_id" => obligation,
        "index" => 0,
        "request_id" => ref,
        "router_agent_id" => scope.agent_id,
        "group_id" => scope.group_id
      }
    }

    context = %{trusted_origin: origin, trusted_origins: [origin], source_message_ids: [ref]}
    opts = [authority_port: TargetAuthority, freshness_port: SourceFreshness]

    assert {:ok, authorized} = DelegationAuthorization.prepare(scope, context, params, opts)
    assert authorized.request_id == ref
    assert authorized.source_refs["triage_obligation_id"] == obligation
    refute Map.has_key?(authorized.source_refs, "origin_session_id")
    assert_receive {:authorized_target, ^obligation, _, "chosen-worker"}
    assert_receive {:checked_source, ^obligation}

    # The same original source remains addressable after the product effect
    # settled. A lookup is read-only and must not reserve the absent Task.
    assert {:ok, %{"disposition" => "not_created"}} =
             ReadModel.delegation_task(
               namespace,
               project_id,
               scope.group_id,
               "product-router",
               obligation,
               0
             )

    assert tasks(scope.group_id) == []

    for {project, group, agent, index} <- [
          {"foreign", scope.group_id, "product-router", 0},
          {project_id, scope.group_id, "foreign", 0},
          {project_id, "foreign", "product-router", 0},
          {project_id, scope.group_id, "product-router", 1}
        ] do
      assert {:error, :not_found} =
               ReadModel.delegation_task(namespace, project, group, agent, obligation, index)
    end

    for {bad_context, bad_params} <- [
          {context, Map.delete(params, "triage_delegation_ref")},
          {context, Map.put(params, "triage_delegation_ref", "made-up")},
          {context, Map.put(params, "schedule", %{})},
          {Map.put(context, :source_message_ids, []), params},
          {Map.put(context, :trusted_origin, %{}), params},
          {put_in(context, [:trusted_origin, "triage_delegation", "group_id"], "foreign"),
           params},
          {put_in(context, [:trusted_origin, "triage_delegation", "index"], 1), params}
        ] do
      assert {:error, _} = DelegationAuthorization.prepare(scope, bad_context, bad_params, opts)
      refute_receive {:authorized_target, _, _, _}, 0
      refute_receive {:checked_source, _}, 0
    end

    Process.put(:triage_target_authority, {:error, :delegation_authority_changed, false})

    assert {:error, "triage_delegation_authority_rejected: delegation_authority_changed"} =
             DelegationAuthorization.prepare(scope, context, params, opts)

    assert_receive {:authorized_target, _, _, _}
    refute_receive {:checked_source, _}, 0

    Process.put(:triage_target_authority, :ok)
    Process.put(:triage_source_freshness, {:ok, %{status: :stale, reason: :new_source_message}})

    assert {:error, "triage_delegation_source_stale: new_source_message"} =
             DelegationAuthorization.prepare(scope, context, params, opts)

    assert tasks(scope.group_id) == []
    assert {:ok, nil} = DelegationAuthorization.prepare(scope, %{}, %{}, opts)
  end

  test "a mirrored self reply preserves the same decision's Worker Task admission", %{
    router: router
  } do
    group_id = router["group_id"]
    router_id = router["agent_id"]

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(router["tenant_id"], group_id, %{
        "role" => "worker"
      })

    connect = %{"tenant_id" => router["tenant_id"], "workspace_id" => "T1"}

    root_message = %{
      "type" => "message",
      "channel" => "C1",
      "ts" => "100.000001",
      "bot_id" => "B_ALERT",
      "text" => "Runtime failed; investigate the source."
    }

    reply_message = %{
      "type" => "message",
      "channel" => "C1",
      "ts" => "101.000001",
      "thread_ts" => "100.000001",
      "bot_id" => "B_SELF",
      "user" => "U_SELF",
      "text" => "The alert identifies one failed session."
    }

    assert {:ok, root} =
             SalixIM.SlackMessageMirror.Row.from_event(connect, %{"event" => root_message})

    assert {:ok, reply} =
             SalixIM.SlackMessageMirror.Row.from_event(connect, %{"event" => reply_message})

    assert reply["actor_kind"] == "bot" and reply["actor_id"] == "U_SELF"

    target = %{
      "connect_id" => "connect-1",
      "connect_generation" => "generation-1",
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "thread_ts" => "100.000001"
    }

    {namespace, obligation, _project} =
      seed_original!(router, %{
        "target" => target,
        "target_cutoff" => %{"event_message_timestamps" => [root["message_ts"]]},
        "source_authority" => [
          %{"message_ts_us" => root["message_ts_us"], "observed_version" => root["version"]}
        ],
        "communication" => %{
          "kind" => "reply",
          "text" => reply["text"],
          "source_refs" => ["source-A"]
        }
      })

    Process.put(
      :mirrored_authority,
      Map.merge(target, %{
        "triage_enabled" => true,
        "approved_channel_id" => "C1",
        "bot_id" => "B_SELF",
        "bot_user_id" => "U_SELF"
      })
    )

    Process.put(:mirrored_messages, [root, reply])
    ref = "triage-delegation:#{obligation}:0"
    scope = %{group_id: group_id, agent_id: router_id}

    params = %{
      "triage_delegation_ref" => ref,
      "agent_id" => worker["agent_id"]
    }

    origin = %{
      "provider" => "slack",
      "source_actor_type" => "provider_system",
      "source_message_id" => ref,
      "agent_group_id" => group_id,
      "triage_delegation" => %{
        "schema" => "comma.triage-delegation-origin.v1",
        "namespace_key" => TriageKeys.namespace_key(namespace),
        "obligation_id" => obligation,
        "index" => 0,
        "request_id" => ref,
        "router_agent_id" => router_id,
        "group_id" => group_id
      }
    }

    context = %{trusted_origin: origin, source_message_ids: [ref]}

    opts = [
      authority_port: TargetAuthority,
      freshness_opts: [
        provider_connects: MirroredSource,
        route_owner: MirroredSource,
        clickhouse_reader: MirroredSource
      ]
    ]

    assert {:ok, authorized} = DelegationAuthorization.prepare(scope, context, params, opts)

    attrs = %{
      "client_request_id" => authorized.request_id,
      "title" => "Investigate the alert",
      "content" => "Read the original alert and investigate.",
      "source_refs" => authorized.source_refs,
      "conversation_metadata" => %{"source" => "bft_triage"}
    }

    assert {:ok, conversation_id} =
             ConversationServer.reserve_task_conversation_id(
               group_id,
               router_id,
               worker["agent_id"],
               attrs
             )

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             TaskConversationInput.create_with_id(
               group_id,
               conversation_id,
               router_id,
               worker["agent_id"],
               Map.merge(attrs, %{
                 "schedule" => %{"schedule_id" => nil, "command" => attrs["content"]},
                 "initial_message_attrs" => %{
                   "kind" => "message",
                   "actor_type" => "agent",
                   "agent_id" => router_id,
                   "content" => attrs["content"],
                   "metadata" => %{"message_type" => "task_command"},
                   "client_request_id" => "delegate-task-" <> conversation_id
                 }
               })
             )

    assert_single_task_trace!(group_id, conversation_id, attrs)

    # Later human input still invalidates the frozen decision, even after our reply.
    assert {:ok, human} =
             SalixIM.SlackMessageMirror.Row.from_event(connect, %{
               "event" => %{
                 "type" => "message",
                 "channel" => "C1",
                 "ts" => "102.000001",
                 "thread_ts" => "100.000001",
                 "user" => "U_HUMAN",
                 "text" => "Already resolved."
               }
             })

    Process.put(:mirrored_messages, [root, reply, human])

    assert {:error, "triage_delegation_source_stale: new_source_message"} =
             DelegationAuthorization.prepare(scope, context, params, opts)

    assert_single_task_trace!(group_id, conversation_id, attrs)
  end

  test "source history reads the canonical Task result without reserving work or inferring delivery",
       %{router: router} do
    group = router["group_id"]

    target = %{
      "connect_id" => "C_CONTEXT_CONNECT",
      "connect_generation" => SalixStore.ULID.generate(),
      "workspace_id" => "T_CONTEXT",
      "channel_id" => "C_CONTEXT",
      "thread_ts" => "100.000001"
    }

    {_namespace, obligation, project} = seed_original!(router, %{"target" => target})

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(router["tenant_id"], group, %{
        "role" => "worker"
      })

    attrs = %{
      "client_request_id" => "triage-delegation:#{obligation}:0",
      "title" => "Investigate the missing result",
      "content" => "Read the exact source and delivery records.",
      "source_refs" => %{"triage_obligation_id" => obligation}
    }

    assert %{availability: "not_created"} = SalixIM.Triage.TaskContext.read(group, obligation, 0)

    assert {:ok, conversation} =
             ConversationServer.reserve_task_conversation_id(
               group,
               router["agent_id"],
               worker["agent_id"],
               attrs
             )

    assert %{availability: "reserved_task_unavailable"} =
             SalixIM.Triage.TaskContext.read(group, obligation, 0)

    assert {:ok, _} =
             TaskConversationInput.create_with_id(
               group,
               conversation,
               router["agent_id"],
               worker["agent_id"],
               Map.merge(attrs, %{
                 "schedule" => %{"schedule_id" => nil, "command" => attrs["content"]},
                 "initial_message_attrs" => %{
                   "kind" => "message",
                   "actor_type" => "agent",
                   "agent_id" => router["agent_id"],
                   "content" => attrs["content"],
                   "metadata" => %{"message_type" => "task_command"}
                 }
               })
             )

    for n <- 1..5 do
      assert {:ok, _} =
               ConversationServer.append_group_conversation_agent_message(
                 group,
                 conversation,
                 worker["agent_id"],
                 %{
                   "kind" => "message",
                   "content" => "Observed delivery record #{n}: " <> String.duplicate("证据", 500),
                   "mentions" => %{"participant_ids" => []}
                 }
               )
    end

    assert %{availability: "available", conversation_id: ^conversation, recent_messages: messages} =
             SalixIM.Triage.TaskContext.read(group, obligation, 0)

    assert length(messages) == 3

    assert Enum.map(messages, &String.slice(&1.text_excerpt, 0, 27)) ==
             Enum.map(3..5, &"Observed delivery record #{&1}:")

    assert Enum.all?(
             messages,
             &(byte_size(&1.text_excerpt) <= 2_048 and String.valid?(&1.text_excerpt))
           )

    assert Enum.all?(messages, &(&1.agent_id == worker["agent_id"]))

    assert {:ok, %{outcomes: [outcome]}} =
             ReadModel.product_activity(project, group, "product-router",
               limit: 3,
               context_limit: 0,
               target: target,
               include_task_context: true
             )

    assert [%{task_context: %{conversation_id: ^conversation, recent_messages: ^messages}}] =
             outcome.delegations

    refute Map.has_key?(hd(outcome.delegations).task_context, :delivered)

    assert {:ok, %{outcomes: [ordinary]}} =
             ReadModel.product_activity(project, group, "product-router",
               limit: 3,
               context_limit: 0,
               target: target
             )

    refute Map.has_key?(hd(ordinary.delegations), :task_context)

    assert {:error, :invalid_triage_product_activity} =
             ReadModel.product_activity(project, group, "product-router",
               limit: 20,
               target: target,
               include_task_context: true
             )

    assert {:error, :invalid_triage_product_activity} =
             ReadModel.product_activity(project, group, "product-router",
               limit: 3,
               include_task_context: true
             )

    assert {:ok, all_messages} =
             Conversations.list_group_conversation_messages(group, conversation, limit: 10)

    assert length(all_messages) == 6
    assert length(tasks(group)) == 1
  end

  test "product investigation protects the public sink and retains stale settlement across restart",
       %{router: router} do
    previous = Application.fetch_env(:salix_im, :triage_delegation_mod)
    Application.put_env(:salix_im, :triage_delegation_mod, TargetAuthority)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:salix_im, :triage_delegation_mod, value)
        :error -> Application.delete_env(:salix_im, :triage_delegation_mod)
      end
    end)

    group = router["group_id"]

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(router["tenant_id"], group, %{
        "role" => "worker"
      })

    worker_id = worker["agent_id"]

    {namespace, obligation, _} =
      seed_original!(router, %{
        "target" => %{
          "connect_id" => "fixture-no-network",
          "channel_id" => "C-SYNTHETIC",
          "thread_ts" => "1789113600.000001"
        },
        "delegations" => [
          %{
            "task" => "Inspect source",
            "source_refs" => ["source-A"],
            "worker_ref" => "comma-agent://" <> worker_id
          }
        ]
      })

    grant = %{
      "namespace_key" => TriageKeys.namespace_key(namespace),
      "obligation_id" => obligation,
      "index" => 0,
      "worker_agent_id" => worker_id
    }

    attrs = %{
      "client_request_id" => "triage-delegation:#{obligation}:0",
      "title" => "Inspect source",
      "content" => "Inspect source",
      "source_refs" => %{"triage_investigation" => grant}
    }

    assert {:ok, conversation_id} =
             ConversationServer.reserve_task_conversation_id(
               group,
               router["agent_id"],
               worker_id,
               attrs
             )

    assert {:ok, _} =
             TaskConversationInput.create_with_id(
               group,
               conversation_id,
               router["agent_id"],
               worker_id,
               attrs
               |> Map.put("schedule", %{"schedule_id" => nil, "command" => attrs["content"]})
               |> Map.put("initial_message_attrs", %{
                 "actor_type" => "agent",
                 "agent_id" => router["agent_id"],
                 "content" => attrs["content"],
                 "client_request_id" => "delegate-task-" <> conversation_id
               })
             )

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(group, conversation_id)

    delegator = Enum.find(participants, &(&1["role_label"] == "delegator"))
    sink = Enum.find(participants, &(&1["role_label"] == "triage_result"))
    assert delegator["notification_filter"] == %{"messages" => "none", "statuses" => "none"}
    assert sink["notification_filter"] == %{"messages" => "mentioned", "statuses" => "none"}

    assert {:ok, progress} =
             ConversationServer.append_group_conversation_agent_message(
               group,
               conversation_id,
               worker_id,
               %{"content" => "Private evidence", "client_request_id" => "private-evidence"}
             )

    assert {:ok, private} =
             Conversations.get_group_conversation_message(
               group,
               conversation_id,
               progress["message_id"]
             )

    refute SalixIM.ConversationMessage.targets_participant?(sink, private)
    refute SalixIM.ConversationMessage.targets_participant?(delegator, private)

    assert {:error, {:bad_request, _}} =
             ConversationServer.append_group_conversation_agent_message(
               group,
               conversation_id,
               worker_id,
               %{
                 "content" => "Attempt to bypass completion",
                 "mentions" => %{"participant_ids" => [sink["participant_id"]]},
                 "delivery_filter" => %{"participant_ids" => [sink["participant_id"]]}
               }
             )

    assert {:error, {:bad_request, _}} =
             ConversationServer.append_group_conversation_agent_message(
               group,
               conversation_id,
               worker_id,
               %{
                 "content" => "Fake completion",
                 "metadata" => %{"triage_investigation_result" => %{}}
               }
             )

    snapshot = %{
      "target" => %{},
      "product_identity" => %{"project_salix_group_id" => group},
      "communication" => %{}
    }

    assert {:ok, source} =
             ConversationServer.record_triage_source(group, conversation_id, worker_id, snapshot)

    decision = %{
      "kind" => "silence",
      "reason" => "No useful public addition",
      "source_refs" => []
    }

    assert {:ok, result} =
             ConversationServer.complete_triage_investigation(
               group,
               conversation_id,
               worker_id,
               source["message_id"],
               decision
             )

    assert {:ok, public} =
             Conversations.get_group_conversation_message(
               group,
               conversation_id,
               result["message_id"]
             )

    assert SalixIM.ConversationMessage.targets_participant?(sink, public)
    refute SalixIM.ConversationMessage.targets_participant?(delegator, public)
    # This fixture has no live source authority. Let the real sink settle it
    # before checking recovery; a manual applied result would race that sink.
    settled_task =
      SalixAgent.LiveLlmTestSupport.eventually(
        fn ->
          {:ok, task} = Conversations.get_group_conversation(group, conversation_id)

          if get_in(task, ["metadata", "triage_investigation_state", "state"]) == "retry",
            do: {:ok, task},
            else: :retry
        end,
        10_000
      )

    assert settled_task["status"] == "active"
    settled_lifecycle = get_in(settled_task, ["metadata", "triage_investigation_state"])
    assert settled_lifecycle["state"] == "retry"
    assert settled_lifecycle["current_source"] == source["message_id"]
    assert settled_lifecycle["settled_sources"] == [source["message_id"]]

    SalixIM.TestSupport.Fleet.stop_all!()

    assert {:error, :triage_source_changed_read_again} =
             ConversationServer.complete_triage_investigation(
               group,
               conversation_id,
               worker_id,
               source["message_id"],
               decision
             )

    assert {:ok, task} = Conversations.get_group_conversation(group, conversation_id)
    assert task["status"] == "active"
    lifecycle = get_in(task, ["metadata", "triage_investigation_state"])
    assert lifecycle == settled_lifecycle
  end

  defp seed_original!(router, payload_overrides \\ %{}) do
    run_id = "handoff-read-" <> SalixStore.ULID.generate()
    namespace = "handoff-boundary"
    namespace_key = TriageKeys.namespace_key(namespace)
    obligation = "triage-product-" <> Crypto.hex(run_id)
    project_id = "project-" <> run_id

    Repo.query!(
      "INSERT INTO triage_runs (record_key, namespace_key, run_id, body) VALUES ($1,$2,$3,$4)",
      [
        "handoff-run://#{run_id}",
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

    Repo.query!(
      """
      INSERT INTO triage_product_obligations (namespace_key, run_id, obligation_id, payload, state)
      VALUES ($1,$2,$3,$4,'applied')
      """,
      [
        namespace_key,
        run_id,
        obligation,
        Map.merge(
          %{
            "schema" => "comma.triage-product-obligation.v1",
            "obligation_id" => obligation,
            "namespace" => namespace,
            "fence_key" => "handoff-fence://#{run_id}",
            "run_id" => run_id,
            "target" => %{},
            "communication" => %{"kind" => "silence", "reason" => "investigation"},
            "context_candidates" => [],
            "target_cutoff" => %{},
            "settled_at" => 1,
            "product_identity" => %{
              "project_id" => project_id,
              "project_salix_group_id" => router["group_id"],
              "agent_id" => "product-router",
              "salix_agent_id" => router["agent_id"]
            },
            "delegations" => [
              %{"task" => "Inspect original source", "source_refs" => ["source-A"]}
            ]
          },
          payload_overrides
        )
      ]
    )

    {namespace, obligation, project_id}
  end

  defp assert_single_task_trace!(group_id, conversation_id, attrs) do
    assert [%{"conversation_id" => ^conversation_id}] = tasks(group_id)
    assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
    assert task["source_refs"] == attrs["source_refs"]
    assert task["metadata"]["source"] == "bft_triage"

    assert {:ok, [command]} =
             Conversations.list_group_conversation_messages(group_id, conversation_id, limit: 10)

    assert command["content"] == [%{"type" => "text", "text" => attrs["content"]}]
    assert command["client_request_id"] == "delegate-task-" <> conversation_id
  end

  defp tasks(group_id) do
    assert {:ok, %{"data" => tasks, "has_more" => false}} =
             Conversations.list_group_conversations(group_id, kind: "agent_task", limit: 10)

    tasks
  end

  defp source_count(agent_id, session_ids, source) do
    Enum.count(session_ids, fn session_id ->
      {:ok, session} = SessionData.read(agent_id, session_id)
      MapSet.member?(session.input_dedupe, source)
    end)
  end
end
