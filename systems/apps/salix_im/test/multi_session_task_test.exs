defmodule SalixIM.MultiSessionTaskTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixIM.{
    ConversationDelivery,
    ConversationMessage,
    ConversationPlacement,
    ConversationServer,
    ConversationSource,
    Conversations,
    Provider,
    RouterWaitProbe,
    TaskCardProjection,
    TaskExecution,
    TaskRun,
    TaskSessionSlots,
    TaskWorkerWatch
  }

  alias SalixStore.{CasRecord, Ids, Keys}

  defmodule FakeTaskCreate do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskCreate

    @runs_on_calls_key {__MODULE__, :runs_on_calls}

    def reset_runs_on_calls, do: SystemsRuntime.PersistentTerm.put(@runs_on_calls_key, 0)
    def runs_on_calls, do: SystemsRuntime.PersistentTerm.get(@runs_on_calls_key, 0)

    @impl true
    def create_task_conversation(group_id, delegator_agent_id, target_agent_id, attrs) do
      SalixCluster.TaskSchedules.create_task_conversation(
        group_id,
        delegator_agent_id,
        target_agent_id,
        attrs
      )
    end

    @impl true
    def default_task_model(_scope), do: {:ok, nil}

    @impl true
    def session_model(_scope, choice), do: {:ok, choice}

    @impl true
    def runs_on(_scope, place) do
      SystemsRuntime.PersistentTerm.put(@runs_on_calls_key, runs_on_calls() + 1)

      case place do
        %{"kind" => "salix"} ->
          {:ok, nil}

        %{"kind" => "sandbox"} ->
          {:ok, %{"kind" => "sandbox"}}

        %{"kind" => "cloud_vm"} when map_size(place) == 1 ->
          {:ok, %{"kind" => "cloud_vm", "device_id" => "dev_cloud_1"}}

        %{"kind" => "cloud_vm"} ->
          {:error, :invalid_runs_on}

        other ->
          {:ok, other}
      end
    end
  end

  defmodule FakeTaskStations do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskStations

    @sessions_key {__MODULE__, :sessions}
    @invite_key {__MODULE__, :invite_result}
    @moved_key {__MODULE__, :moved_result}
    @calls_key {__MODULE__, :calls}
    @on_invite_key {__MODULE__, :on_invite}

    def set_sessions(map) when is_map(map),
      do: SystemsRuntime.PersistentTerm.put(@sessions_key, map)

    def set_invite_result(result),
      do: SystemsRuntime.PersistentTerm.put(@invite_key, result)

    def set_moved_result(result),
      do: SystemsRuntime.PersistentTerm.put(@moved_key, result)

    def set_on_invite(fun),
      do: SystemsRuntime.PersistentTerm.put(@on_invite_key, fun)

    def reset_calls, do: SystemsRuntime.PersistentTerm.put(@calls_key, [])
    def calls, do: Enum.reverse(SystemsRuntime.PersistentTerm.get(@calls_key, []))

    defp record_call(entry) do
      prev = SystemsRuntime.PersistentTerm.get(@calls_key, [])
      SystemsRuntime.PersistentTerm.put(@calls_key, [entry | prev])
    end

    @impl true
    def invite(invitation) do
      record_call({:invite, invitation})

      case SystemsRuntime.PersistentTerm.get(@on_invite_key, nil) do
        fun when is_function(fun, 1) -> fun.(invitation)
        _ -> :ok
      end

      SystemsRuntime.PersistentTerm.get(@invite_key, {:ok, :when_connected})
    end

    @impl true
    def joined(_row), do: :ok
    @impl true
    def sandbox(_reservation), do: :ok
    @impl true
    def update_github(_group_id, _conversation_id, _github), do: :ok
    @impl true
    def terminal_urls(_group_id, _conversation_ids), do: %{}
    @impl true
    def task_status(_group_id, _conversation_id, _status), do: :ok

    @impl true
    def moved(move) do
      record_call({:moved, move})
      SystemsRuntime.PersistentTerm.get(@moved_key, :ok)
    end

    @impl true
    def sessions(_group_id, _conversation_id),
      do: {:ok, SystemsRuntime.PersistentTerm.get(@sessions_key, %{})}

    @impl true
    def appended(_group_id, _conversation_id), do: :ok
    @impl true
    def standing(_group_id, _conversation_id), do: {:ok, :not_station}
    @impl true
    def session_status(_group_id, _conversation_id), do: {:ok, :not_station}
  end

  defmodule FakeSessionActivity do
    @moduledoc false
    @behaviour SalixIM.Ports.SessionActivity

    @key {__MODULE__, :snapshots}
    @sub_err_key {__MODULE__, :subscribe_errors}

    def set(snapshots) when is_map(snapshots),
      do: SystemsRuntime.PersistentTerm.put(@key, snapshots)

    def set_subscribe_errors(refs) when is_list(refs),
      do: SystemsRuntime.PersistentTerm.put(@sub_err_key, MapSet.new(refs))

    @impl true
    def get(agent_id, session_id) do
      snapshots = SystemsRuntime.PersistentTerm.get(@key, %{})

      case Map.get(snapshots, {agent_id, session_id}) do
        nil ->
          {:error, :not_found}

        {:error, _} = err ->
          err

        {:ok, _} = ok ->
          ok

        fun when is_function(fun, 0) ->
          fun.()

        snap when is_map(snap) ->
          {:ok, snap}
      end
    end

    @impl true
    def subscribe(agent_id, session_id) do
      errs = SystemsRuntime.PersistentTerm.get(@sub_err_key, MapSet.new())

      if MapSet.member?(errs, {agent_id, session_id}),
        do: {:error, :pubsub_down},
        else: :ok
    end

    @impl true
    def unsubscribe(_agent_id, _session_id), do: :ok
  end

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()
    SalixAgent.TestSupport.stop_all_agents()
    SalixAgent.TestSupport.configure_control_fixtures!()

    prev_task_create = SystemsRuntime.get_env(:salix_im, :task_create_mod)
    prev_task_stations = SystemsRuntime.get_env(:salix_im, :task_stations_mod)
    prev_activity = SystemsRuntime.get_env(:salix_im, :session_activity_mod)
    prev_placement = SystemsRuntime.get_env(:salix_im, :conversation_placement)
    SystemsRuntime.put_env(:salix_im, :task_create_mod, FakeTaskCreate)
    SystemsRuntime.put_env(:salix_im, :task_stations_mod, FakeTaskStations)
    SystemsRuntime.put_env(:salix_im, :session_activity_mod, FakeSessionActivity)

    SystemsRuntime.put_env(
      :salix_im,
      :conversation_placement,
      SalixIM.ConversationPlacement.LocalFleet
    )

    FakeSessionActivity.set(%{})
    FakeSessionActivity.set_subscribe_errors([])
    FakeTaskStations.set_sessions(%{})
    FakeTaskStations.set_invite_result({:ok, :when_connected})
    FakeTaskStations.set_moved_result(:ok)
    FakeTaskCreate.reset_runs_on_calls()

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SalixAgent.TestSupport.stop_all_agents()
      restore_env(:salix_im, :task_create_mod, prev_task_create)
      restore_env(:salix_im, :task_stations_mod, prev_task_stations)
      restore_env(:salix_im, :session_activity_mod, prev_activity)
      restore_env(:salix_im, :conversation_placement, prev_placement)
      SystemsRuntime.PersistentTerm.erase({FakeSessionActivity, :snapshots})
      SystemsRuntime.PersistentTerm.erase({FakeSessionActivity, :subscribe_errors})
      SystemsRuntime.PersistentTerm.erase({FakeTaskStations, :sessions})
      SystemsRuntime.PersistentTerm.erase({FakeTaskStations, :invite_result})
      SystemsRuntime.PersistentTerm.erase({FakeTaskStations, :moved_result})
      SystemsRuntime.PersistentTerm.erase({FakeTaskCreate, :runs_on_calls})
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    owner_user = "usr_owner_1"

    router_rec =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(group), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "name" => "Router",
        "role" => "router"
      })

    router = router_rec["agent_id"]
    router_session = router_rec["router_session_id"]

    worker_rec =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "name" => "Worker",
        "role" => "worker"
      })

    worker = worker_rec["agent_id"]

    {:ok, _} =
      CasRecord.update(Keys.ctl_group(group), fn g ->
        g
        |> Map.put("router_agent_id", router)
        |> Map.put("task_agent_id", worker)
        |> Map.put("owner_user_id", owner_user)
      end)

    {:ok,
     tenant: tenant,
     group: group,
     router: router,
     worker: worker,
     router_session: router_session,
     owner_user: owner_user}
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, val), do: SystemsRuntime.put_env(app, key, val)

  defp call_router(f, api, params, extra_ctx \\ %{}) do
    {tool_call_id, rest_ctx} =
      Map.pop(extra_ctx, "tool_call_id", "tc_" <> Ids.new_message_id())

    ctx = Map.merge(%{"session_id" => f.router_session}, rest_ctx)

    Provider.call_api(f.router, "internal", api, %{
      "connect_id" => "internal",
      "tool_call_id" => tool_call_id,
      "tool_context" => ctx,
      "params" => params
    })
  end

  defp create_multi_session_task(f, extra_params \\ %{}, extra_ctx \\ %{}) do
    params =
      Map.merge(
        %{
          "agent_id" => f.worker,
          "title" => "Multi-Session Task",
          "content" => "Coordinate implementation and review.",
          "runs_on" => %{"kind" => "salix"},
          "sessions" => [
            %{
              "slot" => "lead",
              "label" => "Lead (Claude)",
              "role" => "Own architecture and final synthesis",
              "primary" => true
            },
            %{
              "slot" => "reviewer",
              "label" => "Reviewer (Codex)",
              "role" => "Audit code and edge cases"
            }
          ]
        },
        extra_params
      )

    call_router(f, "internal.task.create", params, extra_ctx)
  end

  defp participants_by_role(f, conv_id) do
    {:ok, %{"participants" => participants}} =
      Conversations.list_group_conversation_participants(f.group, conv_id)

    primary = Enum.find(participants, &TaskSessionSlots.primary_worker?/1)
    secondaries = Enum.filter(participants, &TaskSessionSlots.secondary_worker?/1)
    router = Enum.find(participants, &(&1["agent_id"] == f.router))
    %{all: participants, primary: primary, secondaries: secondaries, router: router}
  end

  describe "§2.1 & §4.1 multi-session task.create, identity slots, cold reload, idempotency, 6-slot cap & exclusions" do
    test "creates multi-session task, preserves slots across actor restart, and enforces idempotency vs conflict",
         f do
      tool_call_id = "tc_idem_1"
      assert {:ok, created} = create_multi_session_task(f, %{}, %{"tool_call_id" => tool_call_id})
      conv_id = created["conversation_id"]

      # Same request ID + same sessions spec -> idempotent retry returns same task
      assert {:ok, retried} = create_multi_session_task(f, %{}, %{"tool_call_id" => tool_call_id})
      assert retried["conversation_id"] == conv_id

      # Same request ID + conflicting sessions spec -> conflict error
      assert {:error, conflict_msg} =
               create_multi_session_task(
                 f,
                 %{
                   "sessions" => [
                     %{"slot" => "lead", "primary" => true},
                     %{"slot" => "different_slot"}
                   ]
                 },
                 %{"tool_call_id" => tool_call_id}
               )

      assert conflict_msg =~ "conflict" or conflict_msg =~ "different"

      parts = participants_by_role(f, conv_id)
      assert parts.primary["agent_id"] == f.worker
      assert is_nil(TaskSessionSlots.normalize_target_key(parts.primary["target_key"]))
      assert parts.primary["notification_filter"] == %{"messages" => "all", "statuses" => "none"}
      assert get_in(parts.primary, ["payload", "session_slot"]) == "lead"
      assert get_in(parts.primary, ["payload", "session_label"]) == "Lead (Claude)"

      assert [reviewer] = parts.secondaries
      assert reviewer["agent_id"] == f.worker
      assert reviewer["target_key"] == "reviewer"
      assert reviewer["notification_filter"] == %{"messages" => "mentioned", "statuses" => "none"}
      assert get_in(reviewer, ["payload", "session_slot"]) == "reviewer"
      assert get_in(reviewer, ["payload", "session_label"]) == "Reviewer (Codex)"
      assert get_in(reviewer, ["payload", "role_instructions"]) == "Audit code and edge cases"

      assert get_in(reviewer, ["payload", "session_id"]) !=
               get_in(parts.primary, ["payload", "session_id"])

      # Cold reload: stop conversation actor and verify owner APIs rebuild slots from storage
      assert {:ok, pid} = ConversationPlacement.ensure_started(f.group, conv_id)
      GenServer.stop(pid, :normal)

      assert {:ok, primary_id} =
               ConversationServer.get_group_conversation_primary_worker_identity(
                 f.group,
                 conv_id,
                 f.worker
               )

      assert primary_id["participant_id"] == parts.primary["participant_id"]

      assert {:ok, roster} =
               ConversationServer.get_group_conversation_task_worker_identities(f.group, conv_id)

      assert roster["primary"]["participant_id"] == parts.primary["participant_id"]
      assert length(roster["workers"]) == 2
      assert roster["router"]["participant_id"] == parts.router["participant_id"]
    end

    test "enforces 6 worker session cap and allows idempotent retry of existing 6th slot", f do
      sessions = [
        %{"slot" => "lead", "primary" => true},
        %{"slot" => "s1"},
        %{"slot" => "s2"},
        %{"slot" => "s3"},
        %{"slot" => "s4"},
        %{"slot" => "s5"}
      ]

      assert {:ok, created} = create_multi_session_task(f, %{"sessions" => sessions})
      conv_id = created["conversation_id"]

      # 7th session via task.add_session is rejected
      assert {:error, err} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "s6"
               })

      assert err =~ "limit"

      # Idempotent retry of existing 6th slot ("s5") succeeds
      assert {:ok, retried} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "s5"
               })

      assert retried["added"] == true
      assert retried["slot"] == "s5"

      # Creating 7 sessions upfront is rejected
      assert {:error, err7} =
               create_multi_session_task(f, %{"sessions" => sessions ++ [%{"slot" => "s6"}]})

      assert err7 =~ "6"
    end

    test "allows runs_on != nil in PR 2 and rejects reserved slots", f do
      # PR 2 unlocks runs_on != nil (sandbox / station / cloud_vm) for multi-session Tasks
      assert {:ok, created} =
               create_multi_session_task(f, %{"runs_on" => %{"kind" => "sandbox"}})

      assert is_binary(created["conversation_id"])

      # Reserved secondary slots rejected
      for bad <- ~w(all router delegator lead BadUpper) do
        assert {:error, _} =
                 create_multi_session_task(f, %{
                   "sessions" => [%{"slot" => "lead", "primary" => true}, %{"slot" => bad}]
                 })
      end
    end
  end

  describe "§4.2 task.add_session, legacy single-worker upgrade, lead alias, IFC & kickoff isolation" do
    test "adds secondary session to legacy single-worker task, supports @lead alias, and registers IFC destination",
         f do
      # IFC destination check
      assert {:egress, %{"kind" => "conversation", "conversation_id" => "cnv1_test"}} =
               SalixAgent.IFC.Destination.describe(
                 "im_api.internal.task.add_session",
                 %{"conversation_id" => "cnv1_test"},
                 %{}
               )

      # Create legacy single-worker task (no `sessions` param)
      assert {:ok, created} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "Legacy Single Task",
                 "content" => "Initial work",
                 "runs_on" => %{"kind" => "salix"}
               })

      conv_id = created["conversation_id"]

      # Add secondary session with kickoff message
      assert {:ok, added} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer",
                 "label" => "Reviewer",
                 "role" => "Review changes",
                 "message" => "Please audit the implementation."
               })

      assert added["added"] == true
      assert is_binary(added["kickoff_message_id"])

      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      # Kickoff message targets ONLY the new secondary participant
      {:ok, kickoff} =
        Conversations.get_group_conversation_message(
          f.group,
          conv_id,
          added["kickoff_message_id"]
        )

      assert get_in(kickoff, ["delivery_filter", "participant_ids"]) == [
               reviewer["participant_id"]
             ]

      assert get_in(kickoff, ["mentions", "participant_ids"]) == [reviewer["participant_id"]]
      assert ConversationMessage.targets_participant?(reviewer, kickoff)
      refute ConversationMessage.targets_participant?(parts.primary, kickoff)

      # Secondary cannot use TaskExecution grant
      refute TaskExecution.active?(
               %{group_id: f.group, agent_id: f.worker, agent: %{"role" => "worker"}},
               %{
                 "session_id" => get_in(reviewer, ["payload", "session_id"]),
                 "trusted_origin" => %{
                   "provider" => "internal",
                   "conversation_kind" => "agent_task",
                   "agent_group_id" => f.group,
                   "conversation_id" => conv_id,
                   "participant_id" => reviewer["participant_id"],
                   "message_id" => kickoff["message_id"]
                 }
               }
             )

      # Existing legacy primary automatically accepts @lead alias!
      {:ok, reply} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "agent",
          "agent_id" => f.worker,
          "participant_id" => reviewer["participant_id"],
          "content" => "@lead looks good to me"
        })

      {:ok, reply_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, reply["message_id"])

      assert get_in(reply_msg, ["metadata", "wake_targets"]) == [parts.primary["participant_id"]]
      assert ConversationMessage.targets_participant?(parts.primary, reply_msg)
    end
  end

  describe "§3.1-3.3 visibility, frozen wake_targets, policy toggle, leading @slot, hop cap, card & continuation guards" do
    test "separates visibility from frozen wake_targets across policy toggles and respects explicit mentions & read_conversation filter",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      # Add human user participant
      {:ok, user_part} =
        ConversationServer.ensure_group_conversation_user_participant(f.group, conv_id, %{
          "user_id" => f.owner_user
        })

      # 1. Human unmentioned message under default primary_only
      {:ok, h1} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "user",
          "user_id" => f.owner_user,
          "participant_id" => user_part["participant_id"],
          "content" => "Please add unit tests."
        })

      {:ok, m1} = Conversations.get_group_conversation_message(f.group, conv_id, h1["message_id"])
      assert ConversationMessage.visible_to?(reviewer["participant_id"], m1)
      refute ConversationMessage.targets_participant?(reviewer, m1)
      assert ConversationMessage.targets_participant?(parts.primary, m1)

      # Verify ConversationSource produces scan_only (zero model turn, zero attachment materialization)
      {:ok, binding} =
        ConversationSource.binding(f.worker, %{
          group_id: f.group,
          conversation_id: conv_id,
          participant_id: reviewer["participant_id"]
        })

      assert {:ok, %{conversation_scan_only: true}} = ConversationSource.entry(binding, m1)

      # 2. Switch human_wakeup_policy to all_sessions via task.update
      assert {:ok, %{"updated" => true, "human_wakeup_policy" => "all_sessions"}} =
               call_router(f, "internal.task.update", %{
                 "conversation_id" => conv_id,
                 "human_wakeup_policy" => "all_sessions"
               })

      {:ok, h2} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "user",
          "user_id" => f.owner_user,
          "participant_id" => user_part["participant_id"],
          "content" => "Everyone please check the build."
        })

      {:ok, m2} = Conversations.get_group_conversation_message(f.group, conv_id, h2["message_id"])
      assert get_in(m2, ["metadata", "wake_reason"]) == "all_sessions"
      assert ConversationMessage.targets_participant?(parts.primary, m2)
      assert ConversationMessage.targets_participant?(reviewer, m2)

      # 3. Toggle back to primary_only: m2 remains frozen and still targets reviewer on replay!
      assert {:ok, %{"updated" => true, "human_wakeup_policy" => "primary_only"}} =
               call_router(f, "internal.task.update", %{
                 "conversation_id" => conv_id,
                 "human_wakeup_policy" => "primary_only"
               })

      assert ConversationMessage.targets_participant?(reviewer, m2)

      # 4. Explicit mentions (only primary) restricts visible_to? and read_conversation for reviewer!
      {:ok, h3} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "user",
          "user_id" => f.owner_user,
          "participant_id" => user_part["participant_id"],
          "content" => "Private note for lead only",
          "mentions" => %{"participant_ids" => [parts.primary["participant_id"]]}
        })

      {:ok, m3} = Conversations.get_group_conversation_message(f.group, conv_id, h3["message_id"])
      refute ConversationMessage.visible_to?(reviewer["participant_id"], m3)
      refute ConversationMessage.targets_participant?(reviewer, m3)

      # read_conversation as reviewer omits m3
      {:ok, read_res} =
        Provider.call_api(f.worker, "internal", "internal.read_conversation", %{
          "connect_id" => "internal",
          "tool_context" => %{"session_id" => get_in(reviewer, ["payload", "session_id"])},
          "params" => %{"conversation_id" => conv_id}
        })

      read_ids = Enum.map(read_res["messages"], & &1["message_id"])
      assert h1["message_id"] in read_ids
      refute h3["message_id"] in read_ids
    end

    test "enforces leading-only @slot parser, secondary->lead routing, card/continuation guards, and 8-hop cap",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      # Leading @parser unit checks
      assert TaskSessionSlots.parse_leading_mentions("@reviewer, @tester: check") == [
               "reviewer",
               "tester"
             ]

      assert TaskSessionSlots.parse_leading_mentions("Please ask @reviewer") == []
      assert TaskSessionSlots.parse_leading_mentions("```\n@reviewer\n```") == []

      # Secondary without leading @ routes to Lead only, sets peer_handoff, does not pollute TaskCardProjection
      {:ok, sec_res} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "agent",
          "agent_id" => f.worker,
          "participant_id" => reviewer["participant_id"],
          "content" => "Found a subtle edge case in parser."
        })

      {:ok, sec_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, sec_res["message_id"])

      assert get_in(sec_msg, ["metadata", "wake_targets"]) == [parts.primary["participant_id"]]
      assert get_in(sec_msg, ["metadata", "peer_handoff"]) == true
      refute ConversationMessage.targets_participant?(parts.router, sec_msg)

      refute TaskCardProjection.projectable_card_message?(
               sec_msg,
               parts.primary["participant_id"]
             )

      # Secondary with leading @router sets explicit_router_mention and IS projectable on card
      {:ok, sec_r_res} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "agent",
          "agent_id" => f.worker,
          "participant_id" => reviewer["participant_id"],
          "content" => "@router Escalating blocking issue."
        })

      {:ok, sec_r_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, sec_r_res["message_id"])

      assert get_in(sec_r_msg, ["metadata", "explicit_router_mention"]) == true
      assert ConversationMessage.targets_participant?(parts.router, sec_r_msg)

      assert TaskCardProjection.projectable_card_message?(
               sec_r_msg,
               parts.primary["participant_id"]
             )

      # 8-hop cap: sec_res was hop 1; send 7 more alternating hops (hops 2..8), then 9th hop
      for i <- 2..8 do
        {sender_pid, text} =
          if rem(i, 2) == 0,
            do: {parts.primary["participant_id"], "@reviewer handoff #{i}"},
            else: {reviewer["participant_id"], "@lead handoff #{i}"}

        {:ok, r} =
          ConversationServer.append_group_conversation_message(f.group, conv_id, %{
            "actor_type" => "agent",
            "agent_id" => f.worker,
            "participant_id" => sender_pid,
            "content" => text
          })

        {:ok, m} = Conversations.get_group_conversation_message(f.group, conv_id, r["message_id"])
        assert length(get_in(m, ["metadata", "wake_targets"])) == 1
      end

      # 9th consecutive worker->worker hop: commits message with wake_targets: [] and appends Router notice
      {:ok, hop9_res} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "agent",
          "agent_id" => f.worker,
          "participant_id" => reviewer["participant_id"],
          "content" => "@lead one more hop"
        })

      {:ok, hop9_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, hop9_res["message_id"])

      assert get_in(hop9_msg, ["metadata", "wake_targets"]) == []
      refute ConversationMessage.targets_participant?(parts.primary, hop9_msg)
      refute ConversationMessage.targets_participant?(reviewer, hop9_msg)

      {:ok, all_msgs} =
        Conversations.list_group_conversation_messages(f.group, conv_id, limit: 50)

      cap_notice =
        Enum.find(all_msgs, &(get_in(&1, ["metadata", "message_type"]) == "worker_handoff_cap"))

      assert is_map(cap_notice)
      assert get_in(cap_notice, ["metadata", "wake_targets"]) == [parts.router["participant_id"]]
      assert ConversationMessage.targets_participant?(parts.router, cap_notice)
      refute ConversationMessage.targets_participant?(parts.primary, cap_notice)

      # Router message resets worker_handoff_count to 0 so worker->worker handoff works again
      {:ok, _} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "agent",
          "agent_id" => f.router,
          "participant_id" => parts.router["participant_id"],
          "content" => "Continue with @lead"
        })

      {:ok, after_reset} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "agent",
          "agent_id" => f.worker,
          "participant_id" => parts.primary["participant_id"],
          "content" => "@reviewer fresh handoff after reset"
        })

      {:ok, after_reset_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, after_reset["message_id"])

      assert get_in(after_reset_msg, ["metadata", "wake_targets"]) == [reviewer["participant_id"]]
    end
  end

  describe "§3.4 bounded catch-up summary & §2.2 watch/probe/switch/salix_client guards" do
    test "bounded catch-up summary includes roster, skipped visible messages, filenames only, excludes private messages, and caps at 20 msgs / 16 KiB",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      {:ok, user_part} =
        ConversationServer.ensure_group_conversation_user_participant(f.group, conv_id, %{
          "user_id" => f.owner_user
        })

      # Public message (visible to reviewer, unwoken under primary_only)
      {:ok, _} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "user",
          "user_id" => f.owner_user,
          "participant_id" => user_part["participant_id"],
          "content" => "Public context message for lead"
        })

      # Private message (mentions primary only -> NOT visible to reviewer)
      {:ok, _} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "user",
          "user_id" => f.owner_user,
          "participant_id" => user_part["participant_id"],
          "content" => "SECRET_PRIVATE_NOTE",
          "mentions" => %{"participant_ids" => [parts.primary["participant_id"]]}
        })

      # Wake reviewer explicitly
      {:ok, wake_res} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "user",
          "user_id" => f.owner_user,
          "participant_id" => user_part["participant_id"],
          "content" => "@reviewer please review now"
        })

      {:ok, wake_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, wake_res["message_id"])

      {:ok, binding} =
        ConversationSource.binding(f.worker, %{
          group_id: f.group,
          conversation_id: conv_id,
          participant_id: reviewer["participant_id"]
        })

      record =
        binding.conversation
        |> ConversationMessage.delivery_record(
          wake_msg,
          binding.participant,
          SystemsClock.system_time(:millisecond)
        )
        |> Map.merge(%{
          "participant_agent_id" => f.worker,
          "participant_target_key" => reviewer["target_key"],
          "participant_notification_filter" => reviewer["notification_filter"],
          "source_start_seq" => binding.start_seq,
          "participant_payload" => reviewer["payload"]
        })

      assert {:ok, _agent_id, payload, _opts} = ConversationDelivery.materialize_agent(record)

      catchup =
        Enum.find(
          payload.pre_deliveries,
          &String.ends_with?(&1.source_message_id, ":multi-session-context")
        )

      assert is_map(catchup)
      assert catchup.role == "summary"
      assert catchup.content =~ "Task Roster"
      assert catchup.content =~ "@reviewer"
      assert catchup.content =~ "Public context message for lead"
      refute catchup.content =~ "SECRET_PRIVATE_NOTE"
      assert catchup.content =~ "im_api.internal.read_conversation"
      assert byte_size(catchup.content) <= 16_384

      # Direct unit check for 20-message & 16 KiB caps
      many_msgs =
        for seq <- 1..30 do
          %{
            "seq" => seq,
            "message_id" => "msg1_#{seq}",
            "actor_type" => "user",
            "participant_id" => user_part["participant_id"],
            "content" => [%{"type" => "text", "text" => String.duplicate("x", 1_000)}],
            "delivery_filter" => %{
              "participant_ids" => [parts.primary["participant_id"], reviewer["participant_id"]]
            },
            "metadata" => %{"wake_targets" => [parts.primary["participant_id"]]}
          }
        end

      {:ok, roster} =
        ConversationServer.get_group_conversation_task_worker_identities(f.group, conv_id)

      bounded = TaskSessionSlots.build_catchup_summary(reviewer, roster["workers"], many_msgs, 0)
      assert byte_size(bounded) <= 16_384
    end

    test "TaskWorkerWatch.decide obligates primary only for all_sessions and matches by participant_id",
         _f do
      msg = %{
        "seq" => 2,
        "message_id" => "msg1_all",
        "actor_type" => "user",
        "participant_id" => "prt1_user",
        "content" => [%{"type" => "text", "text" => "hello all"}],
        "metadata" => %{
          "wake_targets" => ["prt1_primary", "prt1_sec"],
          "wake_reason" => "all_sessions"
        }
      }

      # Primary owes a reply -> nudge
      assert {:nudge, 2, "msg1_all"} =
               TaskWorkerWatch.decide(
                 [msg],
                 %{
                   worker_participant_id: "prt1_primary",
                   worker_agent_id: "agt1_w",
                   primary?: true
                 },
                 :stopped,
                 nil,
                 "v1"
               )

      # Secondary does NOT owe a reply on wake_reason: "all_sessions" -> :none
      assert :none =
               TaskWorkerWatch.decide(
                 [msg],
                 %{
                   worker_participant_id: "prt1_sec",
                   worker_agent_id: "agt1_w",
                   primary?: false
                 },
                 :stopped,
                 nil,
                 "v1"
               )
    end

    test "TaskRun.switch rejects multi-session task and RouterWaitProbe checks all active workers",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      # TaskRun.switch refused
      assert {:error, {:bad_request, msg}} =
               TaskRun.switch(
                 f.group,
                 conv_id,
                 %{"runs_on" => %{"kind" => "salix"}},
                 f.owner_user
               )

      assert msg =~ "multi-session"

      # RouterWaitProbe: primary stopped, secondary active -> delegates_busy? is true
      FakeSessionActivity.set(%{
        {f.worker, get_in(parts.primary, ["payload", "session_id"])} => %{
          "state" => "stopped",
          "version" => "v1"
        },
        {f.worker, get_in(reviewer, ["payload", "session_id"])} => %{
          "state" => "active",
          "version" => "v2"
        }
      })

      assert RouterWaitProbe.delegates_busy?(f.router, f.router_session, %{})
    end
  end

  describe "review regression coverage (A-E)" do
    test "single-session router read_conversation keeps worker-only messages; multi-session worker fails closed without session_id",
         f do
      # 1. Legacy single-session task: Router reads worker-only initial command without filtering
      assert {:ok, single} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "Single Task",
                 "content" => "Worker-only initial instruction",
                 "runs_on" => %{"kind" => "salix"}
               })

      single_id = single["conversation_id"]

      assert {:ok, router_read} =
               call_router(f, "internal.read_conversation", %{"conversation_id" => single_id})

      assert Enum.any?(router_read["messages"], fn m ->
               Enum.any?(m["content"] || [], &(&1["text"] =~ "Worker-only initial instruction"))
             end)

      # 2. Multi-session task: worker calling read_conversation with unresolved/missing session_id -> fail-closed :forbidden
      assert {:ok, multi} = create_multi_session_task(f)
      multi_id = multi["conversation_id"]

      assert {:error, err} =
               Provider.call_api(f.worker, "internal", "internal.read_conversation", %{
                 "connect_id" => "internal",
                 "tool_context" => %{"session_id" => "ses_unknown_does_not_exist"},
                 "params" => %{"conversation_id" => multi_id}
               })

      assert is_binary(err) and err =~ "not an active worker"
    end

    test "task.create -> add_session -> replay original task.create with same op ID succeeds; initial_wake primary wakes primary only",
         f do
      tool_call_id = "tc_replay_after_add_1"
      assert {:ok, created} = create_multi_session_task(f, %{}, %{"tool_call_id" => tool_call_id})
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      # Default initial_wake: "primary" -> opening message wakes primary only, not reviewer
      {:ok, [opening_msg | _]} =
        Conversations.list_group_conversation_messages(f.group, conv_id, limit: 5)

      assert ConversationMessage.targets_participant?(parts.primary, opening_msg)
      refute ConversationMessage.targets_participant?(reviewer, opening_msg)

      # Add a 3rd session
      assert {:ok, %{"added" => true}} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "tester"
               })

      # Replay original task.create with same op ID -> still succeeds idempotently!
      assert {:ok, replayed} =
               create_multi_session_task(f, %{}, %{"tool_call_id" => tool_call_id})

      assert replayed["conversation_id"] == conv_id
    end

    test "TaskRun.switch lock blocks concurrent add_session; multi-session rejects acquire_task_run_switch and replace_task_schedule",
         f do
      assert {:ok, single} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "Switch Lock Task",
                 "content" => "Work",
                 "runs_on" => %{"kind" => "salix"}
               })

      conv_id = single["conversation_id"]

      # Acquire switch lock -> add_session rejected
      assert {:ok, token} = ConversationServer.acquire_task_run_switch(f.group, conv_id)

      assert {:error, lock_err} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer"
               })

      assert lock_err =~ "switch"

      # Release lock -> add_session succeeds
      assert :ok = ConversationServer.release_task_run_switch(f.group, conv_id, token)

      assert {:ok, %{"added" => true}} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer"
               })

      # Now multi-session -> acquire_task_run_switch rejected
      assert {:error, {:bad_request, msg}} =
               ConversationServer.acquire_task_run_switch(f.group, conv_id)

      assert msg =~ "multi-session"

      # Multi-session Task rejects replace_task_schedule
      assert {:error, {:bad_request, sched_msg}} =
               ConversationServer.replace_task_schedule(f.group, conv_id, %{}, %{
                 "schedule_id" => "sch_1",
                 "cron" => "0 * * * *"
               })

      assert sched_msg =~ "multi-session"
    end

    test "deactivating a slot in a full 6-session task and adding another prevents reactivating the deactivated slot",
         f do
      sessions = [
        %{"slot" => "lead", "primary" => true},
        %{"slot" => "s1"},
        %{"slot" => "s2"},
        %{"slot" => "s3"},
        %{"slot" => "s4"},
        %{"slot" => "s5"}
      ]

      assert {:ok, created} = create_multi_session_task(f, %{"sessions" => sessions})
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      s5 = Enum.find(parts.secondaries, &(&1["target_key"] == "s5"))

      # Deactivate s5
      assert {:ok, _} =
               ConversationServer.deactivate_group_conversation_participant(
                 f.group,
                 conv_id,
                 s5["participant_id"]
               )

      # Add s6 (now back at 6 active)
      assert {:ok, %{"added" => true}} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "s6"
               })

      # Reactivating s5 must fail with 6-session cap error
      assert {:error, cap_err} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "s5"
               })

      assert cap_err =~ "limit"
    end

    test "non-worker mentioned participant is not woken by unmentioned messages; later-added session reads prior public messages",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)

      observer_rec =
        SalixAgent.TestSupport.create_control_agent_in_group!(f.tenant, f.group, %{
          "name" => "Observer",
          "role" => "worker"
        })

      {:ok, observer} =
        ConversationServer.ensure_group_conversation_agent_participant(f.group, conv_id, %{
          "actor_type" => "agent",
          "agent_id" => observer_rec["agent_id"],
          "role_label" => "collaborator",
          "state" => "active",
          "payload" => %{"session_id" => Ids.new_session_id()},
          "notification_filter" => %{"messages" => "mentioned", "statuses" => "none"}
        })

      {:ok, user_part} =
        ConversationServer.ensure_group_conversation_user_participant(f.group, conv_id, %{
          "user_id" => f.owner_user
        })

      # Public human message without mentioning observer
      {:ok, pub} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "user",
          "user_id" => f.owner_user,
          "participant_id" => user_part["participant_id"],
          "content" => "Public update before late joiner"
        })

      {:ok, pub_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, pub["message_id"])

      # Observer has notification_filter: mentioned -> NOT woken
      refute ConversationMessage.targets_participant?(observer, pub_msg)
      assert ConversationMessage.targets_participant?(parts.primary, pub_msg)

      # Public message has no delivery_filter restriction -> later-added session can read it!
      assert is_nil(pub_msg["delivery_filter"])

      assert {:ok, added} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "latecomer"
               })

      late_parts = participants_by_role(f, conv_id)

      latecomer =
        Enum.find(late_parts.secondaries, &(&1["participant_id"] == added["participant_id"]))

      assert ConversationMessage.visible_to?(latecomer["participant_id"], pub_msg)

      {:ok, read_res} =
        Provider.call_api(f.worker, "internal", "internal.read_conversation", %{
          "connect_id" => "internal",
          "tool_context" => %{"session_id" => get_in(latecomer, ["payload", "session_id"])},
          "params" => %{"conversation_id" => conv_id}
        })

      assert pub["message_id"] in Enum.map(read_res["messages"], & &1["message_id"])
    end

    test "add_session validates message before creating participant, rejects conflicts & primary slot collision, and deduplicates kickoff retries",
         f do
      assert {:ok, created} =
               create_multi_session_task(f, %{
                 "sessions" => [
                   %{"slot" => "coder", "primary" => true},
                   %{"slot" => "reviewer", "label" => "Rev A", "role" => "Audit"}
                 ]
               })

      conv_id = created["conversation_id"]

      # Non-string message rejected BEFORE creating participant
      assert {:error, msg_err} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "badmsg",
                 "message" => 123
               })

      assert msg_err =~ "string"
      parts_after = participants_by_role(f, conv_id)
      refute Enum.any?(parts_after.secondaries, &(&1["target_key"] == "badmsg"))

      # Slot colliding with primary's custom session_slot ("coder") rejected
      assert {:error, col_err} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "coder"
               })

      assert col_err =~ "primary"

      # Existing slot with different label/role returns conflict
      assert {:error, conf_err} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer",
                 "label" => "Rev B"
               })

      assert conf_err =~ "conflict" or conf_err =~ "different"

      # Kickoff retry with same tool_call_id deduplicates kickoff message
      tc_id = "tc_kickoff_idem_1"

      assert {:ok, first} =
               call_router(
                 f,
                 "internal.task.add_session",
                 %{
                   "conversation_id" => conv_id,
                   "slot" => "tester",
                   "message" => "Run integration tests"
                 },
                 %{"tool_call_id" => tc_id}
               )

      assert {:ok, second} =
               call_router(
                 f,
                 "internal.task.add_session",
                 %{
                   "conversation_id" => conv_id,
                   "slot" => "tester",
                   "message" => "Run integration tests"
                 },
                 %{"tool_call_id" => tc_id}
               )

      assert first["kickoff_message_id"] == second["kickoff_message_id"]
    end

    test "TaskExecution grant applies to primary only and never to secondary or kickoff", f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      {:ok, [opening_msg | _]} =
        Conversations.list_group_conversation_messages(f.group, conv_id, limit: 5)

      {:ok, primary_source} =
        SalixIM.ConversationSourceIdentity.encode(
          conv_id,
          opening_msg["message_id"],
          parts.primary["participant_id"]
        )

      primary_ctx = %{
        "agent_id" => f.worker,
        "session_id" => get_in(parts.primary, ["payload", "session_id"]),
        "source_message_id" => primary_source,
        "source_message_ids" => [primary_source],
        "trusted_origin" => %{
          "provider" => "internal",
          "conversation_kind" => "agent_task",
          "agent_group_id" => f.group,
          "conversation_id" => conv_id,
          "participant_id" => parts.primary["participant_id"],
          "message_id" => opening_msg["message_id"]
        }
      }

      # Primary succeeds with agent principal via assigned_command -> participant_session
      {:ok, expected_principal} = SalixIFC.Codec.encode_principal({:agent, f.worker})
      send_args = %{"connect_id" => "internal", "conversation_id" => conv_id}

      assert {:ok, ^primary_source, ^expected_principal} =
               TaskExecution.ifc_request("im_api.internal.send_message", send_args, primary_ctx)

      # Secondary rejected on opening message
      {:ok, sec_source} =
        SalixIM.ConversationSourceIdentity.encode(
          conv_id,
          opening_msg["message_id"],
          reviewer["participant_id"]
        )

      sec_ctx = %{
        "agent_id" => f.worker,
        "session_id" => get_in(reviewer, ["payload", "session_id"]),
        "source_message_id" => sec_source,
        "source_message_ids" => [sec_source],
        "trusted_origin" => %{
          "provider" => "internal",
          "conversation_kind" => "agent_task",
          "agent_group_id" => f.group,
          "conversation_id" => conv_id,
          "participant_id" => reviewer["participant_id"],
          "message_id" => opening_msg["message_id"]
        }
      }

      assert :none = TaskExecution.ifc_request("im_api.internal.send_message", send_args, sec_ctx)

      # Kickoff message for a newly added secondary also never inherits TaskExecution grant
      assert {:ok, added} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "auditor",
                 "message" => "Audit kickoff"
               })

      auditor_parts = participants_by_role(f, conv_id)

      auditor =
        Enum.find(auditor_parts.secondaries, &(&1["participant_id"] == added["participant_id"]))

      {:ok, kickoff_source} =
        SalixIM.ConversationSourceIdentity.encode(
          conv_id,
          added["kickoff_message_id"],
          auditor["participant_id"]
        )

      kickoff_ctx = %{
        "agent_id" => f.worker,
        "session_id" => get_in(auditor, ["payload", "session_id"]),
        "source_message_id" => kickoff_source,
        "source_message_ids" => [kickoff_source],
        "trusted_origin" => %{
          "provider" => "internal",
          "conversation_kind" => "agent_task",
          "agent_group_id" => f.group,
          "conversation_id" => conv_id,
          "participant_id" => auditor["participant_id"],
          "message_id" => added["kickoff_message_id"]
        }
      }

      assert :none =
               TaskExecution.ifc_request("im_api.internal.send_message", send_args, kickoff_ctx)
    end

    test "TaskCardProjection filters peer_handoff across initial/advance/refresh and secondary @router wakes task_card provider",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      # Add a task_card provider participant
      {:ok, card_part} =
        ConversationServer.ensure_group_conversation_provider_participant(f.group, conv_id, %{
          "actor_type" => "provider",
          "provider" => "slack",
          "role_label" => "task_card",
          "target_key" => "task-card-1",
          "state" => "active",
          "notification_filter" => %{"messages" => "all", "statuses" => "all"},
          "payload" => %{
            "projection" => "task_card",
            "connect_id" => "conn_card_1",
            "channel_id" => "C_card_1"
          }
        })

      # Secondary peer message -> NOT woke on card_part, NOT projected
      {:ok, peer} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "agent",
          "agent_id" => f.worker,
          "participant_id" => reviewer["participant_id"],
          "content" => "@lead internal note"
        })

      {:ok, peer_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, peer["message_id"])

      refute ConversationMessage.targets_participant?(card_part, peer_msg)

      # Secondary @router -> DOES wake card_part and IS projected
      {:ok, esc} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "agent",
          "agent_id" => f.worker,
          "participant_id" => reviewer["participant_id"],
          "content" => "@router Escalation visible on card"
        })

      {:ok, esc_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, esc["message_id"])

      assert ConversationMessage.targets_participant?(card_part, esc_msg)

      # TaskCardProjection.initial_payload persists primary_worker_participant_id and excludes peer_msg
      {:ok, conv} = Conversations.get_group_conversation(f.group, conv_id)
      {:ok, initial} = TaskCardProjection.initial_payload(conv)
      assert initial["primary_worker_participant_id"] == parts.primary["participant_id"]
      initial_texts = Enum.map(initial["recent_messages"] || [], & &1["text"])
      assert Enum.any?(initial_texts, &(&1 =~ "Escalation visible on card"))
      refute Enum.any?(initial_texts, &(&1 =~ "internal note"))
    end

    test "TaskWorkerWatch isolates cross-session nudges", _f do
      delegation = %{
        "seq" => 2,
        "message_id" => "msg1_del",
        "actor_type" => "user",
        "participant_id" => "prt1_user",
        "content" => [%{"type" => "text", "text" => "@lead @reviewer please check"}],
        "metadata" => %{"wake_targets" => ["prt1_primary", "prt1_sec"]}
      }

      nudge_for_primary = %{
        "seq" => 3,
        "message_id" => "msg1_nudge_p",
        "actor_type" => "system",
        "content" => [%{"type" => "text", "text" => "nudge"}],
        "delivery_filter" => %{"participant_ids" => ["prt1_primary"]},
        "metadata" => %{
          "message_type" => "task_worker_nudge",
          "task_worker_watch" => %{
            "target_participant_id" => "prt1_primary",
            "delegation_seq" => 2,
            "delegation_message_id" => "msg1_del",
            "activity_version" => "v1"
          }
        }
      }

      # Primary already nudged on v1 and stopped again on v2 -> :notify
      assert {:notify, 2, "stopped_after_reminder"} =
               TaskWorkerWatch.decide(
                 [delegation, nudge_for_primary],
                 %{
                   worker_participant_id: "prt1_primary",
                   worker_agent_id: "agt1_w",
                   primary?: true
                 },
                 :stopped,
                 nil,
                 "v2"
               )

      # Secondary was NOT nudged yet -> still gets :nudge (not suppressed by primary's nudge!)
      assert {:nudge, 2, "msg1_del"} =
               TaskWorkerWatch.decide(
                 [delegation, nudge_for_primary],
                 %{
                   worker_participant_id: "prt1_sec",
                   worker_agent_id: "agt1_w",
                   primary?: false
                 },
                 :stopped,
                 nil,
                 "v2"
               )
    end

    test "pending Loop task rejects add_session", f do
      assert {:ok, single} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "Pending Loop Task",
                 "content" => "Monitor health",
                 "runs_on" => %{"kind" => "salix"},
                 "loop" => %{"cadence" => %{"every_minutes" => 5}}
               })

      conv_id = single["conversation_id"]

      assert {:error, loop_err} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer"
               })

      assert loop_err =~ "Loop"
    end

    test "catch-up summary extracts file_name, caps at 20 messages, and returns retryable error on list failure",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      {:ok, roster} =
        ConversationServer.get_group_conversation_task_worker_identities(f.group, conv_id)

      # 25 messages with file_name attachment on the last one -> only latest 20 included
      msgs =
        for seq <- 1..25 do
          content =
            if seq == 25 do
              [
                %{"type" => "text", "text" => "msg_marker_#{seq}"},
                %{"type" => "file", "file_name" => "audit_report.pdf"}
              ]
            else
              [%{"type" => "text", "text" => "msg_marker_#{seq}"}]
            end

          %{
            "seq" => seq,
            "message_id" => "msg1_#{seq}",
            "actor_type" => "user",
            "participant_id" => "prt1_user",
            "content" => content,
            "metadata" => %{"wake_targets" => [parts.primary["participant_id"]]}
          }
        end

      summary = TaskSessionSlots.build_catchup_summary(reviewer, roster["workers"], msgs, 0)
      assert summary =~ "msg_marker_25"
      assert summary =~ "msg_marker_6"
      refute summary =~ "msg_marker_5"
      assert summary =~ "audit_report.pdf"
      assert byte_size(summary) <= 16_384

      # Retryable error when catch-up message listing fails (nonexistent group/conversation)
      missing_group = Ids.new_group_id(f.tenant)
      missing_conv = Ids.new_conversation_id()

      bad_record = %{
        "agent_group_id" => missing_group,
        "conversation_id" => missing_conv,
        "conversation_kind" => "agent_task",
        "conversation_multi_session" => true,
        "participant_id" => reviewer["participant_id"],
        "participant_agent_id" => f.worker,
        "participant_role_label" => "worker",
        "participant_target_key" => "reviewer",
        "participant_payload" => reviewer["payload"],
        "message_id" => Ids.new_message_id(),
        "message_seq" => 10,
        "message_content" => [%{"type" => "text", "text" => "hi"}],
        "message_created_at" => SystemsClock.system_time(:millisecond)
      }

      assert {:error, {:multi_session_catchup_unavailable, _reason}, true} =
               ConversationDelivery.materialize_agent(bad_record)
    end
  end

  describe "R3 review regression coverage (items 1-10)" do
    test "item 1: deactivated secondary fails closed with string error after shrink to 1; primary filters secondary-only messages; router sees all",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      {:ok, user_part} =
        ConversationServer.ensure_group_conversation_user_participant(f.group, conv_id, %{
          "user_id" => f.owner_user
        })

      # Public message
      {:ok, pub} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "user",
          "user_id" => f.owner_user,
          "participant_id" => user_part["participant_id"],
          "content" => "Public note for everyone"
        })

      # Secondary-only private message (mentions + delivery_filter targeting reviewer only)
      {:ok, sec_only} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "user",
          "user_id" => f.owner_user,
          "participant_id" => user_part["participant_id"],
          "content" => "Private note for reviewer only",
          "delivery_filter" => %{"participant_ids" => [reviewer["participant_id"]]},
          "mentions" => %{"participant_ids" => [reviewer["participant_id"]]}
        })

      # Primary read_conversation: sees public note, does NOT see secondary-only message
      {:ok, primary_read} =
        Provider.call_api(f.worker, "internal", "internal.read_conversation", %{
          "connect_id" => "internal",
          "tool_context" => %{"session_id" => get_in(parts.primary, ["payload", "session_id"])},
          "params" => %{"conversation_id" => conv_id}
        })

      primary_ids = Enum.map(primary_read["messages"], & &1["message_id"])
      assert pub["message_id"] in primary_ids
      refute sec_only["message_id"] in primary_ids

      # Router read_conversation: sees ALL messages including secondary-only
      {:ok, router_read} =
        call_router(f, "internal.read_conversation", %{"conversation_id" => conv_id})

      router_ids = Enum.map(router_read["messages"], & &1["message_id"])
      assert pub["message_id"] in router_ids
      assert sec_only["message_id"] in router_ids

      # Deactivate reviewer so task shrinks back to 1 active worker
      assert {:ok, _} =
               ConversationServer.deactivate_group_conversation_participant(
                 f.group,
                 conv_id,
                 reviewer["participant_id"]
               )

      # Deactivated reviewer's session_id calls read_conversation -> fail-closed string error!
      assert {:error, err} =
               Provider.call_api(f.worker, "internal", "internal.read_conversation", %{
                 "connect_id" => "internal",
                 "tool_context" => %{"session_id" => get_in(reviewer, ["payload", "session_id"])},
                 "params" => %{"conversation_id" => conv_id}
               })

      assert is_binary(err)
      assert err =~ "not an active worker"
    end

    test "item 2a & 2b: changing primary session model on same create identity conflicts; deactivating initial slot keeps replay idempotent",
         f do
      # 2a: Same tool_call_id + title + content but changed sessions[primary].model -> conflict, no 2nd task
      tc_id = "tc_model_conflict_1"

      assert {:ok, first} =
               create_multi_session_task(
                 f,
                 %{
                   "sessions" => [
                     %{
                       "slot" => "lead",
                       "primary" => true,
                       "model" => %{"kind" => "catalog", "name" => "claude-opus-5-5"}
                     },
                     %{"slot" => "reviewer"}
                   ]
                 },
                 %{"tool_call_id" => tc_id}
               )

      assert {:error, conflict_err} =
               create_multi_session_task(
                 f,
                 %{
                   "sessions" => [
                     %{
                       "slot" => "lead",
                       "primary" => true,
                       "model" => %{"kind" => "catalog", "name" => "gpt-6.2-sol"}
                     },
                     %{"slot" => "reviewer"}
                   ]
                 },
                 %{"tool_call_id" => tc_id}
               )

      assert conflict_err =~ "conflict" or conflict_err =~ "different"

      # 2b: Deactivate initial secondary slot ("reviewer"), then replay original task.create -> succeeds!
      parts = participants_by_role(f, first["conversation_id"])
      [reviewer] = parts.secondaries

      assert {:ok, _} =
               ConversationServer.deactivate_group_conversation_participant(
                 f.group,
                 first["conversation_id"],
                 reviewer["participant_id"]
               )

      assert {:ok, replayed} =
               create_multi_session_task(
                 f,
                 %{
                   "sessions" => [
                     %{
                       "slot" => "lead",
                       "primary" => true,
                       "model" => %{"kind" => "catalog", "name" => "claude-opus-5-5"}
                     },
                     %{"slot" => "reviewer"}
                   ]
                 },
                 %{"tool_call_id" => tc_id}
               )

      assert replayed["conversation_id"] == first["conversation_id"]
    end

    test "item 3: in-memory task_run_switch guard blocks concurrent switch and add_session, and releases on release or holder :DOWN",
         f do
      assert {:ok, single} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "In-Memory Switch Guard",
                 "content" => "Work",
                 "runs_on" => %{"kind" => "salix"}
               })

      conv_id = single["conversation_id"]
      {:ok, actor_pid} = SalixIM.ConversationFleet.ensure_started(f.group, conv_id)

      # Acquire in-memory monitor-backed guard
      assert {:ok, token} = ConversationServer.acquire_task_run_switch(f.group, conv_id)

      # Concurrent acquire_task_run_switch and add_session are both rejected with :conflict
      assert {:error, {:conflict, "task run switch already in progress"}} =
               ConversationServer.acquire_task_run_switch(f.group, conv_id)

      assert {:error, lock_err} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer"
               })

      assert lock_err =~ "task run switch is in progress"

      # Releasing unlocks immediately
      assert :ok = ConversationServer.release_task_run_switch(f.group, conv_id, token)

      # Separate holder process acquires lock, then exits (:DOWN) -> guard auto-clears!
      {:ok, holder_pid} = Agent.start(fn -> nil end)

      assert {:ok, _holder_token} =
               Agent.get(holder_pid, fn _ ->
                 ConversationServer.acquire_task_run_switch(f.group, conv_id)
               end)

      assert {:error, {:conflict, "task run switch already in progress"}} =
               ConversationServer.acquire_task_run_switch(f.group, conv_id)

      :ok = Agent.stop(holder_pid)
      _ = :sys.get_state(actor_pid)

      assert {:ok, %{"added" => true}} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer"
               })
    end

    test "item 4: add_session with label+role+model+message retries idempotently, conflicts on diff settings, and rejects closed task at owner",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      tc_id = "tc_add_idem_full_1"

      add_params = %{
        "conversation_id" => conv_id,
        "slot" => "auditor",
        "label" => "Security Auditor",
        "role" => "Audit auth boundaries",
        "model" => %{"kind" => "catalog", "name" => "claude-opus-5-5"},
        "message" => "Please audit auth."
      }

      assert {:ok, first} =
               call_router(f, "internal.task.add_session", add_params, %{"tool_call_id" => tc_id})

      assert is_binary(first["kickoff_message_id"])

      # Verbatim retry succeeds and returns the exact same kickoff_message_id!
      assert {:ok, second} =
               call_router(f, "internal.task.add_session", add_params, %{"tool_call_id" => tc_id})

      assert second["participant_id"] == first["participant_id"]
      assert second["kickoff_message_id"] == first["kickoff_message_id"]

      # Changing label/role/model on same slot returns conflict
      assert {:error, conf_err} =
               call_router(
                 f,
                 "internal.task.add_session",
                 Map.put(add_params, "role", "Different role")
               )

      assert conf_err =~ "conflict" or conf_err =~ "different"

      # Closing task rejects direct owner-level secondary worker creation
      assert {:ok, _} =
               ConversationServer.update_group_conversation(f.group, conv_id, %{
                 "status" => "completed"
               })

      assert {:error, {:bad_request, status_err}} =
               ConversationServer.ensure_group_conversation_agent_participant(f.group, conv_id, %{
                 "actor_type" => "agent",
                 "agent_id" => f.worker,
                 "role_label" => "worker",
                 "target_key" => "late_after_close",
                 "state" => "active",
                 "payload" => %{"session_id" => Ids.new_session_id()},
                 "notification_filter" => %{"messages" => "mentioned", "statuses" => "none"}
               })

      assert status_err =~ "completed"
    end

    test "item 5: 9th-hop PG :exists replay recovers handoff_cap_reached and frozen router targets idempotently",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      # Execute 8 consecutive worker->worker hops
      for i <- 1..8 do
        {sender_pid, text} =
          if rem(i, 2) == 1,
            do: {parts.primary["participant_id"], "@reviewer hop #{i}"},
            else: {reviewer["participant_id"], "@lead hop #{i}"}

        assert {:ok, _} =
                 ConversationServer.append_group_conversation_message(f.group, conv_id, %{
                   "actor_type" => "agent",
                   "agent_id" => f.worker,
                   "participant_id" => sender_pid,
                   "content" => text
                 })
      end

      # 9th hop with stable client_request_id
      hop9_attrs = %{
        "actor_type" => "agent",
        "agent_id" => f.worker,
        "participant_id" => parts.primary["participant_id"],
        "client_request_id" => "hop9-replay-test-1",
        "content" => "@reviewer hop 9"
      }

      assert {:ok, hop9_first} =
               ConversationServer.append_group_conversation_message(f.group, conv_id, hop9_attrs)

      {:ok, hop9_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, hop9_first["message_id"])

      assert get_in(hop9_msg, ["metadata", "handoff_cap_reached"]) == true

      assert get_in(hop9_msg, ["metadata", "handoff_cap_router_targets"]) == [
               parts.router["participant_id"]
             ]

      # Replay the exact same 9th hop -> hits PG :exists path, recovers metadata, stays idempotent (still 1 cap notice)
      assert {:ok, hop9_replay} =
               ConversationServer.append_group_conversation_message(f.group, conv_id, hop9_attrs)

      assert hop9_replay["message_id"] == hop9_first["message_id"]

      {:ok, all_msgs} =
        Conversations.list_group_conversation_messages(f.group, conv_id, limit: 50)

      cap_notices =
        Enum.filter(all_msgs, &(get_in(&1, ["metadata", "message_type"]) == "worker_handoff_cap"))

      assert length(cap_notices) == 1
    end

    test "item 6: multi-session sandbox+repo unlocked in PR 2; single-session cloud_vm + model succeeds; top-level vs primary model conflict rejected",
         f do
      FakeTaskCreate.reset_runs_on_calls()

      # PR 2 unlocks multi-session + sandbox + repo
      assert {:ok, created} =
               create_multi_session_task(f, %{
                 "runs_on" => %{"kind" => "sandbox"},
                 "repo" => %{"owner" => "acme", "name" => "api"}
               })

      assert is_binary(created["conversation_id"])
      assert FakeTaskCreate.runs_on_calls() == 1

      # Conflicting top-level model vs sessions[primary].model rejected
      assert {:error, conflict_err} =
               create_multi_session_task(f, %{
                 "model" => %{"kind" => "catalog", "name" => "gpt-6.2-sol"},
                 "sessions" => [
                   %{
                     "slot" => "lead",
                     "primary" => true,
                     "model" => %{"kind" => "catalog", "name" => "claude-opus-5-5"}
                   },
                   %{"slot" => "reviewer"}
                 ]
               })

      assert conflict_err =~ "conflicts"

      # Single-session Cloud VM + runtime model succeeds without invalid_runs_on
      assert {:ok, cloud_task} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "Single Cloud VM Task",
                 "content" => "Run on cloud VM",
                 "runs_on" => %{"kind" => "cloud_vm"},
                 "sessions" => [
                   %{
                     "slot" => "lead",
                     "primary" => true,
                     "model" => %{"kind" => "runtime", "provider" => "codex"}
                   }
                 ]
               })

      assert is_binary(cloud_task["conversation_id"])
    end

    test "item 7: TaskWorkerWatch handles unwoken secondary (:not_found), subscribe failure on active secondary, and transient read error recovery",
         f do
      # Case A: unwoken secondary returns {:error, :not_found} -> primary result triggers task_status_pending
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [_reviewer] = parts.secondaries

      primary_ref = {f.worker, get_in(parts.primary, ["payload", "session_id"])}
      router_ref = {f.router, f.router_session}

      # Primary posts result
      assert {:ok, _} =
               ConversationServer.append_group_conversation_message(f.group, conv_id, %{
                 "actor_type" => "agent",
                 "agent_id" => f.worker,
                 "participant_id" => parts.primary["participant_id"],
                 "content" => "Completed all requested work."
               })

      now_ms = SystemsClock.system_time(:millisecond)

      # Secondary is NOT in FakeSessionActivity -> returns {:error, :not_found} (unwoken!)
      FakeSessionActivity.set(%{
        primary_ref => %{"state" => "stopped", "version" => "wp1", "updated_at" => now_ms},
        router_ref => %{"state" => "stopped", "version" => "rt1", "updated_at" => now_ms + 1}
      })

      {:ok, owner_pid} = ConversationPlacement.ensure_started(f.group, conv_id)

      %{worker_watch_pid: watch_pid, worker_watch_capability: watch_cap} =
        :sys.get_state(owner_pid)

      GenServer.cast(watch_pid, {:reconcile, owner_pid, watch_cap, false})
      _ = :sys.get_state(watch_pid)

      # Advance clock past grace period + review grace period
      SystemsClock.advance(TaskWorkerWatch.grace_ms() + 1_000)
      _ = :sys.get_state(watch_pid)
      SystemsClock.advance(TaskWorkerWatch.grace_ms() + 1_000)
      _ = :sys.get_state(watch_pid)

      {:ok, msgs} = Conversations.list_group_conversation_messages(f.group, conv_id, limit: 20)

      assert Enum.any?(
               msgs,
               &(get_in(&1, ["metadata", "message_type"]) == TaskWorkerWatch.status_type())
             )

      # Case B & C: secondary subscribe fails while active (no premature review), then transient error -> recovers to stopped -> sends review!
      assert {:ok, created2} = create_multi_session_task(f)
      conv2 = created2["conversation_id"]
      parts2 = participants_by_role(f, conv2)
      [rev2] = parts2.secondaries

      p2_ref = {f.worker, get_in(parts2.primary, ["payload", "session_id"])}
      s2_ref = {f.worker, get_in(rev2, ["payload", "session_id"])}

      assert {:ok, _} =
               ConversationServer.append_group_conversation_message(f.group, conv2, %{
                 "actor_type" => "agent",
                 "agent_id" => f.worker,
                 "participant_id" => parts2.primary["participant_id"],
                 "content" => "Primary finished."
               })

      now2 = SystemsClock.system_time(:millisecond)
      FakeSessionActivity.set_subscribe_errors([s2_ref])

      FakeSessionActivity.set(%{
        p2_ref => %{"state" => "stopped", "version" => "wp2", "updated_at" => now2},
        s2_ref => %{"state" => "active", "version" => "ws2", "updated_at" => now2},
        router_ref => %{"state" => "stopped", "version" => "rt2", "updated_at" => now2 + 1}
      })

      {:ok, owner2} = ConversationPlacement.ensure_started(f.group, conv2)
      %{worker_watch_pid: watch2, worker_watch_capability: cap2} = :sys.get_state(owner2)

      GenServer.cast(watch2, {:reconcile, owner2, cap2, false})
      _ = :sys.get_state(watch2)

      # Even though subscribe failed for s2_ref, s2_ref is still tracked and active -> NO task_status_pending yet!
      SystemsClock.advance(TaskWorkerWatch.grace_ms() + 1_000)
      _ = :sys.get_state(watch2)
      SystemsClock.advance(TaskWorkerWatch.grace_ms() + 1_000)
      _ = :sys.get_state(watch2)

      {:ok, msgs2_busy} =
        Conversations.list_group_conversation_messages(f.group, conv2, limit: 20)

      refute Enum.any?(
               msgs2_busy,
               &(get_in(&1, ["metadata", "message_type"]) == TaskWorkerWatch.status_type())
             )

      # Now test transient read error recovery on a fresh primary stop:
      # First read returns {:error, :timeout}, next read returns stopped -> review is NOT lost!
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

      now3 = SystemsClock.system_time(:millisecond)

      FakeSessionActivity.set(%{
        p2_ref => %{"state" => "stopped", "version" => "wp3", "updated_at" => now3},
        s2_ref => fn ->
          n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

          if n == 0,
            do: {:error, :timeout},
            else: {:ok, %{"state" => "stopped", "version" => "ws3", "updated_at" => now3}}
        end,
        router_ref => %{"state" => "stopped", "version" => "rt3", "updated_at" => now3 + 1}
      })

      send(watch2, {:session_activity_updated, f.worker, elem(p2_ref, 1)})
      _ = :sys.get_state(watch2)

      # Grace timeout hits transient {:error, :timeout} -> schedules retry instead of dropping!
      SystemsClock.advance(TaskWorkerWatch.grace_ms() + 1_000)
      _ = :sys.get_state(watch2)
      # Retry fires, s2_ref now returns stopped -> begins review!
      SystemsClock.advance(30_000)
      _ = :sys.get_state(watch2)
      # Review grace expires -> sends task_status_pending!
      SystemsClock.advance(TaskWorkerWatch.grace_ms() + 1_000)
      _ = :sys.get_state(watch2)

      {:ok, msgs2_done} =
        Conversations.list_group_conversation_messages(f.group, conv2, limit: 20)

      assert Enum.any?(
               msgs2_done,
               &(get_in(&1, ["metadata", "message_type"]) == TaskWorkerWatch.status_type())
             )
    end

    test "item 9: real TaskExecution requester grant applies to primary only (not secondary or kickoff) & TaskCardProjection 4-path consistency",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      {:ok, [opening_msg | _]} =
        Conversations.list_group_conversation_messages(f.group, conv_id, limit: 5)

      # Attach a real authorized requester grant (composio.execute) directly to the task's source_refs
      expected_requester_principal = "provider_user|conn_1|U1"

      grant = %{
        "requester" => expected_requester_principal,
        "worker_agent_id" => f.worker,
        "requests" => [
          %{
            "provider" => "composio",
            "params" => %{
              "tool_slug" => "GMAIL_SEND",
              "connected_account_id" => "acc_1",
              "arguments" => %{}
            }
          }
        ]
      }

      {:ok, conv_before} = Conversations.get_group_conversation(f.group, conv_id)

      # Temporarily allow updating protected source_ref in test to attach the real grant
      prev_contracts = SystemsRuntime.get_env(:salix_im, :protected_source_ref_contracts)
      SystemsRuntime.put_env(:salix_im, :protected_source_ref_contracts, [])

      on_exit(fn ->
        restore_env(:salix_im, :protected_source_ref_contracts, prev_contracts)
      end)

      assert {:ok, _} =
               ConversationServer.update_group_conversation(f.group, conv_id, %{
                 "source_refs" =>
                   Map.put(conv_before["source_refs"] || %{}, "task_execution", grant)
               })

      SystemsRuntime.put_env(:salix_im, :protected_source_ref_contracts, prev_contracts)

      composio_args = %{
        "tool_slug" => "GMAIL_SEND",
        "connected_account_id" => "acc_1",
        "arguments" => %{}
      }

      # 1. Primary hits requester grant positive path (returns comma_user|<owner>, NOT agent principal!)
      {:ok, p_source} =
        SalixIM.ConversationSourceIdentity.encode(
          conv_id,
          opening_msg["message_id"],
          parts.primary["participant_id"]
        )

      p_ctx = %{
        "agent_id" => f.worker,
        "session_id" => get_in(parts.primary, ["payload", "session_id"]),
        "source_message_id" => p_source,
        "source_message_ids" => [p_source],
        "trusted_origin" => %{
          "provider" => "internal",
          "conversation_kind" => "agent_task",
          "agent_group_id" => f.group,
          "conversation_id" => conv_id,
          "participant_id" => parts.primary["participant_id"],
          "message_id" => opening_msg["message_id"]
        }
      }

      assert {:ok, ^p_source, ^expected_requester_principal} =
               TaskExecution.ifc_request("composio.execute", composio_args, p_ctx)

      # 2. Delegated secondary on the same opening message does NOT inherit requester grant
      {:ok, s_source} =
        SalixIM.ConversationSourceIdentity.encode(
          conv_id,
          opening_msg["message_id"],
          reviewer["participant_id"]
        )

      s_ctx = %{
        "agent_id" => f.worker,
        "session_id" => get_in(reviewer, ["payload", "session_id"]),
        "source_message_id" => s_source,
        "source_message_ids" => [s_source],
        "trusted_origin" => %{
          "provider" => "internal",
          "conversation_kind" => "agent_task",
          "agent_group_id" => f.group,
          "conversation_id" => conv_id,
          "participant_id" => reviewer["participant_id"],
          "message_id" => opening_msg["message_id"]
        }
      }

      assert :none = TaskExecution.ifc_request("composio.execute", composio_args, s_ctx)

      # 3. Kickoff message for a newly added secondary does NOT inherit requester grant
      assert {:ok, added} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "sec_grant_test",
                 "message" => "Kickoff without grant"
               })

      parts_after = participants_by_role(f, conv_id)

      sec_new =
        Enum.find(parts_after.secondaries, &(&1["participant_id"] == added["participant_id"]))

      {:ok, k_source} =
        SalixIM.ConversationSourceIdentity.encode(
          conv_id,
          added["kickoff_message_id"],
          sec_new["participant_id"]
        )

      k_ctx = %{
        "agent_id" => f.worker,
        "session_id" => get_in(sec_new, ["payload", "session_id"]),
        "source_message_id" => k_source,
        "source_message_ids" => [k_source],
        "trusted_origin" => %{
          "provider" => "internal",
          "conversation_kind" => "agent_task",
          "agent_group_id" => f.group,
          "conversation_id" => conv_id,
          "participant_id" => sec_new["participant_id"],
          "message_id" => added["kickoff_message_id"]
        }
      }

      assert :none = TaskExecution.ifc_request("composio.execute", composio_args, k_ctx)

      # TaskCardProjection 4-path consistency: initial_payload, advance, refresh, output
      {:ok, conv_init} = Conversations.get_group_conversation(f.group, conv_id)
      {:ok, base_payload} = TaskCardProjection.initial_payload(conv_init)

      # Post: (1) primary update, (2) secondary peer handoff, (3) secondary @router escalation
      {:ok, p_post} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "agent",
          "agent_id" => f.worker,
          "participant_id" => parts.primary["participant_id"],
          "content" => "Primary summary output"
        })

      {:ok, peer_post} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "agent",
          "agent_id" => f.worker,
          "participant_id" => reviewer["participant_id"],
          "content" => "@lead internal peer handoff"
        })

      {:ok, esc_post} =
        ConversationServer.append_group_conversation_message(f.group, conv_id, %{
          "actor_type" => "agent",
          "agent_id" => f.worker,
          "participant_id" => reviewer["participant_id"],
          "content" => "@router Escalation output"
        })

      {:ok, p_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, p_post["message_id"])

      {:ok, peer_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, peer_post["message_id"])

      {:ok, esc_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, esc_post["message_id"])

      {:ok, conv_now} = Conversations.get_group_conversation(f.group, conv_id)

      # Path 1: initial_payload (full build)
      {:ok, built} = TaskCardProjection.initial_payload(conv_now)
      # Path 2: advance (incremental)
      advanced =
        Enum.reduce([p_msg, peer_msg, esc_msg], base_payload, fn msg, acc ->
          TaskCardProjection.advance(acc, %{
            "agent_group_id" => f.group,
            "conversation_id" => conv_id,
            "conversation_status" => conv_now["status"],
            "conversation_title" => conv_now["title"],
            "message_seq" => msg["seq"],
            "source_actor_type" => msg["actor_type"],
            "source_agent_id" => msg["agent_id"],
            "source_participant_id" => msg["participant_id"],
            "message_content" => msg["content"],
            "message_metadata" => msg["metadata"]
          })
        end)

      # Path 3: refresh (rebuild)
      {:ok, refreshed} =
        TaskCardProjection.refresh(base_payload, %{
          "agent_group_id" => f.group,
          "conversation_id" => conv_id,
          "message_seq" => esc_msg["seq"]
        })

      for {label, proj} <- [built: built, advanced: advanced, refreshed: refreshed] do
        texts = Enum.map(proj["recent_messages"] || [], & &1["text"])
        assert Enum.any?(texts, &(&1 =~ "Primary summary output")), "#{label} missing primary"
        assert Enum.any?(texts, &(&1 =~ "Escalation output")), "#{label} missing @router"
        refute Enum.any?(texts, &(&1 =~ "internal peer handoff")), "#{label} leaked peer handoff"

        # Path 4: output/1 matches latest projectable message (@router escalation, never peer handoff)
        assert TaskCardProjection.output(proj) =~ "Escalation output", "#{label} output mismatch"
      end
    end
  end

  describe "R4 final review regression coverage (items 1-7)" do
    test "item 2: multi-session owner rejects TaskRun.switch and update_group_conversation(runs_on), and active station binding blocks add_session",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]

      # Multi-session Task rejects TaskRun.switch and update_group_conversation(runs_on) at owner
      assert {:error, {:bad_request, msg}} =
               TaskRun.switch(
                 f.group,
                 conv_id,
                 %{"runs_on" => %{"kind" => "cloud_vm"}},
                 f.owner_user
               )

      assert msg =~ "multi-session"

      assert {:error, {:bad_request, upd_msg}} =
               ConversationServer.update_group_conversation(f.group, conv_id, %{
                 "runs_on" => %{"kind" => "cloud_vm"}
               })

      assert upd_msg =~ "multi-session"

      # PR 2 unlocks add_session on station-backed Tasks (including legacy single-session upgrade).
      assert {:ok, single} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "Legacy Upgrade Task",
                 "content" => "Work",
                 "runs_on" => %{"kind" => "salix"}
               })

      single_id = single["conversation_id"]
      FakeTaskStations.set_sessions(%{})

      assert {:ok, %{"added" => true}} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => single_id,
                 "slot" => "reviewer"
               })
    end

    test "item 3 & 4: structured mentions on 9th hop still notifies Router ([R] ∩ base) and PG :exists replay preserves frozen wake_targets",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      # First test ordinary multi-session message PG :exists replay preserves frozen wake_targets
      sec_only_attrs = %{
        "actor_type" => "agent",
        "agent_id" => f.worker,
        "participant_id" => parts.primary["participant_id"],
        "client_request_id" => "ordinary-replay-r4-1",
        "content" => "@reviewer check this module"
      }

      assert {:ok, first_res} =
               ConversationServer.append_group_conversation_message(
                 f.group,
                 conv_id,
                 sec_only_attrs
               )

      assert {:ok, replay_res} =
               ConversationServer.append_group_conversation_message(
                 f.group,
                 conv_id,
                 sec_only_attrs
               )

      assert replay_res["message_id"] == first_res["message_id"]

      {:ok, replayed_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, replay_res["message_id"])

      assert get_in(replayed_msg, ["metadata", "wake_targets"]) == [reviewer["participant_id"]]

      # 7 more hops (total 8 hops; sec_only_attrs was hop 1)
      for i <- 2..8 do
        {sender_pid, text} =
          if rem(i, 2) == 0,
            do: {reviewer["participant_id"], "@lead hop #{i}"},
            else: {parts.primary["participant_id"], "@reviewer hop #{i}"}

        assert {:ok, _} =
                 ConversationServer.append_group_conversation_message(f.group, conv_id, %{
                   "actor_type" => "agent",
                   "agent_id" => f.worker,
                   "participant_id" => sender_pid,
                   "content" => text
                 })
      end

      # 9th hop with explicit structured mentions targeting ONLY reviewer (excluding router in mentions!)
      hop9_attrs = %{
        "actor_type" => "agent",
        "agent_id" => f.worker,
        "participant_id" => parts.primary["participant_id"],
        "client_request_id" => "hop9-structured-mentions-r4",
        "content" => "please inspect",
        "mentions" => %{"participant_ids" => [reviewer["participant_id"]]}
      }

      assert {:ok, hop9_first} =
               ConversationServer.append_group_conversation_message(f.group, conv_id, hop9_attrs)

      assert is_nil(hop9_first["wakeup_participant_ids"]) or
               hop9_first["wakeup_participant_ids"] == []

      {:ok, hop9_msg} =
        Conversations.get_group_conversation_message(f.group, conv_id, hop9_first["message_id"])

      assert get_in(hop9_msg, ["metadata", "wake_targets"]) == []

      assert get_in(hop9_msg, ["metadata", "handoff_cap_router_targets"]) == [
               parts.router["participant_id"]
             ]

      # PG :exists replay of 9th hop preserves empty wakeup_participant_ids
      assert {:ok, hop9_replay} =
               ConversationServer.append_group_conversation_message(f.group, conv_id, hop9_attrs)

      assert hop9_replay["message_id"] == hop9_first["message_id"]

      assert is_nil(hop9_replay["wakeup_participant_ids"]) or
               hop9_replay["wakeup_participant_ids"] == []

      {:ok, all_msgs} =
        Conversations.list_group_conversation_messages(f.group, conv_id, limit: 50)

      cap_notices =
        Enum.filter(all_msgs, &(get_in(&1, ["metadata", "message_type"]) == "worker_handoff_cap"))

      assert length(cap_notices) == 1

      assert get_in(hd(cap_notices), ["metadata", "wake_targets"]) == [
               parts.router["participant_id"]
             ]
    end

    test "item 5: multi-session task.create with runs_on kind=default succeeds when group default is Salix",
         f do
      assert {:ok, created} =
               create_multi_session_task(f, %{"runs_on" => %{"kind" => "default"}})

      assert is_binary(created["conversation_id"])
    end

    test "item 6: TaskWorkerWatch retries unsubscribed busy secondary via SystemsClock without extra events",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      p_ref = {f.worker, get_in(parts.primary, ["payload", "session_id"])}
      s_ref = {f.worker, get_in(reviewer, ["payload", "session_id"])}
      router_ref = {f.router, f.router_session}

      assert {:ok, _} =
               ConversationServer.append_group_conversation_message(f.group, conv_id, %{
                 "actor_type" => "agent",
                 "agent_id" => f.worker,
                 "participant_id" => parts.primary["participant_id"],
                 "content" => "Primary finished."
               })

      now_ms = SystemsClock.system_time(:millisecond)

      # Stop the actor so the fresh TaskWorkerWatch genuinely hits subscribe failure on s_ref
      {:ok, old_owner} = ConversationPlacement.ensure_started(f.group, conv_id)
      GenServer.stop(old_owner, :normal)

      FakeSessionActivity.set_subscribe_errors([s_ref])

      FakeSessionActivity.set(%{
        p_ref => %{"state" => "stopped", "version" => "wp_r4", "updated_at" => now_ms},
        s_ref => %{"state" => "active", "version" => "ws_r4", "updated_at" => now_ms},
        router_ref => %{"state" => "stopped", "version" => "rt_r4", "updated_at" => now_ms + 1}
      })

      {:ok, owner_pid} = ConversationPlacement.ensure_started(f.group, conv_id)
      %{worker_watch_pid: watch_pid, worker_watch_capability: cap} = :sys.get_state(owner_pid)
      GenServer.cast(watch_pid, {:reconcile, owner_pid, cap, false})
      _ = :sys.get_state(watch_pid)

      # Grace expires while unsubscribed secondary is active -> schedules retry instead of stalling
      SystemsClock.advance(TaskWorkerWatch.grace_ms() + 1_000)
      _ = :sys.get_state(watch_pid)

      # Secondary recovers subscribability and becomes stopped; NO manual event sent to watch!
      FakeSessionActivity.set_subscribe_errors([])

      FakeSessionActivity.set(%{
        p_ref => %{"state" => "stopped", "version" => "wp_r4", "updated_at" => now_ms},
        s_ref => %{"state" => "stopped", "version" => "ws_r4_done", "updated_at" => now_ms + 2},
        router_ref => %{"state" => "stopped", "version" => "rt_r4", "updated_at" => now_ms + 3}
      })

      # Advancing SystemsClock alone triggers retry -> re-subscribe -> idle -> review -> task_status_pending!
      SystemsClock.advance(30_000)
      _ = :sys.get_state(watch_pid)
      SystemsClock.advance(TaskWorkerWatch.grace_ms() + 1_000)
      _ = :sys.get_state(watch_pid)

      {:ok, msgs} = Conversations.list_group_conversation_messages(f.group, conv_id, limit: 20)

      assert Enum.any?(
               msgs,
               &(get_in(&1, ["metadata", "message_type"]) == TaskWorkerWatch.status_type())
             )
    end

    test "item 7: deactivating initial primary still allows idempotent replay of original task.create",
         f do
      tc_id = "tc_deactivate_primary_replay_1"

      assert {:ok, created} = create_multi_session_task(f, %{}, %{"tool_call_id" => tc_id})
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)

      assert {:ok, _} =
               ConversationServer.deactivate_group_conversation_participant(
                 f.group,
                 conv_id,
                 parts.primary["participant_id"]
               )

      assert {:ok, replayed} = create_multi_session_task(f, %{}, %{"tool_call_id" => tc_id})
      assert replayed["conversation_id"] == conv_id
    end
  end

  describe "R5-R8 final closure regression coverage" do
    test "item 1: mid-switch owner restart + concurrent add_session rejects commit without unguarded moved(to: nil)",
         f do
      assert {:ok, single} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "Mid-Switch Owner Restart No Unguarded Leave",
                 "content" => "Work",
                 "runs_on" => %{"kind" => "salix"}
               })

      conv_id = single["conversation_id"]
      FakeTaskStations.reset_calls()
      FakeTaskStations.set_invite_result({:ok, "ember:c-orphan"})
      FakeTaskStations.set_moved_result(:ok)

      # Simulate narrow owner restart + concurrent add_session arriving during invite/5
      FakeTaskStations.set_on_invite(fn _inv ->
        :ok = SalixIM.ConversationFleet.stop(f.group, conv_id)

        assert {:ok, %{"added" => true}} =
                 call_router(f, "internal.task.add_session", %{
                   "conversation_id" => conv_id,
                   "slot" => "reviewer"
                 })
      end)

      try do
        assert {:error, {:bad_request, msg}} =
                 TaskRun.switch(
                   f.group,
                   conv_id,
                   %{"runs_on" => %{"kind" => "cloud_vm"}},
                   f.owner_user
                 )

        assert msg =~ "multi-session"
      after
        FakeTaskStations.set_on_invite(nil)
      end

      # Verify: invite -> moved(to: orphan), and NO unguarded 3rd moved(to: nil) that could tear down another station
      calls = FakeTaskStations.calls()
      assert [{:invite, _}, {:moved, %{to: %{session: "ember:c-orphan"}}}] = calls
    end

    test "item 2: re-ensuring primary on a pure single-session task never sets multi_session=true",
         f do
      assert {:ok, single} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "Pure Single Task",
                 "content" => "Single worker only",
                 "runs_on" => %{"kind" => "salix"}
               })

      conv_id = single["conversation_id"]
      parts = participants_by_role(f, conv_id)

      # Re-ensure the exact same primary worker participant
      assert {:ok, ensured} =
               ConversationServer.ensure_group_conversation_agent_participant(
                 f.group,
                 conv_id,
                 parts.primary
               )

      assert ensured["participant_id"] == parts.primary["participant_id"]

      # multi_session flag must remain nil/false!
      assert {:ok, conv} = Conversations.get_group_conversation(f.group, conv_id)
      refute conv["multi_session"] == true

      # Primary read_conversation without session_id still succeeds (single-session path, no multi-session auth error)
      assert {:ok, read_res} =
               Provider.call_api(f.worker, "internal", "internal.read_conversation", %{
                 "connect_id" => "internal",
                 "tool_context" => %{},
                 "params" => %{"conversation_id" => conv_id}
               })

      assert is_list(read_res["messages"])
    end

    test "item 3: PG :exists replay after adding a 3rd session preserves frozen wake_targets (excludes newly added session)",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      msg_attrs = %{
        "actor_type" => "agent",
        "agent_id" => f.worker,
        "participant_id" => parts.primary["participant_id"],
        "client_request_id" => "r5-replay-before-3rd-session",
        "content" => "@reviewer inspect this patch"
      }

      assert {:ok, first} =
               ConversationServer.append_group_conversation_message(f.group, conv_id, msg_attrs)

      # Also commit a zero-wake message BEFORE adding auditor (sender=primary mentioning only primary)
      silent_attrs = %{
        "actor_type" => "agent",
        "agent_id" => f.worker,
        "participant_id" => parts.primary["participant_id"],
        "client_request_id" => "r5-replay-silent-before-3rd-session",
        "content" => "self note",
        "mentions" => %{"participant_ids" => [parts.primary["participant_id"]]}
      }

      assert {:ok, silent_first} =
               ConversationServer.append_group_conversation_message(
                 f.group,
                 conv_id,
                 silent_attrs
               )

      assert silent_first["delivery_status"] == "recorded"

      # Add a 3rd session ("auditor") AFTER both messages were committed
      assert {:ok, added} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "auditor"
               })

      auditor_pid = added["participant_id"]

      # Replay @reviewer message (PG :exists) -> frozen wake_targets still targets ONLY reviewer (not auditor)
      assert {:ok, replayed} =
               ConversationServer.append_group_conversation_message(f.group, conv_id, msg_attrs)

      assert replayed["message_id"] == first["message_id"]
      assert replayed["delivery_status"] == first["delivery_status"]
      assert replayed["delivery_status"] == "queued"

      {:ok, stored} =
        Conversations.get_group_conversation_message(f.group, conv_id, replayed["message_id"])

      assert get_in(stored, ["metadata", "wake_targets"]) == [reviewer["participant_id"]]
      refute auditor_pid in get_in(stored, ["metadata", "wake_targets"])

      # Replay silent message (PG :exists) -> delivery_status stays "recorded" (proving notify_target_ids == [],
      # NOT falling back to live target_ids which would have woken auditor and returned "queued")
      assert {:ok, silent_replayed} =
               ConversationServer.append_group_conversation_message(
                 f.group,
                 conv_id,
                 silent_attrs
               )

      assert silent_replayed["message_id"] == silent_first["message_id"]
      assert silent_replayed["delivery_status"] == "recorded"
    end

    test "R6 item 2: legacy multi-session conversation missing multi_session flag still enforces read_conversation visibility filtering",
         f do
      assert {:ok, created} = create_multi_session_task(f)
      conv_id = created["conversation_id"]
      parts = participants_by_role(f, conv_id)
      [reviewer] = parts.secondaries

      # Send a primary-only private message (must NOT be visible to reviewer)
      assert {:ok, priv_msg} =
               ConversationServer.append_group_conversation_message(f.group, conv_id, %{
                 "actor_type" => "agent",
                 "agent_id" => f.router,
                 "participant_id" => parts.router["participant_id"],
                 "content" => "primary-only secret payload",
                 "mentions" => %{"participant_ids" => [parts.primary["participant_id"]]}
               })

      # Strip multi_session flag directly in PostgreSQL to simulate a legacy record
      %{rows: [[raw_meta]]} =
        SalixStore.Repo.query!(
          "SELECT metadata FROM salix_conversations WHERE group_id = $1 AND conversation_id = $2",
          [f.group, conv_id]
        )

      stripped_meta =
        raw_meta
        |> :erlang.binary_to_term()
        |> Map.delete("multi_session")
        |> :erlang.term_to_binary()

      SalixStore.Repo.query!(
        "UPDATE salix_conversations SET metadata = $1 WHERE group_id = $2 AND conversation_id = $3",
        [stripped_meta, f.group, conv_id]
      )

      assert {:ok, stripped} = Conversations.get_group_conversation(f.group, conv_id)
      refute stripped["multi_session"] == true

      # Reviewer calls read_conversation -> effective_multi_session? still triggers session auth + visibility filter!
      assert {:ok, read_res} =
               Provider.call_api(f.worker, "internal", "internal.read_conversation", %{
                 "connect_id" => "internal",
                 "tool_context" => %{"session_id" => get_in(reviewer, ["payload", "session_id"])},
                 "params" => %{"conversation_id" => conv_id}
               })

      msg_ids = Enum.map(read_res["messages"], & &1["message_id"])
      refute priv_msg["message_id"] in msg_ids
      assert read_res["current_participant_id"] == reviewer["participant_id"]
    end

    test "R7 item 1: clean invite rejection (:device_offline) clears lock so Salix switch and add_session still succeed",
         f do
      assert {:ok, single} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "Clean Invite Reject Clears Lock",
                 "content" => "Work",
                 "runs_on" => %{"kind" => "salix"}
               })

      conv_id = single["conversation_id"]
      FakeTaskStations.set_invite_result({:error, :device_offline})

      assert {:error, {:station, :device_offline}} =
               TaskRun.switch(
                 f.group,
                 conv_id,
                 %{"runs_on" => %{"kind" => "cloud_vm"}},
                 f.owner_user
               )

      # Lock was cleanly deleted: switching within Salix succeeds
      assert {:ok, salix_switched} =
               TaskRun.switch(
                 f.group,
                 conv_id,
                 %{"runs_on" => %{"kind" => "salix"}},
                 f.owner_user
               )

      refute Map.has_key?(salix_switched, "task_run_switch")

      # add_session also succeeds on this Salix task
      assert {:ok, added} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer"
               })

      assert added["slot"] == "reviewer"
    end

    test "R7/R8 item 4: legacy multi-session conversation missing flag with >100 participants (has_more=true) enforces filtering even after secondary is deactivated",
         f do
      # Create a single-session Task first, then add 105 participants BEFORE adding `reviewer`
      # so monotonic participant IDs guarantee `reviewer` lands strictly on page 2.
      assert {:ok, created} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "Paginated Legacy Multi-Session",
                 "content" => "Initial prompt",
                 "runs_on" => %{"kind" => "salix"}
               })

      conv_id = created["conversation_id"]

      for i <- 1..105 do
        uid = "usr_pad_#{String.pad_leading(Integer.to_string(i), 3, "0")}"

        assert {:ok, _} =
                 ConversationServer.ensure_group_conversation_user_participant(
                   f.group,
                   conv_id,
                   %{"user_id" => uid, "display_name" => "Pad #{i}"}
                 )
      end

      assert {:ok, %{"added" => true, "participant_id" => reviewer_pid}} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer"
               })

      assert {:ok, %{"has_more" => true, "participants" => page1_participants}} =
               Conversations.list_group_conversation_participants(f.group, conv_id, [])

      refute Enum.any?(page1_participants, &(&1["participant_id"] == reviewer_pid))

      assert {:ok, reviewer} =
               Conversations.get_group_conversation_participant(f.group, conv_id, reviewer_pid)

      parts = participants_by_role(f, conv_id)

      # Send a primary-only private message
      assert {:ok, priv_msg} =
               ConversationServer.append_group_conversation_message(f.group, conv_id, %{
                 "actor_type" => "agent",
                 "agent_id" => f.router,
                 "participant_id" => parts.router["participant_id"],
                 "content" => "private primary secret behind pagination",
                 "mentions" => %{"participant_ids" => [parts.primary["participant_id"]]}
               })

      # Strip multi_session flag in PG
      %{rows: [[raw_meta]]} =
        SalixStore.Repo.query!(
          "SELECT metadata FROM salix_conversations WHERE group_id = $1 AND conversation_id = $2",
          [f.group, conv_id]
        )

      stripped_meta =
        raw_meta
        |> :erlang.binary_to_term()
        |> Map.delete("multi_session")
        |> :erlang.term_to_binary()

      SalixStore.Repo.query!(
        "UPDATE salix_conversations SET metadata = $1 WHERE group_id = $2 AND conversation_id = $3",
        [stripped_meta, f.group, conv_id]
      )

      # Reviewer calls read_conversation -> falls back to owner task worker identities -> still filters out priv_msg!
      assert {:ok, read_res} =
               Provider.call_api(f.worker, "internal", "internal.read_conversation", %{
                 "connect_id" => "internal",
                 "tool_context" => %{"session_id" => get_in(reviewer, ["payload", "session_id"])},
                 "params" => %{"conversation_id" => conv_id}
               })

      msg_ids = Enum.map(read_res["messages"], & &1["message_id"])
      refute priv_msg["message_id"] in msg_ids
      assert read_res["current_participant_id"] == reviewer["participant_id"]

      # Now deactivate the secondary on page 2 and strip multi_session flag again ->
      # deactivated secondary STILL fails closed via has_multi_session_history == true!
      assert {:ok, _} =
               ConversationServer.deactivate_group_conversation_participant(
                 f.group,
                 conv_id,
                 reviewer["participant_id"]
               )

      SalixStore.Repo.query!(
        "UPDATE salix_conversations SET metadata = $1 WHERE group_id = $2 AND conversation_id = $3",
        [stripped_meta, f.group, conv_id]
      )

      assert {:error, deactivated_err} =
               Provider.call_api(f.worker, "internal", "internal.read_conversation", %{
                 "connect_id" => "internal",
                 "tool_context" => %{"session_id" => get_in(reviewer, ["payload", "session_id"])},
                 "params" => %{"conversation_id" => conv_id}
               })

      assert deactivated_err =~ "not an active worker"
    end

    test "R25 P0-1: Provider.Internal created?=true compensation respects activation_epoch & invite_id and never deactivates reactivated participant holding invite B",
         f do
      device_id = "dev-r25-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      defmodule R25ProviderStations do
        @behaviour SalixIM.Ports.TaskStations

        @impl true
        def invite(_task), do: {:ok, "ses_r25_lead"}

        @impl true
        def joined(_entry), do: :ok

        @impl true
        def add_session(entry) do
          # Simulate A permanently refused & deactivated in StationTasks, then SAME participant
          # reactivated and offline invite B persisted BEFORE Provider.Internal runs compensation!
          {:ok, _} =
            SalixIM.ConversationServer.deactivate_group_conversation_participant(
              entry.group_id,
              entry.conversation_id,
              entry.participant_id
            )

          {:ok, _} =
            SalixIM.ConversationServer.ensure_group_conversation_agent_participant(
              entry.group_id,
              entry.conversation_id,
              %{
                "agent_id" => entry.agent_id,
                "role_label" => "worker",
                "target_key" => entry.slot,
                "state" => "active",
                "payload" => %{"session_id" => SalixStore.Ids.new_session_id()}
              }
            )

          {:ok, _} =
            SalixStore.StationTaskSessions.append_pending_multi_start(
              entry.group_id,
              entry.conversation_id,
              entry.device_id,
              %{
                "slot" => entry.slot,
                "is_primary" => false,
                "agent_id" => entry.agent_id,
                "participant_id" => entry.participant_id,
                "invite_id" => "inv_r25_B_new",
                "start" => %{"slot" => entry.slot, "is_primary" => false, "model" => "mB"}
              }
            )

          {:error, {:station_refused, "policy denied"}}
        end

        @impl true
        def appended(_group, _conv), do: :ok
        @impl true
        def ended(_group, _conv), do: :ok
        @impl true
        def ended_turn(_group, _conv, _device, _seq), do: :ok
        @impl true
        def ended_turn(_group, _conv, _device, _session, _post_seq, _ans_seq), do: :ok
        @impl true
        def list(_tenant, _group), do: {:ok, []}
        @impl true
        def read(_tenant, _group, _device, _session, _opts), do: {:error, :not_found}
        @impl true
        def sandbox(_opts), do: {:error, :sandbox_unavailable}
      end

      prev_stations = SystemsRuntime.get_env(:salix_im, :task_stations_mod)
      SystemsRuntime.put_env(:salix_im, :task_stations_mod, R25ProviderStations)
      on_exit(fn -> SystemsRuntime.put_env(:salix_im, :task_stations_mod, prev_stations) end)

      assert {:ok, created} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "R25 Provider Compensation",
                 "content" => "Work",
                 "runs_on" => %{"kind" => "device", "device_id" => device_id}
               })

      conv_id = created["conversation_id"]

      :ok =
        SalixStore.StationTaskSessions.join(%{
          tenant_id: f.tenant,
          group_id: f.group,
          conversation_id: conv_id,
          device_id: device_id,
          session: "ses_r25_lead",
          agent_id: f.worker,
          start: %{"slot" => "lead", "is_primary" => true}
        })

      assert {:error, err} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer"
               })

      assert is_binary(err) and err =~ "policy denied"

      # B's pending invite MUST remain intact AND reviewer participant MUST remain active!
      {:ok, [lead_row]} = SalixStore.StationTaskSessions.of_task(f.group, conv_id)
      [kept_b] = lead_row.start["pending_multi_starts"]
      assert kept_b["invite_id"] == "inv_r25_B_new"

      {:ok, %{"participants" => parts}} =
        Conversations.list_group_conversation_participants(f.group, conv_id)

      rev = Enum.find(parts, &(&1["target_key"] == "reviewer"))
      assert rev["state"] == "active"
    end

    test "R26 P0-2: Provider.Internal created?=true compensation delegates verify_slot_unbound to protect sandbox workload B (same active participant, unchanged epoch)",
         f do
      defmodule R26SandboxVerifyStations do
        @behaviour SalixIM.Ports.TaskStations

        @impl true
        def invite(_task), do: {:ok, "ses_r26_lead"}
        @impl true
        def joined(_entry), do: :ok

        @impl true
        def add_session(entry) do
          # Simulate A refused by Sandbox while same active participant's B is reserved in workload
          # (activation_epoch unchanged — participant was NEVER deactivated between A and B!).
          assert is_binary(entry.invite_id) and entry.invite_id != ""
          {:error, {:station_refused, "sandbox refused A"}}
        end

        def verify_slot_unbound(_group_id, _conv_id, _device_id, "reviewer", _stale, _exp_inv) do
          {:abort, :superseded}
        end

        @impl true
        def appended(_group, _conv), do: :ok
        @impl true
        def ended(_group, _conv), do: :ok
        @impl true
        def ended_turn(_group, _conv, _device, _seq), do: :ok
        @impl true
        def ended_turn(_group, _conv, _device, _session, _post_seq, _ans_seq), do: :ok
        @impl true
        def list(_tenant, _group), do: {:ok, []}
        @impl true
        def read(_tenant, _group, _device, _session, _opts), do: {:error, :not_found}
        @impl true
        def sandbox(_opts), do: {:error, :sandbox_unavailable}
      end

      prev_stations = SystemsRuntime.get_env(:salix_im, :task_stations_mod)
      SystemsRuntime.put_env(:salix_im, :task_stations_mod, R26SandboxVerifyStations)
      on_exit(fn -> SystemsRuntime.put_env(:salix_im, :task_stations_mod, prev_stations) end)

      device_id = "dev-r26-sbx-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      assert {:ok, created} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "R26 Sandbox Compensation",
                 "content" => "Work",
                 "runs_on" => %{"kind" => "device", "device_id" => device_id}
               })

      conv_id = created["conversation_id"]

      assert {:error, err} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer"
               })

      assert is_binary(err) and err =~ "sandbox refused A"

      # Participant MUST stay active because verify_slot_unbound returned {:abort, :superseded}!
      {:ok, %{"participants" => parts}} =
        Conversations.list_group_conversation_participants(f.group, conv_id)

      rev = Enum.find(parts, &(&1["target_key"] == "reviewer"))
      assert rev["state"] == "active"
    end

    test "R29 P0-1: online multi-session create persists claim_token and claim_confirmed: false onto every created slot (both full and partial disconnect)",
         f do
      {:ok, joined_log} = Agent.start_link(fn -> [] end)
      {:ok, disconnect_sec} = Agent.start_link(fn -> false end)
      on_exit(fn -> if Process.alive?(joined_log), do: Agent.stop(joined_log) end)
      on_exit(fn -> if Process.alive?(disconnect_sec), do: Agent.stop(disconnect_sec) end)

      defmodule R29OnlineCreateStations do
        @behaviour SalixIM.Ports.TaskStations

        @impl true
        def check_multi_session(_t, _g, _r), do: :ok

        @impl true
        def invite(_task), do: {:ok, "ses_unused"}

        @impl true
        def invite_with_run(inv) do
          log_pid = Process.get(:r29_joined_log)
          disc_pid = Process.get(:r29_disconnect_sec)
          _ = log_pid

          if inv[:slot] == "reviewer" and Agent.get(disc_pid, & &1) do
            {:ok, :when_connected}
          else
            {:ok, {"ses_r29_#{inv[:slot]}", "run_r29_create"}}
          end
        end

        @impl true
        def joined(entry) do
          Agent.update(Process.get(:r29_joined_log), &[entry | &1])
          :ok
        end

        @impl true
        def appended(_group, _conv), do: :ok
        @impl true
        def ended(_group, _conv), do: :ok
        @impl true
        def ended_turn(_group, _conv, _device, _seq), do: :ok
        @impl true
        def ended_turn(_group, _conv, _device, _session, _post_seq, _ans_seq), do: :ok
        @impl true
        def list(_tenant, _group), do: {:ok, []}
        @impl true
        def read(_tenant, _group, _device, _session, _opts), do: {:error, :not_found}
        @impl true
        def sandbox(_opts), do: {:error, :sandbox_unavailable}
      end

      Process.put(:r29_joined_log, joined_log)
      Process.put(:r29_disconnect_sec, disconnect_sec)
      prev_stations = SystemsRuntime.get_env(:salix_im, :task_stations_mod)
      SystemsRuntime.put_env(:salix_im, :task_stations_mod, R29OnlineCreateStations)
      on_exit(fn -> SystemsRuntime.put_env(:salix_im, :task_stations_mod, prev_stations) end)

      dev_1 = "dev-r29-full-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      assert {:ok, _created_full} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "R29 Full Multi Create",
                 "content" => "Work together",
                 "runs_on" => %{"kind" => "device", "device_id" => dev_1},
                 "sessions" => [
                   %{"slot" => "lead", "role" => "Lead"},
                   %{"slot" => "reviewer", "role" => "Reviewer"}
                 ]
               })

      full_entries = Agent.get(joined_log, &Enum.reverse/1)
      assert length(full_entries) == 2

      Enum.each(full_entries, fn e ->
        assert is_binary(e.start["claim_token"]) and
                 String.starts_with?(e.start["claim_token"], "create:")

        assert e.start["claim_confirmed"] == false
      end)

      # Mid-create disconnect: lead succeeds, reviewer returns :when_connected -> lead MUST still carry claim_token & claim_confirmed: false!
      Agent.update(joined_log, fn _ -> [] end)
      Agent.update(disconnect_sec, fn _ -> true end)
      dev_2 = "dev-r29-part-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      assert {:ok, _created_partial} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "R29 Partial Multi Create",
                 "content" => "Work together",
                 "runs_on" => %{"kind" => "device", "device_id" => dev_2},
                 "sessions" => [
                   %{"slot" => "lead", "role" => "Lead"},
                   %{"slot" => "reviewer", "role" => "Reviewer"}
                 ]
               })

      [partial_lead] = Agent.get(joined_log, &Enum.reverse/1)

      assert is_binary(partial_lead.start["claim_token"]) and
               String.starts_with?(partial_lead.start["claim_token"], "create:")

      assert partial_lead.start["claim_confirmed"] == false
    end

    test "PR 3 R1 item 3: task.add_session with message: nil notifies group task list subscribers",
         f do
      assert {:ok, created} =
               call_router(f, "internal.task.create", %{
                 "agent_id" => f.worker,
                 "title" => "Silent add_session SSE wakeup",
                 "content" => "Initial task",
                 "runs_on" => %{"kind" => "salix"}
               })

      conv_id = created["conversation_id"]

      assert {:ok, _sub} =
               ConversationServer.subscribe_group_conversation_list(
                 f.group,
                 "agent_task",
                 self()
               )

      # Synchronous barrier against the actual ConversationGroupActor process + drain any pre-existing invalidation.
      flush_group_actor(f.group)
      drain_group_list_invalidations(f.group, conv_id)

      assert {:ok, added} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer",
                 "label" => "Reviewer (Codex)"
               })

      assert added["slot"] == "reviewer"

      settle_receive(
        {:group_conversation_list_invalidated, group_id, "agent_task", ^conv_id, version}
      )

      assert group_id == f.group
      assert is_binary(version) and version != ""

      # Idempotent retry for the same slot must not emit another spurious invalidation.
      assert {:ok, retry_added} =
               call_router(f, "internal.task.add_session", %{
                 "conversation_id" => conv_id,
                 "slot" => "reviewer",
                 "label" => "Reviewer (Codex)"
               })

      assert retry_added["participant_id"] == added["participant_id"]

      flush_group_actor(f.group)

      refute_received {:group_conversation_list_invalidated, ^group_id, "agent_task", ^conv_id, _}

      # A-P1-1: Deactivating the secondary worker emits an invalidation once, and repeated conditional
      # deactivation of an already-inactive worker does NOT bump membership_revision or emit another invalidation.
      rev_pid = added["participant_id"]

      assert {:ok, _} =
               ConversationServer.deactivate_group_conversation_participant(
                 f.group,
                 conv_id,
                 rev_pid
               )

      settle_receive(
        {:group_conversation_list_invalidated, ^group_id, "agent_task", ^conv_id, deact_version}
      )

      assert deact_version != version

      {:ok, after_deact} = Conversations.get_group_conversation(f.group, conv_id)
      rev_after_deact = after_deact["membership_revision"]

      # Repeated deactivation on already-inactive participant is a no-op (no rev bump, no invalidation).
      assert {:ok, %{"participant_id" => ^rev_pid, "state" => "inactive"}} =
               ConversationServer.deactivate_group_conversation_participant_if_payload(
                 f.group,
                 conv_id,
                 rev_pid,
                 %{}
               )

      flush_group_actor(f.group)
      refute_received {:group_conversation_list_invalidated, ^group_id, "agent_task", ^conv_id, _}

      {:ok, after_repeat} = Conversations.get_group_conversation(f.group, conv_id)
      assert after_repeat["membership_revision"] == rev_after_deact
    end
  end

  defp flush_group_actor(group_id) do
    assert [{pid, _}] =
             SystemsRuntime.Registry.lookup(
               SalixIM.ConversationRegistry,
               SalixIM.ConversationGroupActor.key(group_id)
             )

    _ = :sys.get_state(pid)
    :ok
  end

  defp drain_group_list_invalidations(group_id, conv_id) do
    receive do
      {:group_conversation_list_invalidated, ^group_id, "agent_task", ^conv_id, _} ->
        drain_group_list_invalidations(group_id, conv_id)
    after
      0 -> :ok
    end
  end
end
