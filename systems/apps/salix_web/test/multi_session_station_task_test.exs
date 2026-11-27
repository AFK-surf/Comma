defmodule SalixWeb.MultiSessionStationTaskTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  alias SalixEnv.Registry

  alias SalixIM.{
    ConversationActor,
    ConversationPlacement,
    ConversationServer,
    Conversations,
    StationTaskWatch
  }

  alias SalixStore.{Ids, StationTaskSessions}
  alias SalixWeb.{CodingSandboxes, StationTasks}

  defmodule FakeConnector do
    def start_link do
      Agent.start_link(fn -> %{requests: [], answers: %{}} end, name: __MODULE__)
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil ->
          :ok

        pid ->
          try do
            Agent.stop(pid)
          catch
            :exit, _ -> :ok
          end
      end
    end

    def on(method, fun),
      do: Agent.update(__MODULE__, &put_in(&1.answers[method], fun))

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    def request(run_id, method, params, _opts) do
      Agent.update(__MODULE__, &%{&1 | requests: [{run_id, method, params} | &1.requests]})

      case Agent.get(__MODULE__, & &1.answers[method]) do
        fun when is_function(fun, 2) -> fun.(run_id, params)
        fun when is_function(fun, 1) -> fun.(params)
        nil -> {:ok, %{}}
      end
    end
  end

  defmodule FakeConversations do
    def start_link(opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            participants: Keyword.get(opts, :participants, []),
            messages: Keyword.get(opts, :messages, []),
            on_messages_after: Keyword.get(opts, :on_messages_after),
            pending_reviews: [],
            turn_ended: []
          }
        end,
        name: __MODULE__
      )
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil ->
          :ok

        pid ->
          try do
            Agent.stop(pid)
          catch
            :exit, _ -> :ok
          end
      end
    end

    def pending_reviews, do: Agent.get(__MODULE__, &Enum.reverse(&1.pending_reviews))
    def turn_ended_calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.turn_ended))

    def participants(_group, _conv), do: {:ok, Agent.get(__MODULE__, & &1.participants)}

    def messages_after(_group, _conv, after_seq, limit) do
      {hook, msgs} =
        Agent.get(__MODULE__, fn st ->
          m =
            st.messages
            |> Enum.filter(fn m -> m["seq"] > after_seq end)
            |> Enum.take(limit)

          {st.on_messages_after, m}
        end)

      if is_function(hook, 1), do: hook.(after_seq)
      {:ok, msgs}
    end

    def append(_group, _conv, _agent, attrs) do
      seq =
        Agent.get_and_update(__MODULE__, fn st ->
          next = (st.messages |> Enum.map(& &1["seq"]) |> Enum.max(fn -> 0 end)) + 1
          msg = Map.put(attrs, "seq", next)
          {next, %{st | messages: st.messages ++ [msg]}}
        end)

      {:ok, %{"seq" => seq}}
    end

    def record_coding_pending_review(group, conv, seq) do
      Agent.update(
        __MODULE__,
        &%{&1 | pending_reviews: [{group, conv, seq} | &1.pending_reviews]}
      )

      {:ok, %{"declared_seq" => seq, "membership_revision" => 0}}
    end

    def turn_ended(group, conv, seq) do
      Agent.update(__MODULE__, &%{&1 | turn_ended: [{group, conv, seq} | &1.turn_ended]})
      {:ok, "ready_for_review"}
    end
  end

  setup do
    prev = SystemsRuntime.get_env(:salix_web, :station_tasks)
    {:ok, _} = FakeConnector.start_link()

    on_exit(fn ->
      FakeConnector.stop()
      FakeConversations.stop()

      if is_nil(prev),
        do: SystemsRuntime.delete_env(:salix_web, :station_tasks),
        else: SystemsRuntime.put_env(:salix_web, :station_tasks, prev)
    end)

    {:ok, tenant_rec} = Salix.Control.Tenants.create(%{"name" => "Multi Station Test"})

    {:ok, group_rec} =
      Salix.Control.Groups.create(%{"name" => "Multi Group"}, tenant_rec["tenant_id"])

    tenant = tenant_rec["tenant_id"]
    group = group_rec["group_id"]
    conv = Ids.new_conversation_id()
    agent = Ids.new_agent_id(group)
    device = "dev-ms-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, tenant: tenant, group: group, conv: conv, agent: agent, device: device}
  end

  defp register_device(ctx, tag, capabilities) do
    transport_id = "station-#{tag}-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^transport_id, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "connector-" <> transport_id,
          "name" => "Test Station",
          "capabilities" => capabilities
        },
        transport_id: transport_id
      )

    record["connector_run_id"]
  end

  test "capability gate returns :station_outdated before any RPC when multi_session_tasks is absent",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    register_device(ctx, "run_old", %{"tasks" => 2})

    assert {:error, :station_outdated} =
             StationTasks.check_multi_session(ctx.tenant, ctx.group, %{"device_id" => ctx.device})

    assert {:error, :station_outdated} =
             StationTasks.invite(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: ctx.conv,
               device_id: ctx.device,
               start: %{"requester" => "u1", "slot" => "reviewer"},
               slot: "reviewer",
               join: true,
               multi_session: true
             })

    assert FakeConnector.requests() == []

    # Upgrading capabilities unlocks check_multi_session and invite {join: true}
    register_device(ctx, "run_new", %{"tasks" => 2, "multi_session_tasks" => true})

    FakeConnector.on("task.invite", fn _ ->
      {:ok, %{"session" => "ses_rev_1", "slot" => "reviewer"}}
    end)

    assert :ok =
             StationTasks.check_multi_session(ctx.tenant, ctx.group, %{"device_id" => ctx.device})

    assert {:ok, "ses_rev_1"} =
             StationTasks.invite(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: ctx.conv,
               device_id: ctx.device,
               start: %{"requester" => "u1", "slot" => "reviewer"},
               slot: "reviewer",
               join: true,
               multi_session: true
             })

    assert [{_, "task.invite", %{"join" => true, "slot" => "reviewer"}}] =
             FakeConnector.requests()
  end

  test "StationTasks.ask defaults to primary slot (never Enum.min_by(sent)) and session_statuses aggregates all slots",
       ctx do
    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_lead",
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_rev",
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active"
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_qa",
            "role_label" => "worker",
            "target_key" => "qa",
            "state" => "active"
          }
        ],
        messages: []
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    register_device(ctx, "run_1", %{"tasks" => 2, "multi_session_tasks" => true})

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "participant_id" => "ptp_lead"}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_rev",
        agent_id: ctx.agent,
        start: %{"slot" => "reviewer", "is_primary" => false, "participant_id" => "ptp_rev"}
      })

    # Make lead have HIGHER sent than reviewer so Enum.min_by(&1.sent) would pick reviewer!
    :ok = StationTaskSessions.sent(ctx.group, ctx.conv, ctx.device, 10)
    # Reset only via direct query? Even simpler: join a 3rd slot with sent=0
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_qa",
        agent_id: ctx.agent,
        start: %{"slot" => "qa", "is_primary" => false, "participant_id" => "ptp_qa"}
      })

    FakeConnector.on("task.diff", fn _ -> {:ok, %{"files" => []}} end)

    # Default ask picks primary ("ses_lead"), NOT "ses_qa" (which has sent == 0)
    assert {:ok, %{"files" => []}} = StationTasks.ask(ctx.group, ctx.conv, "task.diff", %{})
    assert [{_, "task.diff", %{"session" => "ses_lead"}}] = FakeConnector.requests()

    # Explicit slot picks that slot
    assert {:ok, %{"files" => []}} =
             StationTasks.ask(ctx.group, ctx.conv, "task.diff", %{"slot" => "qa"})

    assert {_, "task.diff", %{"session" => "ses_qa"}} = List.last(FakeConnector.requests())

    # session_statuses aggregates all slots: running if any running, idle only when all idle
    FakeConnector.on("task.status", fn %{"all" => true} ->
      {:ok,
       %{
         "slots" => [
           %{
             "slot" => "lead",
             "session" => "ses_lead",
             "state" => "idle",
             "pending" => 0,
             "for_ms" => 5000,
             "dirty" => false
           },
           %{
             "slot" => "reviewer",
             "session" => "ses_rev",
             "state" => "running",
             "pending" => 1,
             "for_ms" => 1000,
             "unmerged" => true
           },
           %{
             "slot" => "qa",
             "session" => "ses_qa",
             "state" => "idle",
             "pending" => 0,
             "for_ms" => 4000
           }
         ]
       }}
    end)

    assert {:ok, status} = StationTasks.session_statuses(ctx.group, ctx.conv)
    assert status.state == :running
    assert status.pending == 1
    assert status.for_ms == 1000
    assert status.unmerged == true

    FakeConnector.on("task.status", fn %{"all" => true} ->
      {:ok,
       %{
         "slots" => [
           %{
             "slot" => "lead",
             "session" => "ses_lead",
             "state" => "idle",
             "pending" => 0,
             "for_ms" => 9000
           },
           %{
             "slot" => "reviewer",
             "session" => "ses_rev",
             "state" => "idle",
             "pending" => 0,
             "for_ms" => 3000,
             "unmerged" => true
           },
           %{
             "slot" => "qa",
             "session" => "ses_qa",
             "state" => "idle",
             "pending" => 0,
             "for_ms" => 6000
           }
         ]
       }}
    end)

    assert {:ok, idle_status} = StationTasks.session_statuses(ctx.group, ctx.conv)
    assert idle_status.state == :idle
    assert idle_status.pending == 0
    assert idle_status.for_ms == 3000
    assert idle_status.unmerged == true
  end

  test "multi-session post uses row.start participant_id, answered_through_seq, and records pending_review only for primary",
       ctx do
    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_lead",
            "role_label" => "worker",
            "target_key" => nil
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_rev",
            "role_label" => "worker",
            "target_key" => "reviewer"
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "participant_id" => "ptp_lead"}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_rev",
        agent_id: ctx.agent,
        start: %{"slot" => "reviewer", "is_primary" => false, "participant_id" => "ptp_rev"}
      })

    view = %{tenant_id: ctx.tenant, group_id: ctx.group, device_id: ctx.device}

    # Secondary declaring all_done does NOT record pending_review or call turn_ended
    assert {:ok, %{"seq" => 1}} =
             StationTasks.post(view, %{
               "task" => ctx.conv,
               "session" => "ses_rev",
               "text" => "Review done",
               "key" => "k_rev",
               "declared" => "all_done",
               "answered_through_seq" => 1
             })

    assert FakeConversations.pending_reviews() == []
    assert FakeConversations.turn_ended_calls() == []

    # Primary declaring all_done on multi-session Task does NOT call synchronous turn_ended
    # nor separate record_coding_pending_review (ConversationActor commits pending_review atomically).
    assert {:ok, %{"seq" => 2}} =
             StationTasks.post(view, %{
               "task" => ctx.conv,
               "session" => "ses_lead",
               "text" => "All done",
               "key" => "k_lead",
               "declared" => "all_done",
               "answered_through_seq" => 2
             })

    assert FakeConversations.pending_reviews() == []
    assert FakeConversations.turn_ended_calls() == []
  end

  test "CodingSandboxes.usage_part and monotonic remember/4 preserve usage across single-slot view, replacement, and partial data",
       ctx do
    {:ok, _} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        workspace: "ws_1",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead"}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "reviewer"}
          }
        ]
      })

    t0 = SystemsClock.utc_now()

    u1 = %{
      "by_slot" => %{
        "lead" => %{
          "session" => "s1",
          "usage" => %{
            "modelCalls" => 2,
            "inputTokens" => 100,
            "cachedTokens" => 10,
            "outputTokens" => 50,
            "model" => "claude-opus"
          }
        },
        "reviewer" => %{
          "session" => "s2",
          "usage" => %{
            "modelCalls" => 1,
            "inputTokens" => 80,
            "cachedTokens" => 5,
            "outputTokens" => 40,
            "model" => "gpt-6"
          }
        }
      }
    }

    assert {:ok, ^u1} =
             CodingSandboxes.usage_part(%{
               "task_usage" => u1,
               "usage" => %{"inputTokens" => 100}
             })

    :ok = CodingSandboxes.remember(ctx.tenant, ctx.conv, %{"usage" => {:ok, u1}}, t0)

    # Replace reviewer session (s2 -> s3 with smaller usage): retired s2 must be preserved so total never shrinks!
    u2 = %{
      "by_slot" => %{
        "lead" => %{
          "session" => "s1",
          "usage" => %{
            "modelCalls" => 3,
            "inputTokens" => 120,
            "cachedTokens" => 15,
            "outputTokens" => 60,
            "model" => "claude-opus"
          }
        },
        "reviewer" => %{
          "session" => "s3",
          "usage" => %{
            "modelCalls" => 1,
            "inputTokens" => 20,
            "cachedTokens" => 0,
            "outputTokens" => 10,
            "model" => "gpt-6"
          }
        }
      }
    }

    :ok =
      CodingSandboxes.remember(
        ctx.tenant,
        ctx.conv,
        %{"usage" => {:ok, u2}},
        DateTime.add(t0, 1, :second)
      )

    {:ok, w} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, ctx.conv)
    kept = w.spec["facts"]["usage"]["value"]
    # Total inputTokens = lead(120) + reviewer s3(20) + retired s2(80) = 220
    assert kept["inputTokens"] == 220
    assert kept["outputTokens"] == 110
    assert kept["modelCalls"] == 5
    assert kept["retired_sessions"]["s2"]["inputTokens"] == 80
    assert kept["models"]["claude-opus"]["inputTokens"] == 120
    assert kept["models"]["gpt-6"]["inputTokens"] == 100
    refute Map.has_key?(kept, "partial")

    # Clean nil usage on an idle slot does NOT mark partial: true
    u_idle = %{
      "by_slot" => %{
        "qa" => %{"session" => "s4", "usage" => nil}
      }
    }

    :ok =
      CodingSandboxes.remember(
        ctx.tenant,
        ctx.conv,
        %{"usage" => {:ok, u_idle}},
        DateTime.add(t0, 2, :second)
      )

    {:ok, w_idle} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, ctx.conv)
    refute Map.has_key?(w_idle.spec["facts"]["usage"]["value"], "partial")

    # Unreadable transcript on reviewer does not erase known totals and marks partial: true
    u3 = %{
      "partial" => true,
      "by_slot" => %{
        "reviewer" => %{"session" => "s3", "usage" => nil, "unreadable" => true}
      }
    }

    :ok =
      CodingSandboxes.remember(
        ctx.tenant,
        ctx.conv,
        %{"usage" => {:ok, u3}},
        DateTime.add(t0, 3, :second)
      )

    {:ok, w2} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, ctx.conv)
    kept2 = w2.spec["facts"]["usage"]["value"]
    assert kept2["inputTokens"] == 220
    assert kept2["partial"] == true
  end

  test "R1 regressions: CodingSandboxes.add_session_start on ready sandbox does not destroy healthy sandbox on refusal",
       ctx do
    {:ok, w} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        workspace: "ws_1",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead"}
          }
        ]
      })

    sbx_device = w.spec["device_id"]
    ctx_sbx = %{ctx | device: sbx_device}
    run_id = register_device(ctx_sbx, "old_sbx", %{"tasks" => 2})

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w.id, fn cur ->
        {:ok, Map.merge(cur.spec, %{"state" => "ready", "connector_run_id" => run_id})}
      end)

    assert {:error, :station_outdated} =
             CodingSandboxes.add_session_start(ctx.tenant, ctx.conv, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "start" => %{"slot" => "reviewer"}
             })

    {:ok, after_w} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, ctx.conv)
    assert after_w.spec["state"] == "ready"
    assert Enum.map(after_w.spec["starts"], & &1["slot"]) == ["lead"]
  end

  test "R1 regressions: partial-join multi_session_routing keeps deliver_to_slots and aligned roster fields",
       ctx do
    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_lead_r",
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"role_instructions" => "Lead implementer"}
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_rev_r",
            "role_label" => "worker",
            "target_key" => "reviewer",
            "label" => "Code Reviewer",
            "state" => "active",
            "payload" => %{"role_instructions" => "Audit security"}
          }
        ],
        messages: [
          %{
            "seq" => 1,
            "message_id" => "msg_for_rev",
            "actor_type" => "user",
            "user_id" => "usr_1",
            "content" => "@reviewer check this",
            "created_at" => 1000,
            "metadata" => %{"wake_targets" => ["ptp_rev_r"]}
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    register_device(ctx, "partial_join", %{"tasks" => 2, "multi_session_tasks" => true})

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_lead_only",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "participant_id" => "ptp_lead_r"}
      })

    FakeConnector.on("task.put", fn _ -> {:ok, %{"through" => 1}} end)
    :ok = StationTasks.give(ctx.group, ctx.conv, ctx.device)
    settle_until(fn -> Enum.any?(FakeConnector.requests(), &(elem(&1, 1) == "task.put")) end)

    {_, "task.put", put_params} =
      Enum.find(FakeConnector.requests(), &(elem(&1, 1) == "task.put"))

    assert [%{"deliver_to_slots" => []}] = put_params["messages"]
    rev_roster = Enum.find(put_params["roster"], &(&1["slot"] == "reviewer"))
    lead_roster = Enum.find(put_params["roster"], &(&1["slot"] == "lead"))
    assert lead_roster["primary"] == true
    assert lead_roster["role"] == "Lead implementer"
    assert rev_roster["primary"] == false
    assert rev_roster["label"] == "@reviewer"
    assert rev_roster["role"] == "Audit security"
  end

  test "R1 regressions: invite_expected_multi preserves pending_multi_starts on mid-invite disconnect and resumes on reconnect",
       ctx do
    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_lead",
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_rev",
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active"
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_qa",
            "role_label" => "worker",
            "target_key" => "qa",
            "state" => "active"
          }
        ],
        messages: []
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    register_device(ctx, "resume_vm", %{"tasks" => 2, "multi_session_tasks" => true})

    :ok =
      StationTaskSessions.expect(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        agent_id: ctx.agent,
        start: %{
          "requester" => "u1",
          "multi_starts" => [
            %{
              "slot" => "lead",
              "is_primary" => true,
              "agent_id" => ctx.agent,
              "start" => %{"slot" => "lead", "is_primary" => true, "requester" => "u1"}
            },
            %{
              "slot" => "reviewer",
              "is_primary" => false,
              "agent_id" => ctx.agent,
              "start" => %{"slot" => "reviewer", "is_primary" => false, "requester" => "u1"}
            }
          ]
        }
      })

    # First attempt: primary succeeds, secondary disconnects -> pending_multi_starts kept on primary row!
    FakeConnector.on("task.invite", fn params ->
      if params["join"] == true,
        do: {:error, :disconnected},
        else: {:ok, %{"session" => "ses_lead_vm", "slot" => "lead"}}
    end)

    :ok = StationTasks.give(ctx.group, ctx.conv, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, ctx.conv) do
        {:ok, [%{session: "ses_lead_vm", start: %{"pending_multi_starts" => [_]}}]} -> true
        _ -> false
      end
    end)

    # Reconnect: secondary invite now succeeds and pending_multi_starts is cleared!
    FakeConnector.on("task.invite", fn %{"join" => true} ->
      {:ok, %{"session" => "ses_rev_vm", "slot" => "reviewer"}}
    end)

    :ok = StationTasks.give(ctx.group, ctx.conv, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, ctx.conv) do
        {:ok, rows} ->
          sessions = rows |> Enum.map(& &1.session) |> Enum.sort()
          lead = Enum.find(rows, &(&1.session == "ses_lead_vm"))

          sessions == ["ses_lead_vm", "ses_rev_vm"] and
            is_nil(get_in(lead.start, ["pending_multi_starts"]))

        _ ->
          false
      end
    end)
  end

  test "ConversationActor pending_review CAS: trailing secondary message does not invalidate, new delegation clears, and coding_turn_ended_multi transitions to ready_for_review",
       ctx do
    # Create a real sandbox multi-session Task conversation via ConversationServer
    now = SystemsClock.system_time(:millisecond)
    router = Ids.new_agent_id(ctx.group)

    spec = %{
      "conversation" => %{
        "conversation_id" => ctx.conv,
        "group_id" => ctx.group,
        "kind" => "agent_task",
        "title" => "Multi Coding Review",
        "status" => "active",
        "task_worker_agent_id" => ctx.agent,
        "created_by_agent_id" => router,
        "runs_on" => %{
          "kind" => "sandbox",
          "device_id" => SalixStore.CodingSandboxes.device_id(ctx.conv)
        },
        "created_at" => now,
        "updated_at" => now,
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => router,
            "role_label" => "router",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "all", "statuses" => "all"},
            "joined_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now,
            "updated_at" => now
          }
        ]
      },
      "worker_agent_id" => ctx.agent
    }

    assert {:ok, _} = ConversationServer.create_task(ctx.group, ctx.conv, spec)

    assert {:ok, %{"participants" => parts}} =
             Conversations.list_group_conversation_participants(ctx.group, ctx.conv)

    lead_pid =
      Enum.find(parts, &(&1["role_label"] == "worker" and is_nil(&1["target_key"])))[
        "participant_id"
      ]

    rev_pid =
      Enum.find(parts, &(&1["role_label"] == "worker" and &1["target_key"] == "reviewer"))[
        "participant_id"
      ]

    # Primary posts message (seq 1) and records pending_review
    assert {:ok, %{"seq" => 1}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               ctx.conv,
               ctx.agent,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => ctx.agent,
                 "participant_id" => lead_pid,
                 "content" => "Implemented feature",
                 "client_request_id" => "req_1",
                 "metadata" => %{"declared" => "all_done"}
               }
             )

    assert {:ok, %{"declared_seq" => 1, "membership_revision" => 0}} =
             ConversationServer.record_coding_pending_review(ctx.group, ctx.conv, 1)

    # Trailing secondary wrap-up message addressed only to @router (wakes no worker) MUST NOT clear pending_review
    assert {:ok, %{"seq" => 2}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               ctx.conv,
               ctx.agent,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => ctx.agent,
                 "participant_id" => rev_pid,
                 "content" => "@router Wrap-up note",
                 "client_request_id" => "req_2",
                 "metadata" => %{"declared" => "all_done"}
               }
             )

    assert {:ok, conv_rec} = Conversations.get_group_conversation(ctx.group, ctx.conv)

    assert get_in(conv_rec, ["metadata", "pending_review"]) == %{
             "declared_seq" => 1,
             "membership_revision" => 0
           }

    # Stale CAS with wrong observed_tail_seq (1 instead of 2) does NOT transition
    assert {:ok, "active"} =
             ConversationServer.coding_turn_ended_multi(ctx.group, ctx.conv, 1, 1, 0)

    # Exact CAS with observed_tail_seq=2 and membership_revision=0 transitions to ready_for_review!
    assert {:ok, "ready_for_review"} =
             ConversationServer.coding_turn_ended_multi(ctx.group, ctx.conv, 1, 2, 0)

    assert {:ok, conv_review} = Conversations.get_group_conversation(ctx.group, ctx.conv)
    assert conv_review["status"] == "ready_for_review"
    assert is_nil(get_in(conv_review, ["metadata", "pending_review"]))

    # put_coding_reopen: waking the secondary worker reopens ready_for_review -> active!
    assert {:ok, %{"seq" => 3}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               ctx.conv,
               router,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => router,
                 "content" => "@reviewer please check one more thing",
                 "client_request_id" => "req_3",
                 "metadata" => %{"wake_targets" => [rev_pid]}
               }
             )

    assert {:ok, conv_reopened} = Conversations.get_group_conversation(ctx.group, ctx.conv)
    assert conv_reopened["status"] == "active"

    # Item 6 regression: sibling worker `@lead` handoff (wake_targets hits lead) MUST clear pending_review!
    assert {:ok, %{"declared_seq" => 3, "membership_revision" => 0}} =
             ConversationServer.record_coding_pending_review(ctx.group, ctx.conv, 3)

    assert {:ok, %{"seq" => 4}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               ctx.conv,
               ctx.agent,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => ctx.agent,
                 "participant_id" => rev_pid,
                 "content" => "@lead found a bug in auth.ts",
                 "client_request_id" => "req_4",
                 "metadata" => %{"wake_targets" => [lead_pid]}
               }
             )

    assert {:ok, conv_cleared} = Conversations.get_group_conversation(ctx.group, ctx.conv)
    assert is_nil(get_in(conv_cleared, ["metadata", "pending_review"]))

    # Unused aliases silenced
    _ = {ConversationActor, ConversationPlacement, StationTaskWatch}
  end

  test "R1-7: ConversationActor atomically records pending_review on primary terminal post and never resurrects it on idempotent replay",
       ctx do
    now = SystemsClock.system_time(:millisecond)
    router = Ids.new_agent_id(ctx.group)

    spec = %{
      "conversation" => %{
        "conversation_id" => ctx.conv,
        "group_id" => ctx.group,
        "kind" => "agent_task",
        "title" => "Atomic Pending Review Replay",
        "status" => "active",
        "task_worker_agent_id" => ctx.agent,
        "created_by_agent_id" => router,
        "runs_on" => %{
          "kind" => "sandbox",
          "device_id" => SalixStore.CodingSandboxes.device_id(ctx.conv)
        },
        "created_at" => now,
        "updated_at" => now,
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => router,
            "role_label" => "router",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "all", "statuses" => "all"},
            "joined_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now,
            "updated_at" => now
          }
        ]
      },
      "worker_agent_id" => ctx.agent
    }

    assert {:ok, _} = ConversationServer.create_task(ctx.group, ctx.conv, spec)

    assert {:ok, %{"participants" => parts}} =
             Conversations.list_group_conversation_participants(ctx.group, ctx.conv)

    lead_pid =
      Enum.find(parts, &(&1["role_label"] == "worker" and is_nil(&1["target_key"])))[
        "participant_id"
      ]

    primary_attrs = %{
      "kind" => "message",
      "actor_type" => "agent",
      "agent_id" => ctx.agent,
      "participant_id" => lead_pid,
      "content" => "Primary finished",
      "client_request_id" => "req_atomic_1",
      "metadata" => %{"declared" => "all_done"}
    }

    # Primary terminal post atomically writes metadata.pending_review without any separate RPC!
    assert {:ok, %{"seq" => 1, "inserted" => true}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               ctx.conv,
               ctx.agent,
               primary_attrs
             )

    assert {:ok, c1} = Conversations.get_group_conversation(ctx.group, ctx.conv)

    assert get_in(c1, ["metadata", "pending_review"]) == %{
             "declared_seq" => 1,
             "membership_revision" => 0
           }

    # New delegation clears pending_review
    assert {:ok, %{"seq" => 2}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               ctx.conv,
               router,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => router,
                 "content" => "@lead one more tweak",
                 "client_request_id" => "req_atomic_2",
                 "metadata" => %{"wake_targets" => [lead_pid]}
               }
             )

    assert {:ok, c2} = Conversations.get_group_conversation(ctx.group, ctx.conv)
    assert is_nil(get_in(c2, ["metadata", "pending_review"]))

    # Idempotent replay of the OLD terminal post MUST NOT resurrect pending_review!
    assert {:ok, %{"seq" => 1, "inserted" => false}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               ctx.conv,
               ctx.agent,
               primary_attrs
             )

    assert {:ok, c3} = Conversations.get_group_conversation(ctx.group, ctx.conv)
    assert is_nil(get_in(c3, ["metadata", "pending_review"]))
  end

  test "R1-1/9/10/13/16: strict slot fallback, legacy deliver_to_slots to lead only, session_statuses completeness, all_sessions primary obligation, out-of-order usage merge, slot echo check",
       ctx do
    # Item 13: Out-of-order usage merge (t0: A=10 -> t1: B=5 -> t0(late): A=10 => total 15, by_slot stays B!)
    {:ok, _} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        workspace: "ws_ooo",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "reviewer"}
          }
        ]
      })

    t0 = SystemsClock.utc_now()
    t1 = DateTime.add(t0, 5, :second)

    sample_a = %{
      "by_slot" => %{
        "reviewer" => %{
          "session" => "ses_A",
          "usage" => %{
            "modelCalls" => 1,
            "inputTokens" => 10,
            "cachedTokens" => 0,
            "outputTokens" => 2,
            "model" => "m1"
          }
        }
      }
    }

    sample_b = %{
      "by_slot" => %{
        "reviewer" => %{
          "session" => "ses_B",
          "usage" => %{
            "modelCalls" => 1,
            "inputTokens" => 5,
            "cachedTokens" => 0,
            "outputTokens" => 1,
            "model" => "m1"
          }
        }
      }
    }

    :ok = CodingSandboxes.remember(ctx.tenant, ctx.conv, %{"usage" => {:ok, sample_a}}, t0)
    :ok = CodingSandboxes.remember(ctx.tenant, ctx.conv, %{"usage" => {:ok, sample_b}}, t1)
    # Late arrival of t0 sample_a!
    :ok = CodingSandboxes.remember(ctx.tenant, ctx.conv, %{"usage" => {:ok, sample_a}}, t0)

    {:ok, w_ooo} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, ctx.conv)
    kept_ooo = w_ooo.spec["facts"]["usage"]["value"]
    assert kept_ooo["inputTokens"] == 15
    assert kept_ooo["by_slot"]["reviewer"]["session"] == "ses_B"

    # Item 16: ask_invite rejects missing/mismatched slot echo on multi_session/join
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    register_device(ctx, "slot_echo", %{"tasks" => 2, "multi_session_tasks" => true})

    FakeConnector.on("task.invite", fn _ -> {:ok, %{"session" => "ses_no_slot"}} end)

    assert {:error, :station_outdated} =
             StationTasks.invite(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: ctx.conv,
               device_id: ctx.device,
               start: %{"requester" => "u1", "slot" => "reviewer"},
               slot: "reviewer",
               join: true,
               multi_session: true
             })

    # Item 1 + Item 9 + Item 10:
    # - Secondary row without participant_id matches strictly by target_key (never falls back to primary)
    # - Legacy message without wake_targets routes ONLY to ["lead"]
    # - session_statuses returns :unknown if an active slot is missing
    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_lead_strict",
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_rev_strict",
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active"
          }
        ],
        messages: [
          %{
            "seq" => 1,
            "message_id" => "msg_legacy_no_wake",
            "actor_type" => "user",
            "user_id" => "usr_1",
            "content" => "Legacy message before add_session",
            "created_at" => 1000,
            "metadata" => %{}
          }
        ]
      )

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_lead_strict",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_rev_strict",
        agent_id: ctx.agent,
        start: %{"slot" => "reviewer", "is_primary" => false}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_ghost_slot",
        agent_id: ctx.agent,
        start: %{"slot" => "ghost", "is_primary" => false}
      })

    # Ghost secondary slot with no matching participant_id returns :not_taking_part (never falls back to lead!)
    view = %{tenant_id: ctx.tenant, group_id: ctx.group, device_id: ctx.device}

    assert {:error, :not_taking_part} =
             StationTasks.post(view, %{
               "task" => ctx.conv,
               "session" => "ses_ghost_slot",
               "text" => "Should fail",
               "key" => "k_ghost"
             })

    # Legacy message without wake_targets gets deliver_to_slots: ["lead"]
    FakeConnector.on("task.put", fn _ -> {:ok, %{"through" => 1}} end)
    :ok = StationTasks.give(ctx.group, ctx.conv, ctx.device)
    settle_until(fn -> Enum.any?(FakeConnector.requests(), &(elem(&1, 1) == "task.put")) end)

    {_, "task.put", legacy_put} =
      Enum.find(FakeConnector.requests(), &(elem(&1, 1) == "task.put"))

    assert [%{"deliver_to_slots" => ["lead"]}] = legacy_put["messages"]

    # session_statuses returns :unknown when an active slot ("reviewer" or "ghost") is omitted
    FakeConnector.on("task.status", fn %{"all" => true} ->
      {:ok,
       %{
         "slots" => [
           %{"slot" => "lead", "session" => "ses_lead_strict", "state" => "idle", "pending" => 0}
         ]
       }}
    end)

    assert :unknown = StationTasks.session_statuses(ctx.group, ctx.conv)

    # Item 10: StationTaskWatch.decide for wake_reason="all_sessions" obligates ONLY primary!
    watch_state = %StationTaskWatch{
      worker_agent_id: ctx.agent,
      worker_participant_id: "ptp_lead_strict",
      worker_participant_ids: ["ptp_lead_strict", "ptp_rev_strict"]
    }

    msgs_all = [
      %{
        "seq" => 1,
        "message_id" => "m_all",
        "actor_type" => "user",
        "user_id" => "usr_1",
        "content" => "@all status?",
        "created_at" => 1_700_000_000_000,
        "metadata" => %{
          "wake_reason" => "all_sessions",
          "wake_targets" => ["ptp_lead_strict", "ptp_rev_strict"]
        }
      },
      %{
        "seq" => 2,
        "message_id" => "m_rev_reply",
        "actor_type" => "agent",
        "agent_id" => ctx.agent,
        "participant_id" => "ptp_rev_strict",
        "content" => "Reviewer replying",
        "created_at" => 1_700_000_001_000,
        "metadata" => %{}
      }
    ]

    # Secondary reply alone does NOT answer an all_sessions delegation!
    assert {:unanswered, 1, _, "m_all"} = StationTaskWatch.decide(msgs_all, watch_state)

    # Once primary replies, it IS answered!
    msgs_all_answered =
      msgs_all ++
        [
          %{
            "seq" => 3,
            "message_id" => "m_lead_reply",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_lead_strict",
            "content" => "Lead replying",
            "created_at" => 1_700_000_002_000,
            "metadata" => %{"answered_through_seq" => 1}
          }
        ]

    assert {:answered, 1, _, %{"message_id" => "m_lead_reply"}} =
             StationTaskWatch.decide(msgs_all_answered, watch_state)
  end

  test "R2-1/2/5/6/8/10: declared_seq>1, answered=0, delivery_filter, Watch obligations, session_statuses & usage floor",
       ctx do
    # R2-1: pending_review.declared_seq uses message_tail_seq + 1 (works at seq > 1, not stuck at 1!)
    now = SystemsClock.system_time(:millisecond)
    router = Ids.new_agent_id(ctx.group)

    spec = %{
      "conversation" => %{
        "conversation_id" => ctx.conv,
        "group_id" => ctx.group,
        "kind" => "agent_task",
        "title" => "R2 Declared Seq > 1",
        "status" => "active",
        "task_worker_agent_id" => ctx.agent,
        "created_by_agent_id" => router,
        "runs_on" => %{
          "kind" => "sandbox",
          "device_id" => SalixStore.CodingSandboxes.device_id(ctx.conv)
        },
        "created_at" => now,
        "updated_at" => now,
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => router,
            "role_label" => "router",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "all", "statuses" => "all"},
            "joined_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now,
            "updated_at" => now
          }
        ]
      },
      "worker_agent_id" => ctx.agent
    }

    assert {:ok, _} = ConversationServer.create_task(ctx.group, ctx.conv, spec)

    assert {:ok, %{"participants" => parts}} =
             Conversations.list_group_conversation_participants(ctx.group, ctx.conv)

    lead_pid =
      Enum.find(parts, &(&1["role_label"] == "worker" and is_nil(&1["target_key"])))[
        "participant_id"
      ]

    rev_pid =
      Enum.find(parts, &(&1["role_label"] == "worker" and &1["target_key"] == "reviewer"))[
        "participant_id"
      ]

    # Send 2 messages first so primary terminal declaration lands at seq 3!
    assert {:ok, %{"seq" => 1}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               ctx.conv,
               router,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => router,
                 "content" => "Delegation 1",
                 "client_request_id" => "r2_m1",
                 "metadata" => %{"wake_targets" => [lead_pid]}
               }
             )

    assert {:ok, %{"seq" => 2}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               ctx.conv,
               ctx.agent,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => ctx.agent,
                 "participant_id" => rev_pid,
                 "content" => "Progress",
                 "client_request_id" => "r2_m2"
               }
             )

    assert {:ok, %{"seq" => 3}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               ctx.conv,
               ctx.agent,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => ctx.agent,
                 "participant_id" => lead_pid,
                 "content" => "Done at seq 3",
                 "client_request_id" => "r2_m3",
                 "metadata" => %{"declared" => "all_done"}
               }
             )

    assert {:ok, c_seq3} = Conversations.get_group_conversation(ctx.group, ctx.conv)
    assert get_in(c_seq3, ["metadata", "pending_review", "declared_seq"]) == 3

    assert {:ok, "ready_for_review"} =
             ConversationServer.coding_turn_ended_multi(ctx.group, ctx.conv, 3, 3, 0)

    # R2-8: Watch decide keeps seq 1 unanswered for reviewer even after seq 2->lead and seq 3 lead reply!
    watch_state = %StationTaskWatch{
      worker_agent_id: ctx.agent,
      worker_participant_id: lead_pid,
      worker_participant_ids: [lead_pid, rev_pid]
    }

    msgs_multi_ob = [
      %{
        "seq" => 1,
        "message_id" => "m_rev_ob",
        "actor_type" => "user",
        "user_id" => "usr_1",
        "content" => "@reviewer check",
        "created_at" => 1_700_000_000_000,
        "metadata" => %{"wake_targets" => [rev_pid]}
      },
      %{
        "seq" => 2,
        "message_id" => "m_lead_ob",
        "actor_type" => "user",
        "user_id" => "usr_1",
        "content" => "@lead check",
        "created_at" => 1_700_000_001_000,
        "metadata" => %{"wake_targets" => [lead_pid]}
      },
      %{
        "seq" => 3,
        "message_id" => "m_lead_ans",
        "actor_type" => "agent",
        "agent_id" => ctx.agent,
        "participant_id" => lead_pid,
        "content" => "Lead done",
        "created_at" => 1_700_000_002_000,
        "metadata" => %{"answered_through_seq" => 2}
      }
    ]

    assert {:unanswered, 1, _, "m_rev_ob"} = StationTaskWatch.decide(msgs_multi_ob, watch_state)

    # R2-10: Flat single-session usage (12) -> partial multi-session sample (lead unreadable, rev=2) MUST NOT shrink below 12!
    {:ok, _} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        workspace: "ws_floor",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead"}
          }
        ]
      })

    t0 = SystemsClock.utc_now()
    flat = %{"modelCalls" => 1, "inputTokens" => 12, "cachedTokens" => 0, "outputTokens" => 4}
    :ok = CodingSandboxes.remember(ctx.tenant, ctx.conv, %{"usage" => {:ok, flat}}, t0)
    # Single-session nil sample must preserve existing flat usage!
    :ok =
      CodingSandboxes.remember(
        ctx.tenant,
        ctx.conv,
        %{"usage" => {:ok, nil}},
        DateTime.add(t0, 1, :second)
      )

    {:ok, w_nil} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, ctx.conv)
    assert w_nil.spec["facts"]["usage"]["value"]["inputTokens"] == 12

    partial_multi = %{
      "partial" => true,
      "by_slot" => %{
        "lead" => %{"session" => "s_lead", "usage" => nil, "unreadable" => true},
        "reviewer" => %{
          "session" => "s_rev",
          "usage" => %{
            "modelCalls" => 1,
            "inputTokens" => 2,
            "cachedTokens" => 0,
            "outputTokens" => 1
          }
        }
      }
    }

    :ok =
      CodingSandboxes.remember(
        ctx.tenant,
        ctx.conv,
        %{"usage" => {:ok, partial_multi}},
        DateTime.add(t0, 2, :second)
      )

    {:ok, w_floor} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, ctx.conv)
    assert w_floor.spec["facts"]["usage"]["value"]["inputTokens"] == 14

    # R2-2/5/8: explicit answered_through_seq: 0, explicit delivery_filter emits visible_to_slots even for all slots,
    # and session_statuses returns :unknown on session mismatch or missing pending!
    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => lead_pid,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => rev_pid,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active"
          }
        ],
        messages: [
          %{
            "seq" => 1,
            "message_id" => "m_filtered_both",
            "actor_type" => "user",
            "user_id" => "usr_1",
            "content" => "Restricted to current 2 slots only",
            "created_at" => 1000,
            "delivery_filter" => [lead_pid, rev_pid],
            "metadata" => %{"wake_targets" => [lead_pid]}
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    run_id = register_device(ctx, "r2_checks", %{"tasks" => 2, "multi_session_tasks" => true})

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_r2_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "participant_id" => lead_pid,
          "connector_run_id" => run_id
        }
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_r2_rev",
        agent_id: ctx.agent,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "participant_id" => rev_pid,
          "connector_run_id" => run_id
        }
      })

    # R2-5: explicit delivery_filter emits visible_to_slots even when both current slots are included!
    FakeConnector.on("task.put", fn _ -> {:ok, %{"through" => 1}} end)
    :ok = StationTasks.give(ctx.group, ctx.conv, ctx.device)
    settle_until(fn -> Enum.any?(FakeConnector.requests(), &(elem(&1, 1) == "task.put")) end)

    {_, "task.put", put_r2} =
      Enum.find(FakeConnector.requests(), &(elem(&1, 1) == "task.put"))

    assert [%{"visible_to_slots" => vis_slots}] = put_r2["messages"]
    assert Enum.sort(vis_slots) == ["lead", "reviewer"]

    # R2-2: explicit answered_through_seq: 0 keeps answered == 0 even though sent == 1!
    view = %{tenant_id: ctx.tenant, group_id: ctx.group, device_id: ctx.device}

    assert {:ok, %{"seq" => 2}} =
             StationTasks.post(view, %{
               "task" => ctx.conv,
               "session" => "ses_r2_rev",
               "text" => "Done with 0 consumed",
               "key" => "k_zero",
               "declared" => "all_done",
               "answered_through_seq" => 0
             })

    {:ok, rows_zero} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    assert Enum.find(rows_zero, &(&1.session == "ses_r2_rev")).answered == 0

    # R2-8: session_statuses returns :unknown when session ID mismatches OR pending is missing!
    FakeConnector.on("task.status", fn %{"all" => true} ->
      {:ok,
       %{
         "slots" => [
           %{"slot" => "lead", "session" => "ses_r2_lead", "state" => "idle", "pending" => 0},
           %{
             "slot" => "reviewer",
             "session" => "ses_WRONG_OLD",
             "state" => "idle",
             "pending" => 0
           }
         ]
       }}
    end)

    assert :unknown = StationTasks.session_statuses(ctx.group, ctx.conv)

    FakeConnector.on("task.status", fn %{"all" => true} ->
      {:ok,
       %{
         "slots" => [
           %{"slot" => "lead", "session" => "ses_r2_lead", "state" => "idle"},
           %{"slot" => "reviewer", "session" => "ses_r2_rev", "state" => "idle", "pending" => 0}
         ]
       }}
    end)

    assert :unknown = StationTasks.session_statuses(ctx.group, ctx.conv)
  end

  test "R3-A1/A2/C1/C3: canonical delivery_filter map emits visible_to_slots even on single-slot Task, worker_obligations survives >50 messages, flat-to-multi partial usage sums 12+2=14",
       ctx do
    # R3-C3: Flat single-session 12 -> partial multi-session (lead unreadable, reviewer 2) totals 14 (not 12)!
    {:ok, _} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        workspace: "ws_r3_c3",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: []
      })

    t0 = SystemsClock.utc_now()
    t1 = DateTime.add(t0, 5, :second)

    flat_single = %{
      "modelCalls" => 2,
      "inputTokens" => 12,
      "cachedTokens" => 0,
      "outputTokens" => 4,
      "model" => "m1"
    }

    partial_multi = %{
      "partial" => true,
      "by_slot" => %{
        "lead" => %{"session" => "ses_lead_u", "usage" => nil, "unreadable" => true},
        "reviewer" => %{
          "session" => "ses_rev_u",
          "usage" => %{
            "modelCalls" => 1,
            "inputTokens" => 2,
            "cachedTokens" => 0,
            "outputTokens" => 1,
            "model" => "m2"
          }
        }
      }
    }

    :ok = CodingSandboxes.remember(ctx.tenant, ctx.conv, %{"usage" => {:ok, flat_single}}, t0)
    :ok = CodingSandboxes.remember(ctx.tenant, ctx.conv, %{"usage" => {:ok, partial_multi}}, t1)

    {:ok, w_c3} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, ctx.conv)
    kept_c3 = w_c3.spec["facts"]["usage"]["value"]
    assert kept_c3["inputTokens"] == 14
    assert kept_c3["modelCalls"] == 3
    assert kept_c3["partial"] == true

    # R3-A1/A2: Canonical persisted delivery_filter %{"participant_ids" => [lead_pid]} emits
    # visible_to_slots EVEN on a single-slot Task!
    assert SalixIM.ConversationMessage.explicit_visibility_restriction?(%{
             "delivery_filter" => %{"participant_ids" => ["ptp_lead_only"]}
           }) == true

    assert SalixIM.ConversationMessage.explicit_visibility_restriction?(%{
             "delivery_filter" => nil
           }) == false

    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_single_lead",
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          }
        ],
        messages: [
          %{
            "seq" => 1,
            "message_id" => "msg_r3_restricted_single",
            "actor_type" => "agent",
            "agent_id" => "agt_router",
            "content" => "Lead-only restricted message on 1-slot Task",
            "created_at" => 1000,
            "delivery_filter" => %{"participant_ids" => ["ptp_single_lead"]},
            "metadata" => %{}
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    run_id = register_device(ctx, "r3_a1_single", %{"tasks" => 2, "multi_session_tasks" => true})

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_r3_single_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "participant_id" => "ptp_single_lead",
          "connector_run_id" => run_id
        }
      })

    FakeConnector.on("task.put", fn _ -> {:ok, %{"through" => 1}} end)
    :ok = StationTasks.give(ctx.group, ctx.conv, ctx.device)
    settle_until(fn -> Enum.any?(FakeConnector.requests(), &(elem(&1, 1) == "task.put")) end)

    {_, "task.put", put_a2} =
      Enum.find(FakeConnector.requests(), &(elem(&1, 1) == "task.put"))

    assert [%{"visible_to_slots" => ["lead"]}] = put_a2["messages"]

    # R3-C1: Worker obligation at seq 1 survives >50 subsequent messages from another slot!
    conv_c1 = Ids.new_conversation_id()
    now = SystemsClock.system_time(:millisecond)
    router = Ids.new_agent_id(ctx.group)

    spec = %{
      "conversation" => %{
        "conversation_id" => conv_c1,
        "group_id" => ctx.group,
        "kind" => "agent_task",
        "title" => "Obligation Window Survival",
        "status" => "active",
        "task_worker_agent_id" => ctx.agent,
        "created_by_agent_id" => router,
        "runs_on" => %{
          "kind" => "sandbox",
          "device_id" => SalixStore.CodingSandboxes.device_id(conv_c1)
        },
        "created_at" => now,
        "updated_at" => now,
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => router,
            "role_label" => "router",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "all", "statuses" => "all"},
            "joined_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now,
            "updated_at" => now
          }
        ]
      },
      "worker_agent_id" => ctx.agent
    }

    assert {:ok, _} = ConversationServer.create_task(ctx.group, conv_c1, spec)

    {:ok, %{"participants" => parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_c1)

    lead_pid =
      Enum.find(parts, &(&1["role_label"] == "worker" and is_nil(&1["target_key"])))[
        "participant_id"
      ]

    rev_pid =
      Enum.find(parts, &(&1["role_label"] == "worker" and &1["target_key"] == "reviewer"))[
        "participant_id"
      ]

    # seq 1: Router delegates to reviewer
    assert {:ok, %{"seq" => 1}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               conv_c1,
               router,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => router,
                 "content" => "@reviewer please audit",
                 "client_request_id" => "req_c1_1",
                 "metadata" => %{"wake_targets" => [rev_pid]}
               }
             )

    # seq 2..55: Lead posts 54 progress messages, pushing seq 1 outside the 50-message window!
    for i <- 2..55 do
      assert {:ok, %{"seq" => ^i}} =
               ConversationServer.append_group_conversation_agent_message(
                 ctx.group,
                 conv_c1,
                 ctx.agent,
                 %{
                   "kind" => "message",
                   "actor_type" => "agent",
                   "agent_id" => ctx.agent,
                   "participant_id" => lead_pid,
                   "content" => "Lead step #{i}",
                   "client_request_id" => "req_c1_#{i}",
                   "metadata" => %{}
                 }
               )
    end

    {:ok, conv_after} = Conversations.get_group_conversation(ctx.group, conv_c1)

    assert %{^rev_pid => %{"seq" => 1, "message_id" => ob_mid}} =
             get_in(conv_after, ["metadata", "worker_obligations"])

    assert is_binary(ob_mid)

    {:ok, tail_50} = Conversations.list_group_conversation_messages(ctx.group, conv_c1, tail: 50)
    refute Enum.any?(tail_50, &(&1["seq"] == 1))

    watch = %StationTaskWatch{
      group_id: ctx.group,
      conversation_id: conv_c1,
      worker_agent_id: ctx.agent,
      worker_participant_id: lead_pid,
      worker_participant_ids: [lead_pid, rev_pid],
      worker_obligations: get_in(conv_after, ["metadata", "worker_obligations"]),
      pending: nil
    }

    assert {:unanswered, 1, _at, ^ob_mid} = StationTaskWatch.decide(tail_50, watch)
  end

  test "R4-1/2/3/7/8/9: mentions-only visibility restriction, answered_through_seq obligation clearing, joined preserves run_A, strict 1:1 session_statuses, custom captain usage merge & sandbox transient retry",
       ctx do
    # R4-1: mentions-only message triggers explicit_visibility_restriction? and emits visible_to_slots
    assert SalixIM.ConversationMessage.explicit_visibility_restriction?(%{
             "delivery_filter" => nil,
             "mentions" => %{"participant_ids" => ["ptp_m_lead"]}
           }) == true

    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_m_lead",
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          }
        ],
        messages: [
          %{
            "seq" => 1,
            "message_id" => "msg_r4_mention_only",
            "actor_type" => "agent",
            "agent_id" => "agt_router",
            "content" => "Mentions-only message",
            "created_at" => 1000,
            "delivery_filter" => nil,
            "mentions" => %{"participant_ids" => ["ptp_m_lead"]},
            "metadata" => %{}
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    run_a = register_device(ctx, "r4_run_a", %{"tasks" => 2, "multi_session_tasks" => true})

    # R4-3: joined/1 preserves run_A even after device reconnects on run_B!
    _run_b = register_device(ctx, "r4_run_b", %{"tasks" => 2, "multi_session_tasks" => true})

    :ok =
      StationTasks.joined(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.conv,
        device_id: ctx.device,
        session: "ses_r4_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "participant_id" => "ptp_m_lead",
          "connector_run_id" => run_a
        }
      })

    {:ok, [joined_row]} = StationTaskSessions.of_task(ctx.group, ctx.conv)
    assert joined_row.start["connector_run_id"] == run_a

    # Put emits visible_to_slots: ["lead"] for mentions-only message on 1-slot Task
    # (confirming `ses_r4_lead` is alive on run_b via task.status {all: true} before rebinding run_a -> run_b).
    FakeConnector.on("task.status", fn %{"all" => true} ->
      {:ok,
       %{
         "slots" => [
           %{"slot" => "lead", "session" => "ses_r4_lead", "state" => "idle", "pending" => 0}
         ]
       }}
    end)

    FakeConnector.on("task.put", fn _ -> {:ok, %{"through" => 1}} end)
    :ok = StationTasks.give(ctx.group, ctx.conv, ctx.device)
    settle_until(fn -> Enum.any?(FakeConnector.requests(), &(elem(&1, 1) == "task.put")) end)

    {_, "task.put", put_m} =
      Enum.find(FakeConnector.requests(), &(elem(&1, 1) == "task.put"))

    assert [%{"visible_to_slots" => ["lead"]}] = put_m["messages"]

    # R4-8: session_statuses rejects extra slot reported by Station (strict 1:1 equality, not subset!)
    FakeConnector.on("task.status", fn %{"all" => true} ->
      {:ok,
       %{
         "slots" => [
           %{"slot" => "lead", "session" => "ses_r4_lead", "state" => "idle", "pending" => 0},
           %{"slot" => "ghost", "session" => "ses_ghost", "state" => "idle", "pending" => 0}
         ]
       }}
    end)

    assert :unknown = StationTasks.session_statuses(ctx.group, ctx.conv)

    # R4-9: Custom primary alias "captain" flat 12 -> multi (captain/s1=12, reviewer/s2=2) totals 14 (not 26)!
    conv_cap = Ids.new_conversation_id()

    {:ok, _} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_cap,
        workspace: "ws_cap",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: []
      })

    t0 = SystemsClock.utc_now()
    t1 = DateTime.add(t0, 5, :second)

    :ok =
      CodingSandboxes.remember(
        ctx.tenant,
        conv_cap,
        %{
          "usage" =>
            {:ok,
             %{
               "modelCalls" => 2,
               "inputTokens" => 12,
               "cachedTokens" => 0,
               "outputTokens" => 3,
               "model" => "m1"
             }}
        },
        t0
      )

    :ok =
      CodingSandboxes.remember(
        ctx.tenant,
        conv_cap,
        %{
          "usage" =>
            {:ok,
             %{
               "by_slot" => %{
                 "captain" => %{
                   "session" => "ses_cap_1",
                   "is_primary" => true,
                   "usage" => %{
                     "modelCalls" => 2,
                     "inputTokens" => 12,
                     "cachedTokens" => 0,
                     "outputTokens" => 3,
                     "model" => "m1"
                   }
                 },
                 "reviewer" => %{
                   "session" => "ses_rev_2",
                   "is_primary" => false,
                   "usage" => %{
                     "modelCalls" => 1,
                     "inputTokens" => 2,
                     "cachedTokens" => 0,
                     "outputTokens" => 1,
                     "model" => "m2"
                   }
                 }
               }
             }}
        },
        t1
      )

    {:ok, w_cap} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_cap)
    assert w_cap.spec["facts"]["usage"]["value"]["inputTokens"] == 14

    # R4-2: answered_through_seq: 1 does NOT clear obligation at seq 9 in Actor or Watch!
    conv_ob = Ids.new_conversation_id()
    now = SystemsClock.system_time(:millisecond)
    router = Ids.new_agent_id(ctx.group)

    spec = %{
      "conversation" => %{
        "conversation_id" => conv_ob,
        "group_id" => ctx.group,
        "kind" => "agent_task",
        "title" => "Answered Through Seq Obligation",
        "status" => "active",
        "task_worker_agent_id" => ctx.agent,
        "created_by_agent_id" => router,
        "runs_on" => %{
          "kind" => "sandbox",
          "device_id" => SalixStore.CodingSandboxes.device_id(conv_ob)
        },
        "created_at" => now,
        "updated_at" => now,
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => router,
            "role_label" => "router",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "all", "statuses" => "all"},
            "joined_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now,
            "updated_at" => now
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now,
            "updated_at" => now
          }
        ]
      },
      "worker_agent_id" => ctx.agent
    }

    assert {:ok, _} = ConversationServer.create_task(ctx.group, conv_ob, spec)

    {:ok, %{"participants" => parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_ob)

    lead_pid =
      Enum.find(parts, &(&1["role_label"] == "worker" and is_nil(&1["target_key"])))[
        "participant_id"
      ]

    rev_pid =
      Enum.find(parts, &(&1["role_label"] == "worker" and &1["target_key"] == "reviewer"))[
        "participant_id"
      ]

    # seq 1: initial delegation to reviewer
    assert {:ok, %{"seq" => 1}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               conv_ob,
               router,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => router,
                 "content" => "@reviewer audit v1",
                 "client_request_id" => "req_ob_1",
                 "metadata" => %{"wake_targets" => [rev_pid]}
               }
             )

    # seq 2: newer delegation to reviewer
    assert {:ok, %{"seq" => 2}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               conv_ob,
               router,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => router,
                 "content" => "@reviewer also audit v2",
                 "client_request_id" => "req_ob_2",
                 "metadata" => %{"wake_targets" => [rev_pid]}
               }
             )

    # seq 3: reviewer posts reply covering only answered_through_seq: 1 (old turn)!
    assert {:ok, %{"seq" => 3}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group,
               conv_ob,
               ctx.agent,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => ctx.agent,
                 "participant_id" => rev_pid,
                 "content" => "Finished v1 only",
                 "client_request_id" => "req_ob_3",
                 "metadata" => %{"answered_through_seq" => 1}
               }
             )

    {:ok, conv_ob_after} = Conversations.get_group_conversation(ctx.group, conv_ob)

    assert %{^rev_pid => %{"seq" => 2}} =
             get_in(conv_ob_after, ["metadata", "worker_obligations"])

    {:ok, msgs_ob} = Conversations.list_group_conversation_messages(ctx.group, conv_ob, tail: 50)

    watch_ob = %StationTaskWatch{
      group_id: ctx.group,
      conversation_id: conv_ob,
      worker_agent_id: ctx.agent,
      worker_participant_id: lead_pid,
      worker_participant_ids: [lead_pid, rev_pid],
      worker_obligations: get_in(conv_ob_after, ["metadata", "worker_obligations"]),
      pending: nil
    }

    assert {:unanswered, 2, _, _} = StationTaskWatch.decide(msgs_ob, watch_ob)

    # R5-5: ConversationServer atomic station_bound prevents late compensation from deactivating bound participant!
    assert :ok = ConversationServer.mark_task_participant_bound(ctx.group, conv_ob, rev_pid)

    assert {:ok, :already_bound} =
             ConversationServer.deactivate_unbound_task_participant(ctx.group, conv_ob, rev_pid)

    {:ok, %{"participants" => parts_after_bound}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_ob)

    assert Enum.find(parts_after_bound, &(&1["participant_id"] == rev_pid))["state"] == "active"
  end

  test "R5-3: late joined with run_A after run_B connects rebinds run_A -> run_B and advances sent",
       ctx do
    conv_rebind = Ids.new_conversation_id()

    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_rb_lead",
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          }
        ],
        messages: [
          %{
            "seq" => 1,
            "message_id" => "msg_rb_1",
            "actor_type" => "user",
            "user_id" => "usr_1",
            "content" => "Hello after rebind",
            "created_at" => 1000,
            "metadata" => %{}
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    run_b_live =
      register_device(ctx, "r5_rebind_b", %{"tasks" => 2, "multi_session_tasks" => true})

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_rebind,
        device_id: ctx.device,
        session: "ses_rb_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "participant_id" => "ptp_rb_lead",
          "connector_run_id" => "run_stale_a"
        }
      })

    FakeConnector.on("task.status", fn %{"all" => true} ->
      {:ok,
       %{
         "slots" => [
           %{"slot" => "lead", "session" => "ses_rb_lead", "state" => "idle", "pending" => 0}
         ]
       }}
    end)

    FakeConnector.on("task.put", fn _ -> {:ok, %{"through" => 1}} end)
    :ok = StationTasks.give(ctx.group, conv_rebind, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_rebind) do
        {:ok, [r]} -> r.sent == 1 and r.start["connector_run_id"] == run_b_live
        _ -> false
      end
    end)

    {:ok, [rebound]} = StationTaskSessions.of_task(ctx.group, conv_rebind)
    assert rebound.sent == 1
    assert rebound.start["connector_run_id"] == run_b_live

    # R6-1: Absent stale-run secondary on run_B is NOT rebound and NOT advanced — queued into pending_multi_starts!
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_rebind,
        device_id: ctx.device,
        session: "ses_rb_absent_rev",
        agent_id: ctx.agent,
        answered: 4,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "connector_run_id" => "run_stale_a"
        }
      })

    # Make `task.invite` fail with offline/timeout so we observe the queued pending_multi_starts before recovery finishes
    FakeConnector.on("task.invite", fn _ -> {:error, :timeout} end)
    :ok = StationTasks.give(ctx.group, conv_rebind, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_rebind) do
        {:ok, [only_lead]} ->
          only_lead.session == "ses_rb_lead" and
            Enum.any?(
              only_lead.start["pending_multi_starts"] || [],
              &(&1["slot"] == "reviewer" and &1["answered"] == 4)
            )

        _ ->
          false
      end
    end)

    # R6-7: Personal station add_session persists pending_multi_starts BEFORE task.invite,
    # keeping it intact when task.invite times out!
    assert {:error, {:station_invite_unknown, :timeout}} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_rebind,
               device_id: ctx.device,
               slot: "qa",
               agent_id: ctx.agent,
               start: %{"slot" => "qa", "is_primary" => false}
             })

    {:ok, [lead_with_qa]} = StationTaskSessions.of_task(ctx.group, conv_rebind)
    assert Enum.any?(lead_with_qa.start["pending_multi_starts"] || [], &(&1["slot"] == "qa"))
  end

  test "R7-1/2/3/5/6/7: present_slots atomic split, primary-first recovery with true old_run_id, already_bound deactivation guard, no_active_primary online recovery, and non-starving per-slot backoff",
       ctx do
    run_b_live =
      register_device(ctx, "r7_run_b", %{"tasks" => 2, "multi_session_tasks" => true})

    # ── R7-1: present_slots prevents advancing absent reviewer BOTH when bound before hello(B) (run_B)
    #         AND when late-bound after hello(B) (run_A), triggering demotion + recovery! ──
    conv_p1 = Ids.new_conversation_id()

    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "participant_id" => "p_lead",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          },
          %{
            "participant_id" => "p_rev",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active"
          }
        ],
        messages: [
          %{
            "seq" => 101,
            "message_id" => "msg_r7_101",
            "actor_type" => "user",
            "user_id" => "usr_1",
            "content" => "for reviewer",
            "created_at" => 1000,
            "metadata" => %{
              "visibility" => %{"mode" => "targeted", "target_participant_ids" => ["p_rev"]}
            }
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    for {case_tag, rev_run_id} <- [{:before_hello, run_b_live}, {:after_hello, "run_old_a"}] do
      conv_case = "#{conv_p1}_#{case_tag}"

      :ok =
        StationTaskSessions.join(%{
          tenant_id: ctx.tenant,
          group_id: ctx.group,
          conversation_id: conv_case,
          device_id: ctx.device,
          session: "ses_lead_#{case_tag}",
          agent_id: ctx.agent,
          answered: 0,
          start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_b_live}
        })

      :ok =
        StationTaskSessions.join(%{
          tenant_id: ctx.tenant,
          group_id: ctx.group,
          conversation_id: conv_case,
          device_id: ctx.device,
          session: "ses_rev_#{case_tag}",
          agent_id: ctx.agent,
          answered: 5,
          start: %{"slot" => "reviewer", "is_primary" => false, "connector_run_id" => rev_run_id}
        })

      # Station B only has `lead` present; `reviewer` is absent!
      FakeConnector.on("task.put", fn _ ->
        {:ok,
         %{
           "through" => 101,
           "present_slots" => [%{"slot" => "lead", "session" => "ses_lead_#{case_tag}"}]
         }}
      end)

      # Block invite temporarily so we verify reviewer was NEVER advanced to 101 and was demoted to pending
      FakeConnector.on("task.invite", fn _ -> {:error, :timeout} end)

      :ok = StationTasks.give(ctx.group, conv_case, ctx.device)

      settle_until(fn ->
        case StationTaskSessions.of_task(ctx.group, conv_case) do
          {:ok, [lead_only]} ->
            lead_only.sent == 101 and
              Enum.any?(
                lead_only.start["pending_multi_starts"] || [],
                &(&1["slot"] == "reviewer" and &1["answered"] == 5)
              )

          _ ->
            false
        end
      end)
    end

    # ── R7-2: B has only reviewer, lead is absent (and DB has old_run_id = run_old_a) ->
    #         primary-first recovery uses true old_run_id (not run_B) and succeeds without :stale! ──
    conv_p2 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p2,
        device_id: ctx.device,
        session: "ses_p2_lead_old",
        agent_id: ctx.agent,
        answered: 3,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => "run_old_a"}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p2,
        device_id: ctx.device,
        session: "ses_p2_rev_old",
        agent_id: ctx.agent,
        answered: 2,
        start: %{"slot" => "reviewer", "is_primary" => false, "connector_run_id" => "run_old_a"}
      })

    put_count = :atomics.new(1, [])

    FakeConnector.on("task.put", fn params ->
      c = :atomics.add_get(put_count, 1, 1)

      if c == 1 do
        {:ok,
         %{
           "through" => 101,
           "present_slots" => [%{"slot" => "reviewer", "session" => "ses_p2_rev_old"}]
         }}
      else
        {:ok,
         %{
           "through" => 101,
           "present_slots" => [
             %{"slot" => "lead", "session" => "ses_p2_lead_new"},
             %{"slot" => "reviewer", "session" => "ses_p2_rev_new"}
           ],
           "committed_slots" => [
             %{"slot" => "lead", "session" => "ses_p2_lead_new"},
             %{"slot" => "reviewer", "session" => "ses_p2_rev_new"}
           ],
           "confirmed_claims" => params["confirmed_claims"] || []
         }}
      end
    end)

    FakeConnector.on("task.invite", fn params ->
      case params["slot"] do
        "lead" -> {:ok, %{"session" => "ses_p2_lead_new", "slot" => "lead"}}
        "reviewer" -> {:ok, %{"session" => "ses_p2_rev_new", "slot" => "reviewer"}}
      end
    end)

    :ok = StationTasks.give(ctx.group, conv_p2, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_p2) do
        {:ok, rows} when length(rows) == 2 ->
          Enum.any?(rows, &(&1.session == "ses_p2_lead_new" and &1.sent == 101)) and
            Enum.any?(rows, &(&1.session == "ses_p2_rev_new" and &1.sent == 101))

        _ ->
          false
      end
    end)

    # ── R7-6: Personal station online add_session seeing no_active_primary keeps pending & recovers primary! ──
    conv_p6 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p6,
        device_id: ctx.device,
        session: "ses_p6_lead_old",
        agent_id: ctx.agent,
        answered: 0,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_b_live}
      })

    p6_attempts = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      case params["slot"] do
        "qa" ->
          if :atomics.add_get(p6_attempts, 1, 1) == 1 do
            {:error, "no_active_primary: task has no active primary session"}
          else
            {:ok, %{"session" => "ses_p6_qa_new", "slot" => "qa"}}
          end

        "lead" ->
          {:ok, %{"session" => "ses_p6_lead_new", "slot" => "lead"}}
      end
    end)

    assert :ok =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_p6,
               device_id: ctx.device,
               slot: "qa",
               agent_id: ctx.agent,
               start: %{"slot" => "qa", "is_primary" => false}
             })

    {:ok, p6_rows} = StationTaskSessions.of_task(ctx.group, conv_p6)
    assert Enum.any?(p6_rows, &(&1.session == "ses_p6_lead_new"))
    assert Enum.any?(p6_rows, &(&1.session == "ses_p6_qa_new"))

    # ── R7-7: Single secondary timeout (reviewer) never starves healthy lead or subsequent qa! ──
    conv_p7 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p7,
        device_id: ctx.device,
        session: "ses_p7_lead",
        agent_id: ctx.agent,
        answered: 0,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_b_live,
          "pending_multi_starts" => [
            %{
              "slot" => "reviewer",
              "is_primary" => false,
              "agent_id" => ctx.agent,
              "start" => %{"slot" => "reviewer", "is_primary" => false}
            },
            %{
              "slot" => "qa",
              "is_primary" => false,
              "agent_id" => ctx.agent,
              "start" => %{"slot" => "qa", "is_primary" => false}
            }
          ]
        }
      })

    FakeConnector.on("task.invite", fn params ->
      case params["slot"] do
        "reviewer" -> {:error, :timeout}
        "qa" -> {:ok, %{"session" => "ses_p7_qa", "slot" => "qa"}}
      end
    end)

    FakeConnector.on("task.put", fn params ->
      {:ok,
       %{
         "through" => 101,
         "present_slots" => [
           %{"slot" => "lead", "session" => "ses_p7_lead"},
           %{"slot" => "qa", "session" => "ses_p7_qa"}
         ],
         "committed_slots" => [
           %{"slot" => "lead", "session" => "ses_p7_lead"},
           %{"slot" => "qa", "session" => "ses_p7_qa"}
         ],
         "confirmed_claims" => params["confirmed_claims"] || []
       }}
    end)

    :ok = StationTasks.give(ctx.group, conv_p7, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_p7) do
        {:ok, rows} ->
          lead_r = Enum.find(rows, &(&1.session == "ses_p7_lead"))
          qa_r = Enum.find(rows, &(&1.session == "ses_p7_qa"))
          lead_r != nil and qa_r != nil and lead_r.sent == 101 and qa_r.sent == 101

        _ ->
          false
      end
    end)

    {:ok, p7_rows} = StationTaskSessions.of_task(ctx.group, conv_p7)
    lead_p7 = Enum.find(p7_rows, &(&1.session == "ses_p7_lead"))

    rev_p7_pending =
      Enum.find(lead_p7.start["pending_multi_starts"] || [], &(&1["slot"] == "reviewer"))

    assert rev_p7_pending != nil and is_integer(rev_p7_pending["next_retry_at"])

    # ── R7-3: Background invite_secondary_list permanent refusal calls deactivate_unbound_task_participant ->
    #         when already_bound, keeps participant active, drops stale pending, sends NO false refusal notice! ──
    conv_p3 = Ids.new_conversation_id()
    now_p3 = SystemsClock.system_time(:millisecond)

    spec_p3 = %{
      "group_id" => ctx.group,
      "conversation_id" => conv_p3,
      "title" => "R7-3 bound guard",
      "creator_user_id" => "usr_owner",
      "status" => "open",
      "runs_on" => %{"kind" => "device", "device_id" => ctx.device},
      "worker_agent_id" => ctx.agent,
      "conversation" => %{
        "conversation_id" => conv_p3,
        "group_id" => ctx.group,
        "type" => "task",
        "title" => "R7-3 bound guard",
        "status" => "open",
        "created_at" => now_p3,
        "updated_at" => now_p3,
        "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => ctx.device}},
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_p3,
            "updated_at" => now_p3
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_p3,
            "updated_at" => now_p3
          }
        ]
      }
    }

    assert {:ok, _} = ConversationServer.create_task(ctx.group, conv_p3, spec_p3)

    {:ok, %{"participants" => p3_init_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p3)

    rev_p3_pid =
      Enum.find(p3_init_parts, &(&1["target_key"] == "reviewer"))["participant_id"]

    # (a) Concurrent online add_session bound a NEW session `ses_p3_rev_new`:
    assert :ok =
             ConversationServer.mark_task_participant_bound(
               ctx.group,
               conv_p3,
               rev_p3_pid,
               "ses_p3_rev_new"
             )

    # Atomic check: deactivating with stale demoted_session `"ses_p3_rev_old"` returns {:ok, :already_bound}
    # and keeps participant active!
    assert {:ok, :already_bound} =
             ConversationServer.deactivate_unbound_task_participant(
               ctx.group,
               conv_p3,
               rev_p3_pid,
               "ses_p3_rev_old"
             )

    # (b) Previously bound `ses_p3_rev_new` gets demoted into pending with `demoted_session: "ses_p3_rev_new"`,
    #     and background retry sees permanent refusal -> participant IS atomically deactivated,
    #     refusal notice IS posted, and pending IS cleared (zero active+0-binding+0-pending orphan)!
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p3,
        device_id: ctx.device,
        session: "ses_p3_lead",
        agent_id: ctx.agent,
        answered: 0,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_b_live,
          "pending_multi_starts" => [
            %{
              "slot" => "reviewer",
              "is_primary" => false,
              "agent_id" => ctx.agent,
              "demoted_session" => "ses_p3_rev_new",
              "participant_id" => rev_p3_pid,
              "start" => %{
                "slot" => "reviewer",
                "is_primary" => false,
                "participant_id" => rev_p3_pid
              }
            }
          ]
        }
      })

    # Use real Conversations impl (which calls ConversationServer.deactivate_unbound_task_participant/4)
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: StationTasks.Conversations
    )

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_web, :station_tasks,
        connector: FakeConnector,
        conversations: FakeConversations
      )
    end)

    FakeConnector.on("task.invite", fn _ -> {:error, "refused by policy"} end)

    FakeConnector.on("task.put", fn _ ->
      {:ok,
       %{"through" => 1, "present_slots" => [%{"slot" => "lead", "session" => "ses_p3_lead"}]}}
    end)

    :ok = StationTasks.give(ctx.group, conv_p3, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_p3) do
        {:ok, [r]} -> (r.start["pending_multi_starts"] || []) == []
        _ -> false
      end
    end)

    {:ok, %{"participants" => p3_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p3)

    assert Enum.find(p3_parts, &(&1["participant_id"] == rev_p3_pid))["state"] == "inactive"

    {:ok, p3_msgs} =
      Conversations.list_group_conversation_messages(ctx.group, conv_p3, after_seq: 0, limit: 20)

    assert Enum.any?(p3_msgs, &(inspect(&1["content"]) =~ "refused"))
  end

  test "R8 P0-1/P0-4/P1-4/P1-6: missing present_slots requires task.status proof, awaited primary add_session appends without RPC, SystemsClock auto-wakes backed-off secondary, and unknown vs gone semantics",
       ctx do
    run_live = register_device(ctx, "r8_live", %{"tasks" => 2, "multi_session_tasks" => true})

    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "participant_id" => "p_r8_lead",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          },
          %{
            "participant_id" => "p_r8_rev",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active"
          }
        ],
        messages: [
          %{
            "seq" => 10,
            "message_id" => "msg_r8_10",
            "actor_type" => "user",
            "user_id" => "usr_1",
            "content" => "r8 delivery",
            "created_at" => 1000,
            "metadata" => %{}
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    # ── R8 P0-1: Multi-session task.put ACK WITHOUT present_slots (even with matching run_id)
    #            must call task.status {all: true} and NEVER advance absent reviewer's sent! ──
    conv_no_ps = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_no_ps,
        device_id: ctx.device,
        session: "ses_nops_lead",
        agent_id: ctx.agent,
        answered: 0,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_live}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_no_ps,
        device_id: ctx.device,
        session: "ses_nops_rev",
        agent_id: ctx.agent,
        answered: 3,
        start: %{"slot" => "reviewer", "is_primary" => false, "connector_run_id" => run_live}
      })

    status_called = :atomics.new(1, [])

    FakeConnector.on("task.put", fn _ -> {:ok, %{"through" => 10}} end)

    FakeConnector.on("task.status", fn params ->
      assert params["all"] == true
      :atomics.add(status_called, 1, 1)

      {:ok,
       %{
         "slots" => [
           %{"slot" => "lead", "session" => "ses_nops_lead", "state" => "idle", "pending" => 0}
         ]
       }}
    end)

    FakeConnector.on("task.invite", fn _ -> {:error, :timeout} end)

    :ok = StationTasks.give(ctx.group, conv_no_ps, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_no_ps) do
        {:ok, [only_lead]} ->
          only_lead.sent == 10 and
            Enum.any?(
              only_lead.start["pending_multi_starts"] || [],
              &(&1["slot"] == "reviewer" and &1["demoted_session"] == "ses_nops_rev")
            )

        _ ->
          false
      end
    end)

    assert :atomics.get(status_called, 1) >= 1

    # ── R8 P0-4: add_session with 0 device rows returns {:error, :primary_not_ready} (0 RPCs);
    #            with ONLY awaited primary row appends pending without firing join: true RPC! ──
    conv_empty = Ids.new_conversation_id()
    rpc_count = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn _ ->
      :atomics.add(rpc_count, 1, 1)
      {:ok, %{"session" => "should_not_happen", "slot" => "qa"}}
    end)

    assert {:error, :primary_not_ready} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_empty,
               device_id: ctx.device,
               slot: "qa",
               agent_id: ctx.agent,
               start: %{"slot" => "qa", "is_primary" => false}
             })

    assert :atomics.get(rpc_count, 1) == 0

    conv_awaited = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.expect(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_awaited,
        device_id: ctx.device,
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true}
      })

    # Pause invite for lead (offline) so we inspect the awaited row directly
    FakeConnector.on("task.invite", fn params ->
      assert params["join"] != true, "must NOT send join: true while primary is still awaited!"
      {:error, :timeout}
    end)

    assert :ok =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_awaited,
               device_id: ctx.device,
               slot: "qa",
               agent_id: ctx.agent,
               start: %{"slot" => "qa", "is_primary" => false}
             })

    {:ok, [awaited_row]} = StationTaskSessions.of_task(ctx.group, conv_awaited)
    assert StationTaskSessions.awaited?(awaited_row)
    assert Enum.any?(awaited_row.start["pending_multi_starts"] || [], &(&1["slot"] == "qa"))
  end

  test "R8 P1-4/P1-6: SystemsClock auto-wakes backed-off secondary with no new message or reconnect, and unknown vs gone semantics",
       ctx do
    run_live = register_device(ctx, "r8_wake", %{"tasks" => 2, "multi_session_tasks" => true})

    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "participant_id" => "p_r8w_lead",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          },
          %{
            "participant_id" => "p_r8w_rev",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active"
          }
        ],
        messages: [
          %{
            "seq" => 10,
            "message_id" => "msg_r8w_10",
            "actor_type" => "user",
            "user_id" => "usr_1",
            "content" => "r8 wake delivery",
            "created_at" => 1000,
            "metadata" => %{}
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    # ── R8 P1-4: Deterministic SystemsClock wakeup retries backed-off secondary with NO new message / reconnect ──
    conv_wake = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_wake,
        device_id: ctx.device,
        session: "ses_wake_lead",
        agent_id: ctx.agent,
        answered: 0,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_live,
          "pending_multi_starts" => [
            %{
              "slot" => "reviewer",
              "is_primary" => false,
              "agent_id" => ctx.agent,
              "start" => %{"slot" => "reviewer", "is_primary" => false}
            }
          ]
        }
      })

    allow_rev = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        if :atomics.get(allow_rev, 1) == 0 do
          {:error, :timeout}
        else
          {:ok, %{"session" => "ses_wake_rev", "slot" => "reviewer"}}
        end
      else
        {:ok, %{"session" => "ses_wake_lead", "slot" => "lead"}}
      end
    end)

    FakeConnector.on("task.put", fn params ->
      if :atomics.get(allow_rev, 1) == 1 do
        {:ok,
         %{
           "through" => 10,
           "present_slots" => [
             %{"slot" => "lead", "session" => "ses_wake_lead"},
             %{"slot" => "reviewer", "session" => "ses_wake_rev"}
           ],
           "committed_slots" => [
             %{"slot" => "lead", "session" => "ses_wake_lead"},
             %{"slot" => "reviewer", "session" => "ses_wake_rev"}
           ],
           "confirmed_claims" => params["confirmed_claims"] || []
         }}
      else
        {:ok,
         %{
           "through" => 10,
           "present_slots" => [%{"slot" => "lead", "session" => "ses_wake_lead"}],
           "confirmed_claims" => params["confirmed_claims"] || []
         }}
      end
    end)

    :ok = StationTasks.give(ctx.group, conv_wake, ctx.device)

    # First pass: lead gets msg 10 immediately, reviewer is backed off with next_retry_at
    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_wake) do
        {:ok, [l]} ->
          l.sent == 10 and
            Enum.any?(
              l.start["pending_multi_starts"] || [],
              &(&1["slot"] == "reviewer" and is_integer(&1["next_retry_at"]))
            )

        _ ->
          false
      end
    end)

    # Unblock reviewer and advance SystemsClock with NO new message and NO reconnect ->
    # giver automatically wakes and binds reviewer!
    :atomics.put(allow_rev, 1, 1)
    SystemsClock.advance(35_000)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_wake) do
        {:ok, rows} ->
          Enum.any?(rows, &(&1.session == "ses_wake_rev" and &1.sent == 10))

        _ ->
          false
      end
    end)

    # ── R8 P1-6: Separate `unknown` (disk loss -> recovers) vs `gone` (explicit leave -> cleans up, NEVER revives) ──
    conv_unk = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_unk,
        device_id: ctx.device,
        session: "ses_unk_old",
        agent_id: ctx.agent,
        answered: 0,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => "run_older"}
      })

    unk_puts = :atomics.new(1, [])

    FakeConnector.on("task.put", fn _ ->
      if :atomics.add_get(unk_puts, 1, 1) == 1 do
        {:ok, %{"unknown" => true, "gone" => true}}
      else
        {:ok,
         %{
           "through" => 10,
           "present_slots" => [%{"slot" => "lead", "session" => "ses_unk_recovered"}]
         }}
      end
    end)

    FakeConnector.on("task.invite", fn _ ->
      {:ok, %{"session" => "ses_unk_recovered", "slot" => "lead"}}
    end)

    :ok = StationTasks.give(ctx.group, conv_unk, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_unk) do
        {:ok, [r]} -> r.session == "ses_unk_recovered" and r.sent == 10
        _ -> false
      end
    end)

    conv_gone = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_gone,
        device_id: ctx.device,
        session: "ses_gone_only",
        agent_id: ctx.agent,
        answered: 0,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_live}
      })

    gone_invites = :atomics.new(1, [])

    FakeConnector.on("task.put", fn _ -> {:ok, %{"gone" => true}} end)

    FakeConnector.on("task.invite", fn _ ->
      :atomics.add(gone_invites, 1, 1)
      {:ok, %{"session" => "should_never_revive", "slot" => "lead"}}
    end)

    :ok = StationTasks.give(ctx.group, conv_gone, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_gone) do
        {:ok, []} -> true
        _ -> false
      end
    end)

    assert :atomics.get(gone_invites, 1) == 0
  end

  test "R9 P0-1/P0-3/P1-3: legacy station blocks multi-session task.put before RPC, binding_token distinguishes same-session rebind, and public add_session timeout auto-wakes on SystemsClock",
       ctx do
    # ── R9 P0-1: Legacy station lacking multi_session_tasks sends 0 task.put RPCs on multi-session snapshot ──
    run_legacy = register_device(ctx, "r9_legacy", %{"tasks" => 2})

    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "participant_id" => "p_r9_lead",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          },
          %{
            "participant_id" => "p_r9_rev",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active"
          }
        ],
        messages: [
          %{
            "seq" => 10,
            "message_id" => "msg_r9_10",
            "actor_type" => "user",
            "user_id" => "usr_1",
            "content" => "r9 secret targeted",
            "created_at" => 1000,
            "metadata" => %{}
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    conv_leg = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_leg,
        device_id: ctx.device,
        session: "ses_leg_lead",
        agent_id: ctx.agent,
        answered: 0,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_legacy}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_leg,
        device_id: ctx.device,
        session: "ses_leg_rev",
        agent_id: ctx.agent,
        answered: 0,
        start: %{"slot" => "reviewer", "is_primary" => false, "connector_run_id" => run_legacy}
      })

    put_rpcs = :atomics.new(1, [])

    FakeConnector.on("task.put", fn _ ->
      :atomics.add(put_rpcs, 1, 1)
      {:ok, %{"through" => 10}}
    end)

    :ok = StationTasks.give(ctx.group, conv_leg, ctx.device)
    SystemsClock.advance(500)

    assert :atomics.get(put_rpcs, 1) == 0
    {:ok, leg_rows} = StationTaskSessions.of_task(ctx.group, conv_leg)
    assert length(leg_rows) == 2
    assert Enum.all?(leg_rows, &(&1.sent == 0))

    # ── R9 P0-3: Same disk `session` rebound with new `binding_token` is NOT deactivated by stale token ──
    conv_tok = Ids.new_conversation_id()
    now_tok = SystemsClock.system_time(:millisecond)

    spec_tok = %{
      "group_id" => ctx.group,
      "conversation_id" => conv_tok,
      "title" => "R9 binding_token",
      "creator_user_id" => "usr_owner",
      "status" => "open",
      "runs_on" => %{"kind" => "device", "device_id" => ctx.device},
      "worker_agent_id" => ctx.agent,
      "conversation" => %{
        "conversation_id" => conv_tok,
        "group_id" => ctx.group,
        "type" => "task",
        "title" => "R9 binding_token",
        "status" => "open",
        "created_at" => now_tok,
        "updated_at" => now_tok,
        "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => ctx.device}},
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_tok,
            "updated_at" => now_tok
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_tok,
            "updated_at" => now_tok
          }
        ]
      }
    }

    assert {:ok, _} = ConversationServer.create_task(ctx.group, conv_tok, spec_tok)

    {:ok, %{"participants" => tok_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_tok)

    rev_pid = Enum.find(tok_parts, &(&1["target_key"] == "reviewer"))["participant_id"]

    assert :ok =
             StationTasks.register_slot_binding(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_tok,
               device_id: ctx.device,
               session: "ses_same_disk_id",
               agent_id: ctx.agent,
               participant_id: rev_pid,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "connector_run_id" => "run_1"
               },
               give: false
             })

    {:ok, [first_row]} = StationTaskSessions.of_task(ctx.group, conv_tok)
    old_token = first_row.start["binding_token"]
    assert is_binary(old_token) and old_token != ""

    # Demote/remove old binding, then rebind the EXACT SAME session string `"ses_same_disk_id"`
    # on a newer generation -> fresh row gets a new binding_token!
    :ok = StationTaskSessions.leave(ctx.group, conv_tok, ctx.device)

    assert :ok =
             StationTasks.register_slot_binding(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_tok,
               device_id: ctx.device,
               session: "ses_same_disk_id",
               agent_id: ctx.agent,
               participant_id: rev_pid,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "connector_run_id" => "run_2"
               },
               give: false
             })

    # Stale refusal with old_token MUST return {:ok, :already_bound} and keep participant active!
    assert {:ok, :already_bound} =
             ConversationServer.deactivate_unbound_task_participant(
               ctx.group,
               conv_tok,
               rev_pid,
               old_token
             )

    # ── R9 P1-3: Quiet personal station public add_session timeout auto-wakes on SystemsClock ──
    run_ms = register_device(ctx, "r9_ms_add", %{"tasks" => 2, "multi_session_tasks" => true})
    conv_add = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_add,
        device_id: ctx.device,
        session: "ses_add_lead",
        agent_id: ctx.agent,
        answered: 10,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_ms}
      })

    # Mark lead already caught up to msg 10 (quiet task, no new messages)
    :ok = StationTaskSessions.sent(ctx.group, conv_add, ctx.device, 10)

    qa_allow = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "qa" do
        if :atomics.get(qa_allow, 1) == 0 do
          {:error, :timeout}
        else
          {:ok, %{"session" => "ses_add_qa_live", "slot" => "qa"}}
        end
      else
        {:ok, %{"session" => "ses_add_lead", "slot" => "lead"}}
      end
    end)

    FakeConnector.on("task.put", fn _ ->
      {:ok,
       %{
         "through" => 10,
         "present_slots" => [
           %{"slot" => "lead", "session" => "ses_add_lead"},
           %{"slot" => "qa", "session" => "ses_add_qa_live"}
         ]
       }}
    end)

    assert {:error, {:station_invite_unknown, :timeout}} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_add,
               device_id: ctx.device,
               slot: "qa",
               agent_id: ctx.agent,
               start: %{"slot" => "qa", "is_primary" => false}
             })

    # Unblock qa and advance SystemsClock with NO new message and NO reconnect -> auto-wakes & binds qa!
    :atomics.put(qa_allow, 1, 1)
    SystemsClock.advance(35_000)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_add) do
        {:ok, rows} -> Enum.any?(rows, &(&1.session == "ses_add_qa_live"))
        _ -> false
      end
    end)
  end

  test "R10 P0-1/P0-2/P0-3/P1-3: atomic do_put caps gate, register_slot_binding token alignment, awaited refusal safety, and add_session no_active_primary retry",
       ctx do
    # ── R10 P0-1: Legacy station without multi_session_tasks receives multi-session payload ->
    # do_put skips task.put AND never claims connector_run_id! ──
    run_leg = register_device(ctx, "r10_leg_payload", %{"tasks" => 2})

    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "participant_id" => "p_r10_lead",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          },
          %{
            "participant_id" => "p_r10_rev",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active"
          }
        ],
        messages: [
          %{
            "seq" => 1,
            "message_id" => "msg_r10_1",
            "actor_type" => "user",
            "user_id" => "usr_1",
            "content" => "hello @reviewer",
            "created_at" => 1000,
            "metadata" => %{"deliver_to_slots" => ["reviewer"]}
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    conv_leg = Ids.new_conversation_id()

    # Join only the primary row with empty connector_run_id (offline join)
    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_leg,
        device_id: ctx.device,
        session: "ses_r10_leg",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true}
      })

    put_calls = :atomics.new(1, [])

    FakeConnector.on("task.put", fn _ ->
      :atomics.add(put_calls, 1, 1)
      {:ok, %{"through" => 1}}
    end)

    :ok = StationTasks.give(ctx.group, conv_leg, ctx.device)
    SystemsClock.advance(500)
    assert :atomics.get(put_calls, 1) == 0

    {:ok, [leg_row]} = StationTaskSessions.of_task(ctx.group, conv_leg)
    assert (leg_row.start || %{})["connector_run_id"] in [nil, ""]
    assert run_leg != ""

    # ── R10 P0-2: Concurrent duplicate register_slot_binding aligns actor bound_token to DB token ──
    conv_dup = Ids.new_conversation_id()
    now_dup = SystemsClock.system_time(:millisecond)

    spec_dup = %{
      "group_id" => ctx.group,
      "conversation_id" => conv_dup,
      "title" => "R10 duplicate register_slot_binding",
      "creator_user_id" => "usr_owner",
      "status" => "open",
      "runs_on" => %{"kind" => "device", "device_id" => ctx.device},
      "worker_agent_id" => ctx.agent,
      "conversation" => %{
        "conversation_id" => conv_dup,
        "group_id" => ctx.group,
        "type" => "task",
        "title" => "R10 duplicate register_slot_binding",
        "status" => "open",
        "created_at" => now_dup,
        "updated_at" => now_dup,
        "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => ctx.device}},
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_dup,
            "updated_at" => now_dup
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_dup,
            "updated_at" => now_dup
          }
        ]
      }
    }

    assert {:ok, _} = ConversationServer.create_task(ctx.group, conv_dup, spec_dup)

    {:ok, %{"participants" => dup_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_dup)

    rev_pid = Enum.find(dup_parts, &(&1["target_key"] == "reviewer"))["participant_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_dup,
        device_id: ctx.device,
        session: "ses_r10_dup_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => "run_dup"}
      })

    dup_entry = %{
      tenant_id: ctx.tenant,
      group_id: ctx.group,
      conversation_id: conv_dup,
      device_id: ctx.device,
      session: "ses_r10_dup_rev",
      agent_id: ctx.agent,
      participant_id: rev_pid,
      give: false,
      start: %{
        "slot" => "reviewer",
        "is_primary" => false,
        "participant_id" => rev_pid,
        "connector_run_id" => "run_dup"
      }
    }

    assert :ok = StationTasks.register_slot_binding(dup_entry)
    assert :ok = StationTasks.register_slot_binding(dup_entry)

    {:ok, dup_rows} = StationTaskSessions.of_task(ctx.group, conv_dup)
    rev_db_row = Enum.find(dup_rows, &(&1.session == "ses_r10_dup_rev"))
    db_token = rev_db_row.start["binding_token"]
    assert is_binary(db_token) and db_token != ""

    # Demote reviewer and verify deactivation succeeds with the DB-authoritative token (not :already_bound)
    assert :ok =
             StationTaskSessions.demote_missing_secondaries(
               ctx.group,
               conv_dup,
               ctx.device,
               [rev_db_row],
               "run_dup"
             )

    {:ok, [lead_dup_after]} = StationTaskSessions.of_task(ctx.group, conv_dup)

    pending_dup =
      Enum.find(lead_dup_after.start["pending_multi_starts"], &(&1["slot"] == "reviewer"))

    assert pending_dup["demoted_binding_token"] == db_token

    assert {:ok, %{"state" => state}} =
             ConversationServer.deactivate_unbound_task_participant(
               ctx.group,
               conv_dup,
               rev_pid,
               pending_dup["demoted_binding_token"]
             )

    assert state != "active"

    # ── R10 P1-3: add_session hits no_active_primary and primary recovery times out ->
    # returns error, persists next_retry_at, and SystemsClock auto-wakes and binds! ──
    run_ms =
      register_device(ctx, "r10_no_primary", %{"tasks" => 2, "multi_session_tasks" => true})

    conv_np = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_np,
        device_id: ctx.device,
        session: "ses_np_lead_old",
        agent_id: ctx.agent,
        answered: 5,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_ms}
      })

    :ok = StationTaskSessions.sent(ctx.group, conv_np, ctx.device, 5)

    allow_recover = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      cond do
        params["join"] == true and :atomics.get(allow_recover, 1) == 0 ->
          {:error, "no_active_primary: cannot join"}

        params["join"] != true and :atomics.get(allow_recover, 1) == 0 ->
          {:error, :timeout}

        params["join"] != true ->
          {:ok, %{"session" => "ses_np_lead_new", "slot" => "lead"}}

        true ->
          {:ok, %{"session" => "ses_np_qa_new", "slot" => "qa"}}
      end
    end)

    FakeConnector.on("task.put", fn params ->
      {:ok,
       %{
         "through" => 5,
         "present_slots" => [
           %{"slot" => "lead", "session" => "ses_np_lead_new"},
           %{"slot" => "qa", "session" => "ses_np_qa_new"}
         ],
         "committed_slots" => [
           %{"slot" => "lead", "session" => "ses_np_lead_new"},
           %{"slot" => "qa", "session" => "ses_np_qa_new"}
         ],
         "confirmed_claims" => params["confirmed_claims"] || []
       }}
    end)

    assert {:error, _} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_np,
               device_id: ctx.device,
               slot: "qa",
               agent_id: ctx.agent,
               start: %{"slot" => "qa", "is_primary" => false}
             })

    {:ok, [np_lead]} = StationTaskSessions.of_task(ctx.group, conv_np)
    [np_pending] = np_lead.start["pending_multi_starts"]
    assert np_pending["slot"] == "qa"
    assert is_integer(np_pending["next_retry_at"])

    # Unblock primary + secondary recovery and advance SystemsClock -> auto-wakes & binds!
    :atomics.put(allow_recover, 1, 1)
    SystemsClock.advance(35_000)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_np) do
        {:ok, rows} ->
          Enum.any?(rows, &(&1.session == "ses_np_lead_new")) and
            Enum.any?(rows, &(&1.session == "ses_np_qa_new"))

        _ ->
          false
      end
    end)

    # ── R10 P1-2: Sandbox reconcile_invites preserves concurrently added pending_secondaries
    # (e.g. slot `qa` with request_ids) when another slot (`reviewer`) finishes succeeding! ──
    conv_sbx = Ids.new_conversation_id()

    {:ok, w} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_sbx,
        workspace: "ws_r10",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "reviewer", "is_primary" => false}
          }
        ]
      })

    sbx_device = w.spec["device_id"]
    sbx_transport = SalixStore.CodingSandboxes.transport_id(conv_sbx)

    {:ok, ^sbx_transport, sbx_rec} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => sbx_device,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_sbx),
          "workload_id" => w.id,
          "workload_generation" => w.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: sbx_transport
      )

    run_sbx = sbx_rec["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_sbx,
        device_id: sbx_device,
        session: "ses_sbx_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_sbx}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_sbx,
           "pending_secondaries" => %{
             "by_slot" => %{
               "reviewer" => %{
                 "attempts" => 1,
                 "next_retry_at_ms" => SystemsClock.system_time(:millisecond) - 1_000,
                 "request_ids" => ["req_rev_1"]
               }
             }
           }
         })}
      end)

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        # Concurrently inject `qa` into `pending_secondaries.by_slot` during `reviewer` RPC
        {:ok, _} =
          SalixStore.CodingSandboxes.update(w.id, fn cur ->
            by_slot = get_in(cur.spec, ["pending_secondaries", "by_slot"]) || %{}

            next_by_slot =
              Map.put(by_slot, "qa", %{
                "attempts" => 0,
                "next_retry_at_ms" => SystemsClock.system_time(:millisecond) + 10_000,
                "request_ids" => ["req_qa_1"]
              })

            {:ok, Map.put(cur.spec, "pending_secondaries", %{"by_slot" => next_by_slot})}
          end)

        {:ok, %{"session" => "ses_sbx_rev", "slot" => "reviewer"}}
      else
        {:ok, %{"session" => "ses_sbx_lead", "slot" => "lead"}}
      end
    end)

    CodingSandboxes.connected(%{
      tenant_id: ctx.tenant,
      group_id: ctx.group,
      device_id: sbx_device,
      connector_run_id: run_sbx,
      workload_id: w.id,
      workload_generation: w.generation
    })

    {:ok, after_w} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_sbx)
    by_slot_after = get_in(after_w.spec, ["pending_secondaries", "by_slot"]) || %{}
    refute Map.has_key?(by_slot_after, "reviewer")
    assert by_slot_after["qa"]["request_ids"] == ["req_qa_1"]
  end

  test "R11 regressions: routing.multi? gate, CAS token reconciliation, no_active_primary, outdated awaited, reconcile_pending",
       ctx do
    # ── R11 P0-1a (Opus R11): Legacy station without multi_session_tasks + single-session Task +
    # app_event message (`delivery_filter: []`) MUST send task.put and advance `sent`! ──
    run_leg_single = register_device(ctx, "r11_leg_single", %{"tasks" => 2})

    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "participant_id" => "p_r11_single",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          }
        ],
        messages: [
          %{
            "seq" => 7,
            "message_id" => "msg_r11_app_ev",
            "actor_type" => "system",
            "content" => "provider status update",
            "created_at" => 1000,
            "metadata" => %{"kind" => "app_event", "delivery_filter" => []}
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    conv_single = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_single,
        device_id: ctx.device,
        session: "ses_r11_single",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_leg_single}
      })

    single_puts = :atomics.new(1, [])

    FakeConnector.on("task.put", fn _ ->
      :atomics.add(single_puts, 1, 1)
      {:ok, %{"through" => 7}}
    end)

    :ok = StationTasks.give(ctx.group, conv_single, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_single) do
        {:ok, [r]} -> r.sent == 7
        _ -> false
      end
    end)

    assert :atomics.get(single_puts, 1) >= 1

    # ── R11 P0-1b (Astra R11 P0-2): Multi-session-capable station + 2-slot authoritative roster +
    # DB has only 1 primary row (no pending) + task.put returns `{through: 12}` WITHOUT `present_slots` ->
    # MUST call `task.status {all: true}` before settling `sent = 12`! ──
    run_ms_proof =
      register_device(ctx, "r11_ms_proof", %{"tasks" => 2, "multi_session_tasks" => true})

    Agent.update(FakeConversations, fn st ->
      %{
        st
        | participants: [
            %{
              "participant_id" => "p_r11_lead",
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => nil,
              "state" => "active"
            },
            %{
              "participant_id" => "p_r11_qa",
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => "qa",
              "state" => "active"
            }
          ],
          messages: [
            %{
              "seq" => 12,
              "message_id" => "msg_r11_12",
              "actor_type" => "user",
              "user_id" => "usr_1",
              "content" => "hello team",
              "created_at" => 2000,
              "metadata" => %{}
            }
          ]
      }
    end)

    conv_proof = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_proof,
        device_id: ctx.device,
        session: "ses_r11_proof_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_ms_proof}
      })

    status_all_calls = :atomics.new(1, [])

    FakeConnector.on("task.put", fn _ ->
      # Deliberately omit `present_slots`
      {:ok, %{"through" => 12}}
    end)

    FakeConnector.on("task.status", fn params ->
      if params["all"] == true do
        :atomics.add(status_all_calls, 1, 1)
      end

      {:ok, %{"slots" => [%{"slot" => "lead", "session" => "ses_r11_proof_lead"}]}}
    end)

    :ok = StationTasks.give(ctx.group, conv_proof, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_proof) do
        {:ok, [r]} -> r.sent == 12
        _ -> false
      end
    end)

    assert :atomics.get(status_all_calls, 1) >= 1

    # ── R11 P0-2 (Astra R11 P0-1): Conditional CAS reconcile_task_participant_bound_token
    # refuses stale overwrite when newer registration B superseded actor token! ──
    conv_cas = Ids.new_conversation_id()
    now_cas = SystemsClock.system_time(:millisecond)

    spec_cas = %{
      "group_id" => ctx.group,
      "conversation_id" => conv_cas,
      "title" => "R11 CAS token",
      "creator_user_id" => "usr_owner",
      "status" => "open",
      "runs_on" => %{"kind" => "device", "device_id" => ctx.device},
      "worker_agent_id" => ctx.agent,
      "conversation" => %{
        "conversation_id" => conv_cas,
        "group_id" => ctx.group,
        "type" => "task",
        "title" => "R11 CAS token",
        "status" => "open",
        "created_at" => now_cas,
        "updated_at" => now_cas,
        "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => ctx.device}},
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_cas,
            "updated_at" => now_cas
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_cas,
            "updated_at" => now_cas
          }
        ]
      }
    }

    assert {:ok, _} = ConversationServer.create_task(ctx.group, conv_cas, spec_cas)

    {:ok, %{"participants" => cas_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_cas)

    cas_rev_pid = Enum.find(cas_parts, &(&1["target_key"] == "reviewer"))["participant_id"]

    # Step 1: registration A sets candidate_A; then newer registration B supersedes to tok_B
    assert :ok =
             ConversationServer.mark_task_participant_bound(
               ctx.group,
               conv_cas,
               cas_rev_pid,
               "cand_A"
             )

    assert :ok =
             ConversationServer.mark_task_participant_bound(
               ctx.group,
               conv_cas,
               cas_rev_pid,
               "tok_B"
             )

    # Step 2: delayed reconciliation from A (expecting cand_A -> committed_A) MUST return {:error, :stale}!
    assert {:error, :stale} =
             ConversationServer.reconcile_task_participant_bound_token(
               ctx.group,
               conv_cas,
               cas_rev_pid,
               "cand_A",
               "committed_A"
             )

    # Step 3: stale deactivation with committed_A MUST return {:ok, :already_bound} and keep participant active!
    assert {:ok, :already_bound} =
             ConversationServer.deactivate_unbound_task_participant(
               ctx.group,
               conv_cas,
               cas_rev_pid,
               "committed_A"
             )

    # ── R11 P1-4: Consecutive no_active_primary normalizes to {:error, :needs_primary_recovery}
    # without CaseClauseError, persists next_retry_at, and recovers on SystemsClock! ──
    conv_np2 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_np2,
        device_id: ctx.device,
        session: "ses_np2_lead_old",
        agent_id: ctx.agent,
        answered: 5,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_ms_proof}
      })

    :ok = StationTaskSessions.sent(ctx.group, conv_np2, ctx.device, 5)

    np2_allow = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      cond do
        params["join"] != true ->
          {:ok, %{"session" => "ses_np2_lead_new", "slot" => "lead"}}

        :atomics.get(np2_allow, 1) == 0 ->
          # Both initial add_session AND primary recovery's secondary invite hit no_active_primary!
          {:error, "no_active_primary: cannot join"}

        true ->
          {:ok, %{"session" => "ses_np2_qa_new", "slot" => "qa"}}
      end
    end)

    FakeConnector.on("task.put", fn _ ->
      {:ok,
       %{
         "through" => 5,
         "present_slots" => [
           %{"slot" => "lead", "session" => "ses_np2_lead_new"},
           %{"slot" => "qa", "session" => "ses_np2_qa_new"}
         ]
       }}
    end)

    assert {:error, :needs_primary_recovery} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_np2,
               device_id: ctx.device,
               slot: "qa",
               agent_id: ctx.agent,
               start: %{"slot" => "qa", "is_primary" => false}
             })

    {:ok, [np2_lead]} = StationTaskSessions.of_task(ctx.group, conv_np2)
    [np2_pending] = np2_lead.start["pending_multi_starts"]
    assert np2_pending["slot"] == "qa"
    assert is_integer(np2_pending["next_retry_at"])

    :atomics.put(np2_allow, 1, 1)
    SystemsClock.advance(35_000)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_np2) do
        {:ok, rows} -> Enum.any?(rows, &(&1.session == "ses_np2_qa_new"))
        _ -> false
      end
    end)

    # ── R11 P1-5: invite_expected_multi pre-check :station_outdated calls leave_awaited/3 ──
    _run_outdated = register_device(ctx, "r11_outdated_aw", %{"tasks" => 2})
    conv_aw_out = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.expect(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_aw_out,
        device_id: ctx.device,
        agent_id: ctx.agent,
        start: %{
          "multi_starts" => [
            %{
              "slot" => "lead",
              "is_primary" => true,
              "agent_id" => ctx.agent,
              "start" => %{"slot" => "lead", "is_primary" => true}
            },
            %{
              "slot" => "qa",
              "is_primary" => false,
              "agent_id" => ctx.agent,
              "start" => %{"slot" => "qa", "is_primary" => false}
            }
          ]
        }
      })

    :ok = StationTasks.give(ctx.group, conv_aw_out, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_aw_out) do
        {:ok, []} -> true
        _ -> false
      end
    end)

    # ── R11 P1-3: Ready sandbox reconcile_invites preserves `reconcile_pending: true` when
    # `of_task` / whole-roster check fails (failed_slot == nil) and clears it once reconciliation succeeds! ──
    conv_rp = Ids.new_conversation_id()

    {:ok, w_rp} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_rp,
        workspace: "ws_r11_rp",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "qa",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "qa", "is_primary" => false}
          }
        ]
      })

    rp_device = w_rp.spec["device_id"]
    rp_transport = SalixStore.CodingSandboxes.transport_id(conv_rp)

    {:ok, ^rp_transport, rp_rec} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => rp_device,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_rp),
          "workload_id" => w_rp.id,
          "workload_generation" => w_rp.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: rp_transport
      )

    run_rp = rp_rec["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_rp,
        device_id: rp_device,
        session: "ses_rp_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_rp}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_rp.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_rp,
           "pending_secondaries" => %{"by_slot" => %{}, "reconcile_pending" => true}
         })}
      end)

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "qa" do
        {:ok, %{"session" => "ses_rp_qa", "slot" => "qa"}}
      else
        {:ok, %{"session" => "ses_rp_lead", "slot" => "lead"}}
      end
    end)

    CodingSandboxes.connected(%{
      tenant_id: ctx.tenant,
      group_id: ctx.group,
      device_id: rp_device,
      connector_run_id: run_rp,
      workload_id: w_rp.id,
      workload_generation: w_rp.generation
    })

    {:ok, after_rp} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_rp)
    assert after_rp.spec["pending_secondaries"] == nil

    {:ok, rp_rows} = StationTaskSessions.of_task(ctx.group, conv_rp)
    assert Enum.any?(rp_rows, &(&1.session == "ses_rp_qa"))
  end

  test "R12 regressions: single-session invisible omit, actor rollback, reconcile_pending, superseded slot guard",
       ctx do
    # ── R12 P0-1: Legacy single-session Station with real top-level `delivery_filter` ──
    run_leg = register_device(ctx, "r12_leg_vis", %{"tasks" => 2})

    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "participant_id" => "p_r12_lead",
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active"
          }
        ],
        messages: [
          %{
            "seq" => 1,
            "message_id" => "msg_r12_allowed",
            "actor_type" => "user",
            "user_id" => "usr_1",
            "content" => "visible to lead",
            "created_at" => 1000,
            "delivery_filter" => %{"participant_ids" => ["p_r12_lead"]},
            "metadata" => %{}
          },
          %{
            "seq" => 2,
            "message_id" => "msg_r12_secret",
            "actor_type" => "user",
            "user_id" => "usr_1",
            "content" => "TOP SECRET BODY NOT FOR LEAD",
            "created_at" => 2000,
            "delivery_filter" => %{"participant_ids" => ["p_other_only"]},
            "metadata" => %{
              "attachments" => [
                %{"name" => "secret.pdf", "url" => "https://example.test/secret.pdf"}
              ]
            }
          }
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    conv_vis = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_vis,
        device_id: ctx.device,
        session: "ses_r12_vis",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_leg}
      })

    {:ok, captured_puts} = Agent.start_link(fn -> [] end)

    FakeConnector.on("task.put", fn params ->
      Agent.update(captured_puts, &[params | &1])
      {:ok, %{"through" => params["through"]}}
    end)

    :ok = StationTasks.give(ctx.group, conv_vis, ctx.device)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_vis) do
        {:ok, [r]} -> r.sent == 2
        _ -> false
      end
    end)

    puts = Agent.get(captured_puts, &Enum.reverse/1)
    assert puts != []
    sent_msgs = Enum.flat_map(puts, &(&1["messages"] || []))
    assert Enum.any?(sent_msgs, &(&1["text"] == "visible to lead"))
    refute Enum.any?(sent_msgs, &String.contains?(&1["text"] || "", "TOP SECRET BODY"))
    refute Enum.any?(sent_msgs, &(&1["seq"] == 2))
    Agent.stop(captured_puts)

    # ── R12 P1-1: Conditional rollback of uncommitted Actor candidate_token ──
    conv_rb = Ids.new_conversation_id()
    now_rb = SystemsClock.system_time(:millisecond)

    spec_rb = %{
      "group_id" => ctx.group,
      "conversation_id" => conv_rb,
      "title" => "R12 actor rollback",
      "creator_user_id" => "usr_owner",
      "status" => "open",
      "runs_on" => %{"kind" => "device", "device_id" => ctx.device},
      "worker_agent_id" => ctx.agent,
      "conversation" => %{
        "conversation_id" => conv_rb,
        "group_id" => ctx.group,
        "type" => "task",
        "title" => "R12 actor rollback",
        "status" => "open",
        "created_at" => now_rb,
        "updated_at" => now_rb,
        "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => ctx.device}},
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_rb,
            "updated_at" => now_rb
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_rb,
            "updated_at" => now_rb
          }
        ]
      }
    }

    assert {:ok, _} = ConversationServer.create_task(ctx.group, conv_rb, spec_rb)

    {:ok, %{"participants" => rb_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_rb)

    rb_rev_pid = Enum.find(rb_parts, &(&1["target_key"] == "reviewer"))["participant_id"]

    # Mark pending candidate token, then clear uncommitted -> restores unbound so deactivation succeeds!
    assert :ok =
             ConversationServer.mark_task_participant_bound_pending(
               ctx.group,
               conv_rb,
               rb_rev_pid,
               "cand_fail_1"
             )

    assert :ok =
             ConversationServer.clear_uncommitted_task_participant_bound(
               ctx.group,
               conv_rb,
               rb_rev_pid,
               "cand_fail_1"
             )

    # Stale clear after newer pending binding returns {:error, :stale} and never clobbers newer binding
    assert :ok =
             ConversationServer.mark_task_participant_bound_pending(
               ctx.group,
               conv_rb,
               rb_rev_pid,
               "tok_newer"
             )

    assert {:error, :stale} =
             ConversationServer.clear_uncommitted_task_participant_bound(
               ctx.group,
               conv_rb,
               rb_rev_pid,
               "cand_fail_1"
             )

    # Clear tok_newer -> restores unbound -> deactivate_unbound_task_participant deactivates cleanly!
    assert :ok =
             ConversationServer.clear_uncommitted_task_participant_bound(
               ctx.group,
               conv_rb,
               rb_rev_pid,
               "tok_newer"
             )

    assert {:ok, %{"state" => rb_state}} =
             ConversationServer.deactivate_unbound_task_participant(
               ctx.group,
               conv_rb,
               rb_rev_pid,
               nil
             )

    assert rb_state != "active"

    # ── R12 P1-2: Sandbox append/confirm preserves global `reconcile_pending: true` ──
    conv_p12 = Ids.new_conversation_id()

    {:ok, w_p12} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p12,
        workspace: "ws_r12_p12",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "reviewer", "is_primary" => false}
          }
        ]
      })

    p12_dev = w_p12.spec["device_id"]
    p12_tr = SalixStore.CodingSandboxes.transport_id(conv_p12)

    {:ok, ^p12_tr, p12_rec} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => p12_dev,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_p12),
          "workload_id" => w_p12.id,
          "workload_generation" => w_p12.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: p12_tr
      )

    run_p12 = p12_rec["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p12,
        device_id: p12_dev,
        session: "ses_p12_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_p12}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_p12.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_p12,
           "pending_secondaries" => %{"by_slot" => %{}, "reconcile_pending" => true}
         })}
      end)

    FakeConnector.on("task.invite", fn params ->
      {:ok, %{"session" => "ses_p12_#{params["slot"]}", "slot" => params["slot"]}}
    end)

    assert :ok =
             CodingSandboxes.add_session_start(ctx.tenant, conv_p12, %{
               "slot" => "qa",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "start" => %{"slot" => "qa", "is_primary" => false}
             })

    {:ok, after_p12} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_p12)
    assert get_in(after_p12.spec, ["pending_secondaries", "reconcile_pending"]) == true

    # ── R12 P1-3: `:station_outdated` cleanup guards superseded same-name slot (`participant_id` + `request_ids`) ──
    conv_p13 = Ids.new_conversation_id()

    {:ok, w_p13} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p13,
        workspace: "ws_r12_p13",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_old_rev",
            "start" => %{
              "slot" => "reviewer",
              "is_primary" => false,
              "participant_id" => "ptp_old_rev"
            }
          }
        ]
      })

    p13_dev = w_p13.spec["device_id"]
    p13_tr = SalixStore.CodingSandboxes.transport_id(conv_p13)

    {:ok, ^p13_tr, p13_rec} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => p13_dev,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_p13),
          "workload_id" => w_p13.id,
          "workload_generation" => w_p13.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: p13_tr
      )

    run_p13 = p13_rec["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p13,
        device_id: p13_dev,
        session: "ses_p13_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_p13}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_p13.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_p13,
           "pending_secondaries" => %{
             "by_slot" => %{
               "reviewer" => %{
                 "attempts" => 0,
                 "next_retry_at_ms" => SystemsClock.system_time(:millisecond) - 1_000,
                 "request_ids" => ["req_old_rev"]
               }
             }
           }
         })}
      end)

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        # Simulate concurrent re-add of same slot `reviewer` with new participant_id + new request_id
        # BEFORE the old refusal's Store.update commits!
        {:ok, _} =
          SalixStore.CodingSandboxes.update(w_p13.id, fn cur ->
            starts_new =
              Enum.map(cur.spec["starts"], fn e ->
                if e["slot"] == "reviewer" do
                  %{
                    "slot" => "reviewer",
                    "is_primary" => false,
                    "agent_id" => ctx.agent,
                    "participant_id" => "ptp_new_rev",
                    "start" => %{
                      "slot" => "reviewer",
                      "is_primary" => false,
                      "participant_id" => "ptp_new_rev"
                    }
                  }
                else
                  e
                end
              end)

            by_slot =
              (get_in(cur.spec, ["pending_secondaries", "by_slot"]) || %{})
              |> Map.put("reviewer", %{
                "attempts" => 0,
                "request_ids" => ["req_old_rev", "req_new_rev"]
              })

            {:ok,
             cur.spec
             |> Map.put("starts", starts_new)
             |> Map.put("pending_secondaries", %{"by_slot" => by_slot})}
          end)

        {:error, "model unavailable"}
      else
        {:ok, %{"session" => "ses_p13_lead", "slot" => "lead"}}
      end
    end)

    CodingSandboxes.connected(%{
      tenant_id: ctx.tenant,
      group_id: ctx.group,
      device_id: p13_dev,
      connector_run_id: run_p13,
      workload_id: w_p13.id,
      workload_generation: w_p13.generation
    })

    {:ok, after_p13} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_p13)
    rev_start = Enum.find(after_p13.spec["starts"], &(&1["slot"] == "reviewer"))
    assert rev_start != nil
    assert rev_start["participant_id"] == "ptp_new_rev"

    assert "req_new_rev" in (get_in(after_p13.spec, [
                               "pending_secondaries",
                               "by_slot",
                               "reviewer",
                               "request_ids"
                             ]) || [])
  end

  test "R13 regressions: answered guard on join fallback, committed vs pending actor rollback, and start_version guard after confirm",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks, connector: FakeConnector)

    # ── R13 P0: register_slot_binding join_with_token failure with stale existing row (answered 0 < 9)
    # MUST return error and NEVER falsely return :ok! ──
    conv_ans = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_ans,
        device_id: ctx.device,
        session: "ses_r13_ans",
        agent_id: ctx.agent,
        answered: 0,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "connector_run_id" => "run_ans",
          "binding_token" => "tok_existing_0"
        }
      })

    # Passing tenant_id: nil forces a DB NOT NULL error inside join_with_token while of_task
    # succeeds and reads the existing row with answered=0 (< requested answered=9).
    assert {:error, _} =
             StationTasks.register_slot_binding(%{
               tenant_id: nil,
               group_id: ctx.group,
               conversation_id: conv_ans,
               device_id: ctx.device,
               session: "ses_r13_ans",
               agent_id: ctx.agent,
               answered: 9,
               give: false,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "connector_run_id" => "run_ans"
               }
             })

    # ── R13 P1-1: Consecutive failed writes (A fails DB+readback, B fails DB & clears) MUST
    # restore station_bound: false (NEVER restore uncommitted A), allowing clean deactivation! ──
    conv_ab = Ids.new_conversation_id()
    now_ab = SystemsClock.system_time(:millisecond)

    spec_ab = %{
      "group_id" => ctx.group,
      "conversation_id" => conv_ab,
      "title" => "R13 committed vs pending actor",
      "creator_user_id" => "usr_owner",
      "status" => "open",
      "runs_on" => %{"kind" => "device", "device_id" => ctx.device},
      "worker_agent_id" => ctx.agent,
      "conversation" => %{
        "conversation_id" => conv_ab,
        "group_id" => ctx.group,
        "type" => "task",
        "title" => "R13 committed vs pending actor",
        "status" => "open",
        "created_at" => now_ab,
        "updated_at" => now_ab,
        "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => ctx.device}},
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_ab,
            "updated_at" => now_ab
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_ab,
            "updated_at" => now_ab
          }
        ]
      }
    }

    assert {:ok, _} = ConversationServer.create_task(ctx.group, conv_ab, spec_ab)

    {:ok, %{"participants" => ab_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_ab)

    ab_rev_pid = Enum.find(ab_parts, &(&1["target_key"] == "reviewer"))["participant_id"]

    # Attempt A marks pending candidate A (never committed), then attempt B marks pending candidate B
    assert :ok =
             ConversationServer.mark_task_participant_bound_pending(
               ctx.group,
               conv_ab,
               ab_rev_pid,
               "cand_A_uncommitted"
             )

    assert :ok =
             ConversationServer.mark_task_participant_bound_pending(
               ctx.group,
               conv_ab,
               ab_rev_pid,
               "cand_B_uncommitted"
             )

    # B clears uncommitted -> MUST restore station_bound: false (never restore cand_A!)
    assert :ok =
             ConversationServer.clear_uncommitted_task_participant_bound(
               ctx.group,
               conv_ab,
               ab_rev_pid,
               "cand_B_uncommitted"
             )

    assert {:ok, %{"state" => ab_state}} =
             ConversationServer.deactivate_unbound_task_participant(
               ctx.group,
               conv_ab,
               ab_rev_pid,
               nil
             )

    assert ab_state != "active"

    # ── R13 P1-2: Same participant_id re-added & ALREADY CONFIRMED (request_ids cleared!) with
    # new `start_version` -> old refusal cleanup MUST NOT delete healthy confirmed slot! ──
    conv_ver = Ids.new_conversation_id()

    {:ok, w_ver} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_ver,
        workspace: "ws_r13_ver",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "participant_id" => "ptp_same_rev",
            "start_seq" => 1,
            "start" => %{
              "slot" => "reviewer",
              "is_primary" => false,
              "participant_id" => "ptp_same_rev"
            }
          }
        ]
      })

    ver_dev = w_ver.spec["device_id"]
    ver_tr = SalixStore.CodingSandboxes.transport_id(conv_ver)

    {:ok, ^ver_tr, ver_rec} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ver_dev,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_ver),
          "workload_id" => w_ver.id,
          "workload_generation" => w_ver.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: ver_tr
      )

    run_ver = ver_rec["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_ver,
        device_id: ver_dev,
        session: "ses_ver_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_ver}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_ver.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_ver,
           "pending_secondaries" => %{
             "by_slot" => %{
               "reviewer" => %{
                 "attempts" => 0,
                 "next_retry_at_ms" => SystemsClock.system_time(:millisecond) - 1_000,
                 "request_ids" => ["ver_old_1"]
               }
             }
           }
         })}
      end)

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        # Simulate B re-adding SAME participant_id AND ALREADY CONFIRMING (clearing pending_secondaries!)
        {:ok, _} =
          SalixStore.CodingSandboxes.update(w_ver.id, fn cur ->
            starts_confirmed =
              Enum.map(cur.spec["starts"], fn e ->
                if e["slot"] == "reviewer",
                  do: Map.put(e, "start_seq", 2),
                  else: e
              end)

            {:ok,
             cur.spec
             |> Map.put("starts", starts_confirmed)
             |> Map.delete("pending_secondaries")}
          end)

        {:error, "model unavailable"}
      else
        {:ok, %{"session" => "ses_ver_lead", "slot" => "lead"}}
      end
    end)

    CodingSandboxes.connected(%{
      tenant_id: ctx.tenant,
      group_id: ctx.group,
      device_id: ver_dev,
      connector_run_id: run_ver,
      workload_id: w_ver.id,
      workload_generation: w_ver.generation
    })

    {:ok, after_ver} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_ver)
    rev_after = Enum.find(after_ver.spec["starts"], &(&1["slot"] == "reviewer"))
    assert rev_after != nil
    assert rev_after["start_seq"] == 2
  end

  test "R14 single-ownership rulings: serialized bind/deactivate in ParticipantActor and monotonic start_seq in CodingSandboxes",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks, connector: FakeConnector)

    # ── R14 P0 & P1-1: Single-owner ParticipantActor serializes bind + deactivate_if_unbound ──
    conv_so = Ids.new_conversation_id()
    now_so = SystemsClock.system_time(:millisecond)

    spec_so = %{
      "group_id" => ctx.group,
      "conversation_id" => conv_so,
      "title" => "R14 single-owner actor",
      "creator_user_id" => "usr_owner",
      "status" => "open",
      "runs_on" => %{"kind" => "device", "device_id" => ctx.device},
      "worker_agent_id" => ctx.agent,
      "conversation" => %{
        "conversation_id" => conv_so,
        "group_id" => ctx.group,
        "type" => "task",
        "title" => "R14 single-owner actor",
        "status" => "open",
        "created_at" => now_so,
        "updated_at" => now_so,
        "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => ctx.device}},
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => nil,
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_so,
            "updated_at" => now_so
          },
          %{
            "actor_type" => "agent",
            "agent_id" => ctx.agent,
            "role_label" => "worker",
            "target_key" => "reviewer",
            "state" => "active",
            "payload" => %{"session_id" => Ids.new_session_id()},
            "notification_filter" => %{"messages" => "none", "statuses" => "none"},
            "joined_at" => now_so,
            "updated_at" => now_so
          }
        ]
      }
    }

    assert {:ok, _} = ConversationServer.create_task(ctx.group, conv_so, spec_so)

    {:ok, %{"participants" => so_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_so)

    so_rev_pid = Enum.find(so_parts, &(&1["target_key"] == "reviewer"))["participant_id"]

    # P1-1: Failed bind (tenant_id: nil) NEVER mutates Actor -> subsequent deactivate_if_unbound
    # with verify_unbound_fun sees DB empty (:unbound) and atomically deactivates!
    assert {:error, _} =
             StationTasks.register_slot_binding(%{
               tenant_id: nil,
               group_id: ctx.group,
               conversation_id: conv_so,
               device_id: ctx.device,
               session: "ses_r14_fail",
               agent_id: ctx.agent,
               participant_id: so_rev_pid,
               give: false,
               start: %{"slot" => "reviewer", "is_primary" => false}
             })

    verify_fn = StationTasks.slot_verify_unbound_fun(ctx.group, conv_so, ctx.device, "reviewer")

    assert {:ok, %{"state" => "inactive"}} =
             ConversationServer.deactivate_unbound_task_participant(
               ctx.group,
               conv_so,
               so_rev_pid,
               nil,
               verify_fn
             )

    # P0: On a fresh task, successful bind A + failing bind B + stale deactivate ->
    # Actor stays bound to A's DB token and participant stays active!
    conv_p0 = Ids.new_conversation_id()

    spec_p0 =
      spec_so
      |> Map.put("conversation_id", conv_p0)
      |> put_in(["conversation", "conversation_id"], conv_p0)

    assert {:ok, _} = ConversationServer.create_task(ctx.group, conv_p0, spec_p0)

    {:ok, %{"participants" => p0_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p0)

    p0_rev_pid = Enum.find(p0_parts, &(&1["target_key"] == "reviewer"))["participant_id"]

    assert :ok =
             StationTasks.register_slot_binding(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_p0,
               device_id: ctx.device,
               session: "ses_r14_live_S",
               agent_id: ctx.agent,
               participant_id: p0_rev_pid,
               give: false,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "connector_run_id" => "run_r14"
               }
             })

    # Concurrent failing registration B for a different session MUST NOT clear A's bound state
    assert {:error, _} =
             StationTasks.register_slot_binding(%{
               tenant_id: nil,
               group_id: ctx.group,
               conversation_id: conv_p0,
               device_id: ctx.device,
               session: "ses_r14_other_fail",
               agent_id: ctx.agent,
               participant_id: p0_rev_pid,
               give: false,
               start: %{"slot" => "reviewer", "is_primary" => false}
             })

    verify_p0 = StationTasks.slot_verify_unbound_fun(ctx.group, conv_p0, ctx.device, "reviewer")

    assert {:ok, :already_bound} =
             ConversationServer.deactivate_unbound_task_participant(
               ctx.group,
               conv_p0,
               p0_rev_pid,
               nil,
               verify_p0
             )

    # ── R14 P1-2: Monotonic `start_seq` in CodingSandboxes protects newer B (seq=2) from
    # late confirm A (seq=1) + old refusal cleanup (snap.start_seq=1)! ──
    conv_seq = Ids.new_conversation_id()

    spec_seq =
      spec_so
      |> Map.put("conversation_id", conv_seq)
      |> put_in(["conversation", "conversation_id"], conv_seq)

    assert {:ok, _} = ConversationServer.create_task(ctx.group, conv_seq, spec_seq)

    {:ok, %{"participants" => seq_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_seq)

    seq_rev_pid = Enum.find(seq_parts, &(&1["target_key"] == "reviewer"))["participant_id"]

    {:ok, w_seq} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_seq,
        workspace: "ws_r14_seq",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    seq_dev = w_seq.spec["device_id"]
    seq_tr = SalixStore.CodingSandboxes.transport_id(conv_seq)

    {:ok, ^seq_tr, seq_rec} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => seq_dev,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_seq),
          "workload_id" => w_seq.id,
          "workload_generation" => w_seq.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: seq_tr
      )

    run_seq = seq_rec["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_seq,
        device_id: seq_dev,
        session: "ses_seq_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_seq}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_seq.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_seq
         })}
      end)

    # First call (A) gets seq=1, pauses inside task.invite while B gets seq=2 and confirms!
    inv_count = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        n = :atomics.add_get(inv_count, 1, 1)

        if n == 1 do
          # Inside A (seq=1), run B (seq=2) to completion BEFORE A returns and confirms!
          assert :ok =
                   CodingSandboxes.add_session_start(ctx.tenant, conv_seq, %{
                     "slot" => "reviewer",
                     "is_primary" => false,
                     "agent_id" => ctx.agent,
                     "participant_id" => seq_rev_pid,
                     "start" => %{
                       "slot" => "reviewer",
                       "is_primary" => false,
                       "participant_id" => seq_rev_pid
                     }
                   })

          {:ok, %{"session" => "ses_seq_rev_a", "slot" => "reviewer"}}
        else
          {:ok, %{"session" => "ses_seq_rev_b", "slot" => "reviewer"}}
        end
      else
        {:ok, %{"session" => "ses_seq_lead", "slot" => "lead"}}
      end
    end)

    assert :ok =
             CodingSandboxes.add_session_start(ctx.tenant, conv_seq, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => seq_rev_pid,
               "start" => %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "participant_id" => seq_rev_pid
               }
             })

    {:ok, after_seq} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_seq)
    rev_seq = Enum.find(after_seq.spec["starts"], &(&1["slot"] == "reviewer"))
    assert rev_seq != nil
    assert rev_seq["start_seq"] == 2
    assert get_in(after_seq.spec, ["slot_seq_hwm", "reviewer"]) == 2

    # R15 P0-1: DB has strictly ONE active row for `(seq_dev, "reviewer")` (`ses_seq_rev_b`),
    # late A (`ses_seq_rev_a`, seq=1) was rejected by DB FOR UPDATE gate, Actor points to B,
    # and StationTasks.session_statuses returns normal status for B!
    {:ok, seq_db_rows} = StationTaskSessions.of_task(ctx.group, conv_seq)

    rev_db_rows =
      Enum.filter(seq_db_rows, fn r ->
        r.device_id == seq_dev and get_in(r.start || %{}, ["slot"]) == "reviewer"
      end)

    assert length(rev_db_rows) == 1
    assert hd(rev_db_rows).session == "ses_seq_rev_b"

    {:ok, %{"participants" => seq_parts_after}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_seq)

    rev_part_after = Enum.find(seq_parts_after, &(&1["participant_id"] == seq_rev_pid))

    assert String.starts_with?(
             get_in(rev_part_after, ["payload", "bound_token"]) || "",
             "ses_seq_rev_b@"
           )

    FakeConnector.on("task.status", fn _ ->
      {:ok,
       %{
         "slots" => [
           %{"slot" => "lead", "session" => "ses_seq_lead", "state" => "idle", "pending" => 0},
           %{
             "slot" => "reviewer",
             "session" => "ses_seq_rev_b",
             "state" => "idle",
             "pending" => 0
           }
         ]
       }}
    end)

    assert {:ok, %{state: :idle, slots: statuses}} =
             StationTasks.session_statuses(ctx.group, conv_seq)

    rev_st = Enum.find(statuses, &(&1.slot == "reviewer"))
    assert rev_st != nil
    assert rev_st.session == "ses_seq_rev_b"
    assert rev_st.state == :idle

    # ── R15 P1-1 & P1-2: Reverse dual permanent refusal (B=2 refuses first while A=1 in-flight,
    # then A=1 refuses second) cleans up `starts`, preserves `slot_seq_hwm == 2`, and a later
    # re-add C gets `start_seq == 3`! ──
    conv_rev2 = Ids.new_conversation_id()

    {:ok, w_rev2} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_rev2,
        workspace: "ws_r15_rev2",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    r2_dev = w_rev2.spec["device_id"]
    r2_tr = SalixStore.CodingSandboxes.transport_id(conv_rev2)

    {:ok, ^r2_tr, r2_rec} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => r2_dev,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_rev2),
          "workload_id" => w_rev2.id,
          "workload_generation" => w_rev2.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: r2_tr
      )

    run_r2 = r2_rec["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_rev2,
        device_id: r2_dev,
        session: "ses_r2_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_r2}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_rev2.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_r2
         })}
      end)

    refusal_calls = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        n = :atomics.add_get(refusal_calls, 1, 1)

        if n == 1 do
          # Inside A (seq=1), run B (seq=2) which permanently refuses FIRST while A is still in-flight!
          assert {:error, {:station_refused, "policy denied"}} =
                   CodingSandboxes.add_session_start(ctx.tenant, conv_rev2, %{
                     "slot" => "reviewer",
                     "is_primary" => false,
                     "agent_id" => ctx.agent,
                     "start" => %{"slot" => "reviewer", "is_primary" => false}
                   })

          # Now A (seq=1) also permanently refuses!
          {:error, "policy denied"}
        else
          {:error, "policy denied"}
        end
      else
        {:ok, %{"session" => "ses_r2_lead", "slot" => "lead"}}
      end
    end)

    assert {:error, {:station_refused, "policy denied"}} =
             CodingSandboxes.add_session_start(ctx.tenant, conv_rev2, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    {:ok, after_r2} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_rev2)
    assert Enum.find(after_r2.spec["starts"], &(&1["slot"] == "reviewer")) == nil
    assert after_r2.spec["pending_secondaries"] == nil
    assert get_in(after_r2.spec, ["slot_seq_hwm", "reviewer"]) == 2

    # Subsequent re-add C after deletion gets monotonic start_seq == 3 (> 2)!
    FakeConnector.on("task.invite", fn params ->
      {:ok, %{"session" => "ses_r2_#{params["slot"]}", "slot" => params["slot"]}}
    end)

    assert :ok =
             CodingSandboxes.add_session_start(ctx.tenant, conv_rev2, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    {:ok, after_r2_c} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_rev2)
    rev_c = Enum.find(after_r2_c.spec["starts"], &(&1["slot"] == "reviewer"))
    assert rev_c["start_seq"] == 3
    assert get_in(after_r2_c.spec, ["slot_seq_hwm", "reviewer"]) == 3
  end

  defmodule FlakyUnboundConversations do
    def start_link(fail_counter),
      do: Agent.start_link(fn -> fail_counter end, name: __MODULE__)

    def stop do
      case Process.whereis(__MODULE__) do
        nil ->
          :ok

        pid ->
          try do
            Agent.stop(pid)
          catch
            :exit, _ -> :ok
          end
      end
    end

    def participants(g, c), do: SalixWeb.StationTasks.Conversations.participants(g, c)

    def messages_after(g, c, a, l),
      do: SalixWeb.StationTasks.Conversations.messages_after(g, c, a, l)

    def append(g, c, a, attrs), do: SalixWeb.StationTasks.Conversations.append(g, c, a, attrs)

    def record_coding_pending_review(g, c, s),
      do: SalixWeb.StationTasks.Conversations.record_coding_pending_review(g, c, s)

    def turn_ended(g, c, s), do: SalixWeb.StationTasks.Conversations.turn_ended(g, c, s)

    def deactivate_unbound_task_participant(g, c, p, stale_tok, verify_fun) do
      ctr = Agent.get(__MODULE__, & &1)

      if :atomics.add_get(ctr, 1, 1) == 1 do
        # Simulate transient DB failure inside Actor lock -> returns {:error, :binding_state_unavailable}
        SalixWeb.StationTasks.Conversations.deactivate_unbound_task_participant(
          g,
          c,
          p,
          stale_tok,
          fn _ -> :unknown end
        )
      else
        SalixWeb.StationTasks.Conversations.deactivate_unbound_task_participant(
          g,
          c,
          p,
          stale_tok,
          verify_fun
        )
      end
    end
  end

  test "R16 P0-1/P0-2/P1-1/P1-2: same-session start_seq monotonicity, reconcile_invites start_seq propagation, stale cleanup never resurrects deleted slot, and personal station :binding_state_unavailable retains pending + retries",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations
    )

    # ── 1. R16 P0-1 (with real ConversationParticipantActor): S@seq=1, B@seq=3 re-confirms S -> late A@seq=2(SA) rejected, DB & Actor keep S ──
    conv_p01 = Ids.new_conversation_id()
    now_r16 = SystemsClock.system_time(:millisecond)

    make_r16_task_spec = fn conv_id, title ->
      %{
        "group_id" => ctx.group,
        "conversation_id" => conv_id,
        "title" => title,
        "creator_user_id" => "usr_owner",
        "status" => "open",
        "runs_on" => %{"kind" => "device", "device_id" => ctx.device},
        "worker_agent_id" => ctx.agent,
        "conversation" => %{
          "conversation_id" => conv_id,
          "group_id" => ctx.group,
          "type" => "task",
          "title" => title,
          "status" => "open",
          "created_at" => now_r16,
          "updated_at" => now_r16,
          "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => ctx.device}},
          "participants" => [
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => nil,
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r16,
              "updated_at" => now_r16
            },
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => "reviewer",
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r16,
              "updated_at" => now_r16
            }
          ]
        }
      }
    end

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_p01,
               make_r16_task_spec.(conv_p01, "R16 P0-1")
             )

    {:ok, %{"participants" => p01_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p01)

    pid_p01 = Enum.find(p01_parts, &(&1["target_key"] == "reviewer"))["participant_id"]
    run_p01 = register_device(ctx, "r16_p01", %{"tasks" => 2, "multi_session_tasks" => true})

    assert :ok =
             StationTasks.register_slot_binding(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_p01,
               device_id: ctx.device,
               session: "S",
               agent_id: ctx.agent,
               participant_id: pid_p01,
               give: false,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "connector_run_id" => run_p01,
                 "start_seq" => 1
               }
             })

    assert :ok =
             StationTasks.register_slot_binding(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_p01,
               device_id: ctx.device,
               session: "S",
               agent_id: ctx.agent,
               participant_id: pid_p01,
               give: false,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "connector_run_id" => run_p01,
                 "start_seq" => 3
               }
             })

    assert {:error, {:stale_slot_binding, "S"}} =
             StationTasks.register_slot_binding(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_p01,
               device_id: ctx.device,
               session: "SA",
               agent_id: ctx.agent,
               participant_id: pid_p01,
               give: false,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "connector_run_id" => run_p01,
                 "start_seq" => 2
               }
             })

    {:ok, [s_db]} = StationTaskSessions.of_task(ctx.group, conv_p01)
    assert s_db.session == "S"
    assert s_db.start["start_seq"] == 3

    {:ok, %{"participants" => p01_list}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p01)

    p01_actor = Enum.find(p01_list, &(&1["participant_id"] == pid_p01))
    assert p01_actor["state"] == "active"
    assert String.starts_with?(get_in(p01_actor, ["payload", "bound_token"]) || "", "S@")

    # ── 2. R16 P0-2: background reconcile_invites propagates authoritative start_seq=2 for SB, rejecting late A(seq=1, SA) ──
    conv_p02 = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_p02,
               make_r16_task_spec.(conv_p02, "R16 P0-2")
             )

    {:ok, w_p02} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p02,
        workspace: "ws_r16_p02",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start_seq" => 2,
            "start" => %{"slot" => "reviewer", "is_primary" => false}
          }
        ]
      })

    dev_p02 = w_p02.spec["device_id"]
    tr_p02 = SalixStore.CodingSandboxes.transport_id(conv_p02)

    {:ok, ^tr_p02, rec_p02} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_p02,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_p02),
          "workload_id" => w_p02.id,
          "workload_generation" => w_p02.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_p02
      )

    run_p02 = rec_p02["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p02,
        device_id: dev_p02,
        session: "ses_p02_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_p02}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_p02.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_p02,
           "slot_seq_hwm" => %{"reviewer" => 2},
           "pending_secondaries" => %{
             "by_slot" => %{"reviewer" => %{"attempts" => 0, "latest_seq" => 2}},
             "reconcile_pending" => true
           }
         })}
      end)

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        {:ok, %{"session" => "SB", "slot" => "reviewer"}}
      else
        {:ok, %{"session" => "ses_p02_lead", "slot" => "lead"}}
      end
    end)

    CodingSandboxes.connected(%{
      tenant_id: ctx.tenant,
      group_id: ctx.group,
      device_id: dev_p02,
      workload_id: w_p02.id,
      workload_generation: w_p02.generation,
      connector_run_id: run_p02
    })

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_p02) do
        {:ok, rows} -> Enum.any?(rows, &(&1.session == "SB"))
        _ -> false
      end
    end)

    {:ok, rows_p02} = StationTaskSessions.of_task(ctx.group, conv_p02)
    sb_row = Enum.find(rows_p02, &(&1.session == "SB"))
    assert sb_row != nil
    assert sb_row.start["start_seq"] == 2

    # Late A (seq=1, SA) MUST be rejected and DB unique binding stays SB!
    assert {:error, {:stale_slot_binding, "SB"}} =
             StationTasks.register_slot_binding(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_p02,
               device_id: dev_p02,
               session: "SA",
               agent_id: ctx.agent,
               give: false,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "connector_run_id" => run_p02,
                 "start_seq" => 1
               }
             })

    {:ok, rows_p02_after} = StationTaskSessions.of_task(ctx.group, conv_p02)
    rev_rows_p02 = Enum.filter(rows_p02_after, &(get_in(&1.start, ["slot"]) == "reviewer"))
    assert Enum.map(rev_rows_p02, & &1.session) == ["SB"]

    # ── 3. R16 P1-1: A=1 pauses after invite -> B=2 refuses & clears starts+pending (hwm=2) -> A=1 resumes -> NEVER resurrects reviewer! ──
    conv_p11 = Ids.new_conversation_id()

    {:ok, w_p11} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p11,
        workspace: "ws_r16_p11",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    dev_p11 = w_p11.spec["device_id"]
    tr_p11 = SalixStore.CodingSandboxes.transport_id(conv_p11)

    {:ok, ^tr_p11, rec_p11} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_p11,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_p11),
          "workload_id" => w_p11.id,
          "workload_generation" => w_p11.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_p11
      )

    run_p11 = rec_p11["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p11,
        device_id: dev_p11,
        session: "ses_p11_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_p11}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_p11.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_p11
         })}
      end)

    p11_calls = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        n = :atomics.add_get(p11_calls, 1, 1)

        if n == 1 do
          # While A (seq=1) is paused mid-invite, B (seq=2) enters, gets refused, and clears
          # reviewer from `starts` & `pending` while leaving `slot_seq_hwm["reviewer"] == 2`!
          assert {:error, {:station_refused, "policy denied"}} =
                   CodingSandboxes.add_session_start(ctx.tenant, conv_p11, %{
                     "slot" => "reviewer",
                     "is_primary" => false,
                     "agent_id" => ctx.agent,
                     "start" => %{"slot" => "reviewer", "is_primary" => false}
                   })

          # Simulate B=2 having removed reviewer completely from starts & pending (leaving hwm=2)
          {:ok, _} =
            SalixStore.CodingSandboxes.update(w_p11.id, fn cur ->
              {:ok,
               cur.spec
               |> Map.put(
                 "starts",
                 Enum.reject(cur.spec["starts"] || [], &(&1["slot"] == "reviewer"))
               )
               |> Map.delete("pending_secondaries")}
            end)

          # Now A (seq=1) resumes and succeeds its invite -> pre_join_check rejects as stale
          # and with 0 DB bindings add_session_start returns {:error, :stale_slot_binding},
          # NEVER resurrecting reviewer in `spec["starts"]`!
          {:ok, %{"session" => "ses_p11_a", "slot" => "reviewer"}}
        else
          {:error, "policy denied"}
        end
      else
        {:ok, %{"session" => "ses_p11_lead", "slot" => "lead"}}
      end
    end)

    assert {:error, :stale_slot_binding} =
             CodingSandboxes.add_session_start(ctx.tenant, conv_p11, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    {:ok, after_p11} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_p11)
    assert Enum.find(after_p11.spec["starts"], &(&1["slot"] == "reviewer")) == nil
    assert get_in(after_p11.spec, ["slot_seq_hwm", "reviewer"]) == 2

    # ── 4. R16 P1-2: personal station online add_session permanent refusal + :binding_state_unavailable
    # retains pending_multi_starts & schedules next_retry_at; after DB recovers & SystemsClock advances,
    # background retry deactivates participant and clears pending_multi_starts! ──
    fail_ctr = :atomics.new(1, [])
    {:ok, _} = FlakyUnboundConversations.start_link(fail_ctr)

    on_exit(fn -> FlakyUnboundConversations.stop() end)

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FlakyUnboundConversations
    )

    conv_p12 = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_p12,
               make_r16_task_spec.(conv_p12, "R16 P1-2")
             )

    {:ok, %{"participants" => p12_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p12)

    pid_p12 = Enum.find(p12_parts, &(&1["target_key"] == "reviewer"))["participant_id"]
    run_p12 = register_device(ctx, "r16_p12", %{"tasks" => 2, "multi_session_tasks" => true})

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p12,
        device_id: ctx.device,
        session: "ses_p12_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_p12}
      })

    invite_calls_p12 = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        n = :atomics.add_get(invite_calls_p12, 1, 1)

        if n == 1 do
          {:error, "policy denied"}
        else
          # If a second invite were ever sent, station would accept it!
          {:ok, %{"session" => "ses_p12_must_never_bind", "slot" => "reviewer"}}
        end
      else
        {:ok, %{"session" => "ses_p12_lead", "slot" => "lead"}}
      end
    end)

    FakeConnector.on("task.put", fn _ -> {:ok, %{"through" => 0}} end)

    assert {:error, {:station_refused, "policy denied"}} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_p12,
               device_id: ctx.device,
               agent_id: ctx.agent,
               participant_id: pid_p12,
               slot: "reviewer",
               start: %{"slot" => "reviewer", "is_primary" => false}
             })

    # Participant is STILL active and pending_multi_starts is RETAINED with next_retry_at & pending_deactivation!
    {:ok, %{"participants" => p12_mid}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p12)

    assert Enum.find(p12_mid, &(&1["participant_id"] == pid_p12))["state"] == "active"

    {:ok, [lead_mid]} = StationTaskSessions.of_task(ctx.group, conv_p12)

    pending_mid =
      Enum.find(lead_mid.start["pending_multi_starts"] || [], &(&1["slot"] == "reviewer"))

    assert pending_mid != nil
    assert is_integer(pending_mid["next_retry_at"])
    assert pending_mid["pending_deactivation"] == true

    # Advance SystemsClock past next_retry_at -> DB authority is now healthy (fail_ctr >= 2) ->
    # background retry executes deactivation ONLY (0 second invites!), deactivates participant, and clears pending!
    SystemsClock.advance(30_000)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_p12) do
        {:ok, [row]} -> List.wrap(row.start["pending_multi_starts"]) == []
        _ -> false
      end
    end)

    assert :atomics.get(invite_calls_p12, 1) == 1

    {:ok, %{"participants" => p12_end}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p12)

    assert Enum.find(p12_end, &(&1["participant_id"] == pid_p12))["state"] == "inactive"

    {:ok, [lead_end]} = StationTaskSessions.of_task(ctx.group, conv_p12)
    assert List.wrap(lead_end.start["pending_multi_starts"]) == []
  end

  test "R17 P0-1/P0-3/P1-1: readback validates slot & start_seq, pre_join_check blocks stale DB write, confirm_start_entry never resurrects deleted current generation, and drop_stale_request_id preserves backoff",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations
    )

    now_r17 = SystemsClock.system_time(:millisecond)

    make_r17_spec = fn conv_id, title, dev_id ->
      %{
        "group_id" => ctx.group,
        "conversation_id" => conv_id,
        "title" => title,
        "creator_user_id" => "usr_owner",
        "status" => "open",
        "runs_on" => %{"kind" => "device", "device_id" => dev_id},
        "worker_agent_id" => ctx.agent,
        "conversation" => %{
          "conversation_id" => conv_id,
          "group_id" => ctx.group,
          "type" => "task",
          "title" => title,
          "status" => "open",
          "created_at" => now_r17,
          "updated_at" => now_r17,
          "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => dev_id}},
          "participants" => [
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => nil,
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r17,
              "updated_at" => now_r17
            },
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => "reviewer",
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r17,
              "updated_at" => now_r17
            }
          ]
        }
      }
    end

    # ── 1. R17 P0-1: existing S(seq=1); B(seq=3, S) upsert fails (nil tenant_id) -> readback sees S(1) < 3 -> returns error, NEVER :ok ──
    conv_rb = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_rb,
        device_id: ctx.device,
        session: "S_rb",
        agent_id: ctx.agent,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "binding_token" => "tok_s_rb_1",
          "start_seq" => 1
        }
      })

    assert {:error, _} =
             StationTasks.register_slot_binding(%{
               tenant_id: nil,
               group_id: ctx.group,
               conversation_id: conv_rb,
               device_id: ctx.device,
               session: "S_rb",
               agent_id: ctx.agent,
               give: false,
               start: %{"slot" => "reviewer", "is_primary" => false, "start_seq" => 3}
             })

    # Wrong-slot readback must also reject!
    assert {:error, _} =
             StationTasks.register_slot_binding(%{
               tenant_id: nil,
               group_id: ctx.group,
               conversation_id: conv_rb,
               device_id: ctx.device,
               session: "S_rb",
               agent_id: ctx.agent,
               give: false,
               start: %{"slot" => "qa", "is_primary" => false, "start_seq" => 1}
             })

    # ── 2. R17 P0-3 (a): B(2) removes reviewer while A(1) is mid-invite -> pre_join_check blocks DB write -> 0 reviewer DB rows, workload only lead, Actor unbound ──
    conv_p03 = Ids.new_conversation_id()

    {:ok, w_p03} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p03,
        workspace: "ws_r17_p03",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    dev_p03 = w_p03.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_p03,
               make_r17_spec.(conv_p03, "R17 P0-3", dev_p03)
             )

    {:ok, %{"participants" => p03_parts}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p03)

    pid_p03 = Enum.find(p03_parts, &(&1["target_key"] == "reviewer"))["participant_id"]
    tr_p03 = SalixStore.CodingSandboxes.transport_id(conv_p03)

    {:ok, ^tr_p03, rec_p03} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_p03,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_p03),
          "workload_id" => w_p03.id,
          "workload_generation" => w_p03.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_p03
      )

    run_p03 = rec_p03["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p03,
        device_id: dev_p03,
        session: "ses_p03_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_p03}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_p03.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_p03
         })}
      end)

    p03_calls = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        n = :atomics.add_get(p03_calls, 1, 1)

        if n == 1 do
          # B(2) enters, permanently refuses, and clears reviewer from starts + pending (hwm=2)
          assert {:error, {:station_refused, "policy denied"}} =
                   CodingSandboxes.add_session_start(ctx.tenant, conv_p03, %{
                     "slot" => "reviewer",
                     "is_primary" => false,
                     "agent_id" => ctx.agent,
                     "participant_id" => pid_p03,
                     "start" => %{"slot" => "reviewer", "is_primary" => false}
                   })

          {:ok, _} =
            SalixStore.CodingSandboxes.update(w_p03.id, fn cur ->
              {:ok,
               cur.spec
               |> Map.put(
                 "starts",
                 Enum.reject(cur.spec["starts"] || [], &(&1["slot"] == "reviewer"))
               )
               |> Map.delete("pending_secondaries")}
            end)

          # Now late A(1) returns success from station -> pre_join_check MUST block DB write & Actor bind!
          {:ok, %{"session" => "ses_p03_late_a", "slot" => "reviewer"}}
        else
          {:error, "policy denied"}
        end
      else
        {:ok, %{"session" => "ses_p03_lead", "slot" => "lead"}}
      end
    end)

    assert {:error, :stale_slot_binding} =
             CodingSandboxes.add_session_start(ctx.tenant, conv_p03, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_p03,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    # Strict 3-way consistency: DB has 0 reviewer rows, workload has only lead, Actor is unbound!
    {:ok, p03_db_rows} = StationTaskSessions.of_task(ctx.group, conv_p03)
    assert Enum.map(p03_db_rows, & &1.session) == ["ses_p03_lead"]

    {:ok, w_p03_after} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_p03)
    assert Enum.map(w_p03_after.spec["starts"], & &1["slot"]) == ["lead"]

    {:ok, %{"participants" => p03_parts_after}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p03)

    p03_actor = Enum.find(p03_parts_after, &(&1["participant_id"] == pid_p03))
    assert get_in(p03_actor, ["payload", "bound_token"]) == nil

    # ── 3. R17 P0-3 (b): my_seq == hwm == 1 already deleted & no request_id -> confirm_start_entry is a strict no-op, NEVER resurrects reviewer(1) ──
    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_p03.id, fn cur ->
        {:ok, Map.put(cur.spec, "slot_seq_hwm", %{"reviewer" => 1})}
      end)

    assert {:ok, w_no_resurrect} =
             CodingSandboxes.confirm_start_entry(
               w_p03.id,
               "reviewer",
               %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "agent_id" => ctx.agent,
                 "start" => %{"slot" => "reviewer"}
               },
               "req_deleted_1",
               1
             )

    assert Enum.map(w_no_resurrect.spec["starts"], & &1["slot"]) == ["lead"]

    # ── 4. R17 P1-1: drop_stale_request_id is no-op when ID absent, and preserves background backoff when deleting its own ID ──
    future_ms = SystemsClock.system_time(:millisecond) + 60_000

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_p03.id, fn cur ->
        {:ok,
         Map.put(cur.spec, "pending_secondaries", %{
           "by_slot" => %{
             "reviewer" => %{"attempts" => 2, "next_retry_at_ms" => future_ms}
           },
           "reconcile_pending" => true
         })}
      end)

    assert {:ok, w_keep1} =
             CodingSandboxes.drop_stale_request_id(w_p03.id, "reviewer", "old_absent_req")

    assert get_in(w_keep1.spec, ["pending_secondaries", "by_slot", "reviewer"]) == %{
             "attempts" => 2,
             "next_retry_at_ms" => future_ms
           }

    # Even when old_req IS present alongside independent backoff, dropping old_req keeps attempts + next_retry_at_ms!
    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_p03.id, fn cur ->
        {:ok,
         Map.put(cur.spec, "pending_secondaries", %{
           "by_slot" => %{
             "reviewer" => %{
               "attempts" => 2,
               "next_retry_at_ms" => future_ms,
               "request_ids" => ["old_present_req"],
               "request_seqs" => %{"old_present_req" => 1}
             }
           },
           "reconcile_pending" => true
         })}
      end)

    assert {:ok, w_keep2} =
             CodingSandboxes.drop_stale_request_id(w_p03.id, "reviewer", "old_present_req")

    assert get_in(w_keep2.spec, ["pending_secondaries", "by_slot", "reviewer"]) == %{
             "attempts" => 2,
             "next_retry_at_ms" => future_ms
           }
  end

  defmodule FlakyTaskSessions do
    def start_link(opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            fail_backoff: Keyword.get(opts, :fail_backoff, 0),
            fail_remove: Keyword.get(opts, :fail_remove, 0)
          }
        end,
        name: __MODULE__
      )
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil ->
          :ok

        pid ->
          try do
            Agent.stop(pid)
          catch
            :exit, _ -> :ok
          end
      end
    end

    def set_failures(opts) do
      Agent.update(__MODULE__, fn st ->
        %{
          st
          | fail_backoff: Keyword.get(opts, :fail_backoff, st.fail_backoff),
            fail_remove: Keyword.get(opts, :fail_remove, st.fail_remove)
        }
      end)
    end

    def update_pending_multi_starts_backoff(g, c, d, updates) do
      should_fail? =
        Agent.get_and_update(__MODULE__, fn st ->
          if st.fail_backoff > 0 do
            {true, %{st | fail_backoff: st.fail_backoff - 1}}
          else
            {false, st}
          end
        end)

      if should_fail? do
        {:error, :db_unavailable}
      else
        SalixStore.StationTaskSessions.update_pending_multi_starts_backoff(g, c, d, updates)
      end
    end

    def remove_pending_multi_starts(g, c, d, slots) do
      should_fail? =
        Agent.get_and_update(__MODULE__, fn st ->
          if slots != [] and st.fail_remove > 0 do
            {true, %{st | fail_remove: st.fail_remove - 1}}
          else
            {false, st}
          end
        end)

      if should_fail? do
        {:error, :db_unavailable}
      else
        SalixStore.StationTaskSessions.remove_pending_multi_starts(g, c, d, slots)
      end
    end
  end

  test "R18 P0-1/P0-2/P1-1: stale add_session_start never fakes :ok without DB binding, reconcile_invites fences stale A(1) preserving B(2), and personal station refusal guard survives DB writeback failure with 0 re-invites",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations
    )

    now_r18 = SystemsClock.system_time(:millisecond)

    make_r18_spec = fn conv_id, title, dev_id ->
      %{
        "group_id" => ctx.group,
        "conversation_id" => conv_id,
        "title" => title,
        "creator_user_id" => "usr_owner",
        "status" => "active",
        "runs_on" => %{"kind" => "device", "device_id" => dev_id},
        "worker_agent_id" => ctx.agent,
        "conversation" => %{
          "conversation_id" => conv_id,
          "group_id" => ctx.group,
          "type" => "task",
          "title" => title,
          "status" => "active",
          "created_at" => now_r18,
          "updated_at" => now_r18,
          "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => dev_id}},
          "participants" => [
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => nil,
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r18,
              "updated_at" => now_r18
            },
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => "reviewer",
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r18,
              "updated_at" => now_r18
            }
          ]
        }
      }
    end

    # ── 1. R18 P0-1 (main case): A(1) in-flight -> B(2) permanently refused (leaves starts reviewer(2) because A(1) still in req_seqs) -> A(1) returns {:ok, SA} -> MUST return {:error, :stale_slot_binding}, clean orphaned starts, deactivate participant, 0 DB reviewer rows! ──
    conv_1a = Ids.new_conversation_id()

    {:ok, w_1a} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1a,
        workspace: "ws_r18_1a",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    dev_1a = w_1a.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_1a,
               make_r18_spec.(conv_1a, "R18 P0-1a", dev_1a)
             )

    {:ok, %{"participants" => parts_1a}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_1a)

    pid_1a = Enum.find(parts_1a, &(&1["target_key"] == "reviewer"))["participant_id"]
    tr_1a = SalixStore.CodingSandboxes.transport_id(conv_1a)

    {:ok, ^tr_1a, rec_1a} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_1a,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_1a),
          "workload_id" => w_1a.id,
          "workload_generation" => w_1a.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_1a
      )

    run_1a = rec_1a["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1a,
        device_id: dev_1a,
        session: "ses_1a_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_1a}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_1a.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_1a
         })}
      end)

    calls_1a = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        n = :atomics.add_get(calls_1a, 1, 1)

        if n == 1 do
          # B(2) permanently refuses while A(1) is still in-flight (does NOT manually wipe starts!)
          assert {:error, {:station_refused, "policy denied"}} =
                   CodingSandboxes.add_session_start(ctx.tenant, conv_1a, %{
                     "slot" => "reviewer",
                     "is_primary" => false,
                     "agent_id" => ctx.agent,
                     "participant_id" => pid_1a,
                     "start" => %{"slot" => "reviewer", "is_primary" => false}
                   })

          # Now A(1) gets {:ok, SA} from station!
          {:ok, %{"session" => "SA_1a", "slot" => "reviewer"}}
        else
          {:error, "policy denied"}
        end
      else
        {:ok, %{"session" => "ses_1a_lead", "slot" => "lead"}}
      end
    end)

    assert {:error, :stale_slot_binding} =
             CodingSandboxes.add_session_start(ctx.tenant, conv_1a, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_1a,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    {:ok, db_1a} = StationTaskSessions.of_task(ctx.group, conv_1a)
    assert Enum.map(db_1a, & &1.session) == ["ses_1a_lead"]

    {:ok, w_1a_end} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_1a)
    assert Enum.map(w_1a_end.spec["starts"], & &1["slot"]) == ["lead"]
    assert w_1a_end.spec["pending_secondaries"] == nil
    assert get_in(w_1a_end.spec, ["slot_seq_hwm", "reviewer"]) == 2

    {:ok, %{"participants" => parts_1a_end}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_1a)

    assert Enum.find(parts_1a_end, &(&1["participant_id"] == pid_1a))["state"] == "inactive"

    # ── 1b. R18 P0-1 (control case): A(1) in-flight -> B(2) binds SB in DB -> A(1) hits stale -> returns :ok and DB/Actor keep SB! ──
    conv_1b = Ids.new_conversation_id()

    {:ok, w_1b} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1b,
        workspace: "ws_r18_1b",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    dev_1b = w_1b.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_1b,
               make_r18_spec.(conv_1b, "R18 P0-1b", dev_1b)
             )

    {:ok, %{"participants" => parts_1b}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_1b)

    pid_1b = Enum.find(parts_1b, &(&1["target_key"] == "reviewer"))["participant_id"]
    tr_1b = SalixStore.CodingSandboxes.transport_id(conv_1b)

    {:ok, ^tr_1b, rec_1b} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_1b,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_1b),
          "workload_id" => w_1b.id,
          "workload_generation" => w_1b.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_1b
      )

    run_1b = rec_1b["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1b,
        device_id: dev_1b,
        session: "ses_1b_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_1b}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_1b.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_1b
         })}
      end)

    calls_1b = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        n = :atomics.add_get(calls_1b, 1, 1)

        if n == 1 do
          assert :ok =
                   CodingSandboxes.add_session_start(ctx.tenant, conv_1b, %{
                     "slot" => "reviewer",
                     "is_primary" => false,
                     "agent_id" => ctx.agent,
                     "participant_id" => pid_1b,
                     "start" => %{"slot" => "reviewer", "is_primary" => false}
                   })

          {:ok, %{"session" => "SA_1b", "slot" => "reviewer"}}
        else
          {:ok, %{"session" => "SB_1b", "slot" => "reviewer"}}
        end
      else
        {:ok, %{"session" => "ses_1b_lead", "slot" => "lead"}}
      end
    end)

    assert :ok =
             CodingSandboxes.add_session_start(ctx.tenant, conv_1b, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_1b,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    {:ok, db_1b} = StationTaskSessions.of_task(ctx.group, conv_1b)
    assert Enum.find(db_1b, &(get_in(&1.start, ["slot"]) == "reviewer")).session == "SB_1b"

    {:ok, %{"participants" => parts_1b_end}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_1b)

    actor_1b = Enum.find(parts_1b_end, &(&1["participant_id"] == pid_1b))
    assert actor_1b["state"] == "active"
    assert String.starts_with?(get_in(actor_1b, ["payload", "bound_token"]) || "", "SB_1b@")

    # ── 2. R18 P0-2: A(1) online timeout -> background reconcile_invites starts A(1) -> B(2) online timeout leaves reqB in pending -> background receives SA(1) -> blocked by pre_join_check, preserves B(2) in pending_secondaries, next reconcile binds SB(2)! ──
    conv_2 = Ids.new_conversation_id()

    {:ok, w_2} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2,
        workspace: "ws_r18_2",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    dev_2 = w_2.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_2,
               make_r18_spec.(conv_2, "R18 P0-2", dev_2)
             )

    {:ok, %{"participants" => parts_2}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_2)

    pid_2 = Enum.find(parts_2, &(&1["target_key"] == "reviewer"))["participant_id"]
    tr_2 = SalixStore.CodingSandboxes.transport_id(conv_2)

    {:ok, ^tr_2, rec_2} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_2,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_2),
          "workload_id" => w_2.id,
          "workload_generation" => w_2.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_2
      )

    run_2 = rec_2["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2,
        device_id: dev_2,
        session: "ses_2_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_2}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_2.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_2
         })}
      end)

    # Step 1: A(1) online timeout
    FakeConnector.on("task.invite", fn _ -> {:error, :timeout} end)

    assert {:error, {:station_invite_unknown, :timeout}} =
             CodingSandboxes.add_session_start(ctx.tenant, conv_2, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_2,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    {:ok, w_2_snap1} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_2)

    # Step 2: Background reconcile_invites starts on snapshot (seq=1); mid-invite, B(2) online timeout arrives!
    rec_calls_2 = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        n = :atomics.add_get(rec_calls_2, 1, 1)

        if n == 1 do
          assert {:error, {:station_invite_unknown, :timeout}} =
                   CodingSandboxes.add_session_start(ctx.tenant, conv_2, %{
                     "slot" => "reviewer",
                     "is_primary" => false,
                     "agent_id" => ctx.agent,
                     "participant_id" => pid_2,
                     "start" => %{"slot" => "reviewer", "is_primary" => false}
                   })

          # Background receives stale A(1) success!
          {:ok, %{"session" => "SA_2_stale", "slot" => "reviewer"}}
        else
          {:error, :timeout}
        end
      else
        {:ok, %{"session" => "ses_2_lead", "slot" => "lead"}}
      end
    end)

    {:ok, _} = CodingSandboxes.reconcile_invites(w_2_snap1)

    # Verify SA_2_stale was NOT written to DB or Actor, and B(2) is still preserved in starts & pending!
    {:ok, db_2_mid} = StationTaskSessions.of_task(ctx.group, conv_2)
    assert Enum.map(db_2_mid, & &1.session) == ["ses_2_lead"]

    {:ok, %{"participants" => parts_2_mid}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_2)

    assert get_in(
             Enum.find(parts_2_mid, &(&1["participant_id"] == pid_2)),
             ["payload", "bound_token"]
           ) == nil

    {:ok, w_2_mid} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_2)
    rev_2_mid = Enum.find(w_2_mid.spec["starts"], &(&1["slot"] == "reviewer"))
    assert rev_2_mid["start_seq"] == 2

    req_seqs_2_mid =
      get_in(w_2_mid.spec, ["pending_secondaries", "by_slot", "reviewer", "request_seqs"])

    assert is_map(req_seqs_2_mid) and map_size(req_seqs_2_mid) == 1
    assert Map.values(req_seqs_2_mid) == [2]

    # Step 3: Next reconcile_invites binds B(2) cleanly!
    FakeConnector.on("task.invite", fn params ->
      {:ok, %{"session" => "SB_2_live", "slot" => params["slot"]}}
    end)

    {:ok, _} = CodingSandboxes.reconcile_invites(w_2_mid)

    {:ok, db_2_end} = StationTaskSessions.of_task(ctx.group, conv_2)
    sb_2 = Enum.find(db_2_end, &(get_in(&1.start, ["slot"]) == "reviewer"))
    assert sb_2 != nil
    assert sb_2.session == "SB_2_live"
    assert sb_2.start["start_seq"] == 2

    # ── 3. R18 P1-1: Personal station refusal guard survives DB writeback failure (both online backoff failure & background remove failure) with STRICTLY 0 re-invites, and new participant_id on same slot is NOT blocked! ──
    fail_ctr_3 = :atomics.new(1, [])
    {:ok, _} = FlakyUnboundConversations.start_link(fail_ctr_3)
    {:ok, _} = FlakyTaskSessions.start_link(fail_backoff: 1, fail_remove: 1)

    on_exit(fn ->
      FlakyUnboundConversations.stop()
      FlakyTaskSessions.stop()
    end)

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FlakyUnboundConversations,
      task_sessions: FlakyTaskSessions
    )

    conv_3 = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_3,
               make_r18_spec.(conv_3, "R18 P1-1", ctx.device)
             )

    {:ok, %{"participants" => parts_3}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_3)

    pid_3 = Enum.find(parts_3, &(&1["target_key"] == "reviewer"))["participant_id"]
    run_3 = register_device(ctx, "r18_p1", %{"tasks" => 2, "multi_session_tasks" => true})

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_3,
        device_id: ctx.device,
        session: "ses_3_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_3}
      })

    invite_calls_3 = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        n = :atomics.add_get(invite_calls_3, 1, 1)

        if n == 1 do
          {:error, "policy denied"}
        else
          {:ok, %{"session" => "ses_3_must_never_reinvite", "slot" => "reviewer"}}
        end
      else
        {:ok, %{"session" => "ses_3_lead", "slot" => "lead"}}
      end
    end)

    FakeConnector.on("task.put", fn _ -> {:ok, %{"through" => 0}} end)

    # Online permanent refusal: BOTH deactivate_dropped_slot (fail_ctr_3==1) AND
    # update_pending_multi_starts_backoff (fail_backoff==1) fail!
    # Then when giver runs, remove_pending_multi_starts ALSO fails once (fail_remove==1)!
    assert {:error, {:station_refused, "policy denied"}} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_3,
               device_id: ctx.device,
               agent_id: ctx.agent,
               participant_id: pid_3,
               slot: "reviewer",
               start: %{"slot" => "reviewer", "is_primary" => false}
             })

    # Advance SystemsClock so giver retries after backoff failure & remove failure ->
    # finishes deactivation and clears pending with STRICTLY 0 extra task.invite RPCs!
    SystemsClock.advance(30_000)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_3) do
        {:ok, [row]} -> List.wrap(row.start["pending_multi_starts"]) == []
        _ -> false
      end
    end)

    assert :atomics.get(invite_calls_3, 1) == 1

    {:ok, %{"participants" => parts_3_end}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_3)

    assert Enum.find(parts_3_end, &(&1["participant_id"] == pid_3))["state"] == "inactive"

    # Control: adding a NEW participant_id on the SAME slot "reviewer" is NOT blocked by old guard!
    {:ok, new_rev_3} =
      ConversationServer.ensure_group_conversation_agent_participant(ctx.group, conv_3, %{
        "agent_id" => ctx.agent,
        "role_label" => "worker",
        "target_key" => "reviewer",
        "payload" => %{"session_id" => Ids.new_session_id()}
      })

    new_pid_3 = new_rev_3["participant_id"]

    FakeConnector.on("task.invite", fn params ->
      {:ok, %{"session" => "ses_3_new_rev", "slot" => params["slot"]}}
    end)

    assert :ok =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_3,
               device_id: ctx.device,
               agent_id: ctx.agent,
               participant_id: new_pid_3,
               slot: "reviewer",
               start: %{"slot" => "reviewer", "is_primary" => false}
             })

    {:ok, db_3_new} = StationTaskSessions.of_task(ctx.group, conv_3)
    assert Enum.any?(db_3_new, &(&1.session == "ses_3_new_rev"))
  end

  test "R19 P0-1/P1-3/P1-4: old DB binding SA(1) never satisfies B(2), sandbox pending_deactivation recovers via periodic reconcile, and personal station invite_id survives ETS wipe across restart",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations
    )

    now_r19 = SystemsClock.system_time(:millisecond)

    make_r19_spec = fn conv_id, title, dev_id ->
      %{
        "group_id" => ctx.group,
        "conversation_id" => conv_id,
        "title" => title,
        "creator_user_id" => "usr_owner",
        "status" => "active",
        "runs_on" => %{"kind" => "device", "device_id" => dev_id},
        "worker_agent_id" => ctx.agent,
        "conversation" => %{
          "conversation_id" => conv_id,
          "group_id" => ctx.group,
          "type" => "task",
          "title" => title,
          "status" => "active",
          "created_at" => now_r19,
          "updated_at" => now_r19,
          "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => dev_id}},
          "participants" => [
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => nil,
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r19,
              "updated_at" => now_r19
            },
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => "reviewer",
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r19,
              "updated_at" => now_r19
            }
          ]
        }
      }
    end

    # ── Test 1 (R19 P0-1): DB already has SA(1); online B(2) is in-flight -> reconcile_invites MUST NOT
    # confirm seq=2 or clear B(2)'s request_id using old SA(1), and B(2) hitting stale MUST NOT fake :ok from SA(1)! ──
    conv_t1 = Ids.new_conversation_id()

    {:ok, w_t1} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_t1,
        workspace: "ws_r19_t1",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start_seq" => 1,
            "start" => %{"slot" => "reviewer", "is_primary" => false}
          }
        ]
      })

    dev_t1 = w_t1.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_t1,
               make_r19_spec.(conv_t1, "R19 T1", dev_t1)
             )

    {:ok, %{"participants" => parts_t1}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_t1)

    pid_t1 = Enum.find(parts_t1, &(&1["target_key"] == "reviewer"))["participant_id"]
    tr_t1 = SalixStore.CodingSandboxes.transport_id(conv_t1)

    {:ok, ^tr_t1, rec_t1} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_t1,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_t1),
          "workload_id" => w_t1.id,
          "workload_generation" => w_t1.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_t1
      )

    run_t1 = rec_t1["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_t1,
        device_id: dev_t1,
        session: "ses_t1_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_t1}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_t1,
        device_id: dev_t1,
        session: "SA_t1_1",
        agent_id: ctx.agent,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "connector_run_id" => run_t1,
          "binding_token" => "tok_sa_t1_1",
          "start_seq" => 1
        }
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_t1.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_t1,
           "slot_seq_hwm" => %{"reviewer" => 1},
           "slot_confirmed_seq" => %{"reviewer" => 1}
         })}
      end)

    t1_calls = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        n = :atomics.add_get(t1_calls, 1, 1)

        if n == 1 do
          # While online B(2) is in-flight, background reconcile_invites runs and sees old SA(1) in DB.
          # During reconcile_invites, station returns :timeout for reviewer (proving reconcile did NOT short-circuit on SA(1)!).
          {:ok, w_mid} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_t1)
          {:ok, _} = CodingSandboxes.reconcile_invites(w_mid)

          {:ok, w_after_rec} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_t1)

          # slot_confirmed_seq MUST still be 1 (NOT 2), and B(2)'s request_id MUST still be present!
          assert get_in(w_after_rec.spec, ["slot_confirmed_seq", "reviewer"]) == 1

          req_seqs =
            get_in(w_after_rec.spec, [
              "pending_secondaries",
              "by_slot",
              "reviewer",
              "request_seqs"
            ])

          assert is_map(req_seqs) and Map.values(req_seqs) == [2]

          # Now B(2) completes cleanly and binds SB_t1_2 (seq=2)!
          {:ok, %{"session" => "SB_t1_2", "slot" => "reviewer"}}
        else
          {:error, :timeout}
        end
      else
        {:ok, %{"session" => "ses_t1_lead", "slot" => "lead"}}
      end
    end)

    assert :ok =
             CodingSandboxes.add_session_start(ctx.tenant, conv_t1, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_t1,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    {:ok, db_t1_end} = StationTaskSessions.of_task(ctx.group, conv_t1)
    rev_t1_end = Enum.find(db_t1_end, &(get_in(&1.start, ["slot"]) == "reviewer"))
    assert rev_t1_end.session == "SB_t1_2"
    assert rev_t1_end.start["start_seq"] == 2

    # ── Test 3 (R19 P1-3): Sandbox B(2) permanently refused + A(1) arrives late + deactivation fails once ->
    # persists pending_deactivation: true & reconcile_pending: true (anchor NOT dropped!) ->
    # periodic reconcile_invites completes deactivation with 0 re-invites and cleans starts + pending! ──
    fail_ctr_t3 = :atomics.new(1, [])
    {:ok, _} = FlakyUnboundConversations.start_link(fail_ctr_t3)
    on_exit(fn -> FlakyUnboundConversations.stop() end)

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FlakyUnboundConversations
    )

    conv_t3 = Ids.new_conversation_id()

    {:ok, w_t3} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_t3,
        workspace: "ws_r19_t3",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    dev_t3 = w_t3.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_t3,
               make_r19_spec.(conv_t3, "R19 T3", dev_t3)
             )

    {:ok, %{"participants" => parts_t3}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_t3)

    pid_t3 = Enum.find(parts_t3, &(&1["target_key"] == "reviewer"))["participant_id"]
    tr_t3 = SalixStore.CodingSandboxes.transport_id(conv_t3)

    {:ok, ^tr_t3, rec_t3} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_t3,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_t3),
          "workload_id" => w_t3.id,
          "workload_generation" => w_t3.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_t3
      )

    run_t3 = rec_t3["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_t3,
        device_id: dev_t3,
        session: "ses_t3_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_t3}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_t3.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_t3
         })}
      end)

    t3_calls = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        n = :atomics.add_get(t3_calls, 1, 1)

        if n == 1 do
          assert {:error, {:station_refused, "policy denied"}} =
                   CodingSandboxes.add_session_start(ctx.tenant, conv_t3, %{
                     "slot" => "reviewer",
                     "is_primary" => false,
                     "agent_id" => ctx.agent,
                     "participant_id" => pid_t3,
                     "start" => %{"slot" => "reviewer", "is_primary" => false}
                   })

          {:ok, %{"session" => "SA_t3_late", "slot" => "reviewer"}}
        else
          {:error, "policy denied"}
        end
      else
        {:ok, %{"session" => "ses_t3_lead", "slot" => "lead"}}
      end
    end)

    # First deactivation attempt inside stale cleanup fails (fail_ctr_t3 == 1 -> :binding_state_unavailable)
    assert {:error, :stale_slot_binding} =
             CodingSandboxes.add_session_start(ctx.tenant, conv_t3, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_t3,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    {:ok, w_t3_mid} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_t3)

    assert get_in(w_t3_mid.spec, [
             "pending_secondaries",
             "by_slot",
             "reviewer",
             "pending_deactivation"
           ]) == true

    assert get_in(w_t3_mid.spec, ["pending_secondaries", "reconcile_pending"]) == true

    {:ok, %{"participants" => parts_t3_mid}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_t3)

    assert Enum.find(parts_t3_mid, &(&1["participant_id"] == pid_t3))["state"] == "active"

    # Advance clock past backoff and run periodic reconcile_invites -> 0 extra task.invite RPCs,
    # deactivates participant, and cleans starts + pending_secondaries!
    calls_before_rec = :atomics.get(t3_calls, 1)
    SystemsClock.advance(35_000)
    {:ok, _} = CodingSandboxes.reconcile_invites(w_t3_mid)

    assert :atomics.get(t3_calls, 1) == calls_before_rec

    {:ok, w_t3_end} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_t3)
    assert Enum.map(w_t3_end.spec["starts"], & &1["slot"]) == ["lead"]
    assert w_t3_end.spec["pending_secondaries"] == nil

    {:ok, %{"participants" => parts_t3_end}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_t3)

    assert Enum.find(parts_t3_end, &(&1["participant_id"] == pid_t3))["state"] == "inactive"

    # ── Test 4 (R19 P1-4 Elixir): Personal station online permanent refusal + deactivation failure +
    # backoff DB write failure + simulated node restart wiping ETS -> giver replays SAME persisted
    # invite_id -> Station replays refusal -> 0 new sessions registered, participant deactivated, pending cleared! ──
    FlakyUnboundConversations.stop()
    fail_ctr_t4 = :atomics.new(1, [])
    {:ok, _} = FlakyUnboundConversations.start_link(fail_ctr_t4)
    {:ok, _} = FlakyTaskSessions.start_link(fail_backoff: 1, fail_remove: 0)
    on_exit(fn -> FlakyTaskSessions.stop() end)

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FlakyUnboundConversations,
      task_sessions: FlakyTaskSessions
    )

    conv_t4 = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_t4,
               make_r19_spec.(conv_t4, "R19 T4", ctx.device)
             )

    {:ok, %{"participants" => parts_t4}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_t4)

    pid_t4 = Enum.find(parts_t4, &(&1["target_key"] == "reviewer"))["participant_id"]
    run_t4 = register_device(ctx, "r19_t4", %{"tasks" => 2, "multi_session_tasks" => true})

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_t4,
        device_id: ctx.device,
        session: "ses_t4_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_t4}
      })

    # Station mock records refused invite_ids (modeling Station SQLite `task_invite_decisions`)
    {:ok, refused_ids_agent} = Agent.start_link(fn -> MapSet.new() end)
    on_exit(fn -> if Process.alive?(refused_ids_agent), do: Agent.stop(refused_ids_agent) end)

    t4_calls = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        inv_id = params["invite_id"]
        assert is_binary(inv_id) and inv_id != ""
        n = :atomics.add_get(t4_calls, 1, 1)

        already_refused? = Agent.get(refused_ids_agent, &MapSet.member?(&1, inv_id))

        cond do
          already_refused? ->
            # Station replays persisted refusal by invite_id!
            {:error, "policy denied"}

          n == 1 ->
            Agent.update(refused_ids_agent, &MapSet.put(&1, inv_id))
            {:error, "policy denied"}

          true ->
            {:ok, %{"session" => "ses_t4_must_never_bind", "slot" => "reviewer"}}
        end
      else
        {:ok, %{"session" => "ses_t4_lead", "slot" => "lead"}}
      end
    end)

    FakeConnector.on("task.put", fn _ -> {:ok, %{"through" => 0}} end)

    assert {:error, {:station_refused, "policy denied"}} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_t4,
               device_id: ctx.device,
               agent_id: ctx.agent,
               participant_id: pid_t4,
               slot: "reviewer",
               start: %{"slot" => "reviewer", "is_primary" => false}
             })

    # Simulate node restart wiping the in-memory ETS refusal guard!
    StationTasks.reset_refusal_guard_for_test()
    StationTasks.give(ctx.group, conv_t4, ctx.device)
    SystemsClock.advance(30_000)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_t4) do
        {:ok, [row]} -> List.wrap(row.start["pending_multi_starts"]) == []
        _ -> false
      end
    end)

    # 0 new sessions registered in DB, participant deactivated, pending cleared!
    {:ok, db_t4_end} = StationTaskSessions.of_task(ctx.group, conv_t4)
    assert Enum.map(db_t4_end, & &1.session) == ["ses_t4_lead"]

    {:ok, %{"participants" => parts_t4_end}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_t4)

    assert Enum.find(parts_t4_end, &(&1["participant_id"] == pid_t4))["state"] == "inactive"
  end

  test "R20 P0-1/P0-3/P1-1/P1-2/P1-3: background refusal min_seq check, superseded pending_deactivation guard protects C(3), atomic stale transition preserves anchor, same invite_id reused, and SQLITE_BUSY/outdated persist failure handled",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations
    )

    now_r20 = SystemsClock.system_time(:millisecond)

    make_r20_spec = fn conv_id, title, dev_id ->
      %{
        "group_id" => ctx.group,
        "conversation_id" => conv_id,
        "title" => title,
        "creator_user_id" => "usr_owner",
        "status" => "active",
        "runs_on" => %{"kind" => "device", "device_id" => dev_id},
        "worker_agent_id" => ctx.agent,
        "conversation" => %{
          "conversation_id" => conv_id,
          "group_id" => ctx.group,
          "type" => "task",
          "title" => title,
          "status" => "active",
          "created_at" => now_r20,
          "updated_at" => now_r20,
          "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => dev_id}},
          "participants" => [
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => nil,
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r20,
              "updated_at" => now_r20
            },
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => "reviewer",
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r20,
              "updated_at" => now_r20
            }
          ]
        }
      }
    end

    # ── 1. R20 P0-1: DB has SA(1), B(2) in-flight -> background reconcile_invites gets permanent refusal
    # (:station_refused) -> Actor returns :already_bound (for SA(1)), min_seq=2 rejects SA(1) so
    # slot_confirmed_seq stays 1, B(2) pending is KEPT, and real SB(2) later replaces SA(1)! ──
    conv_p01 = Ids.new_conversation_id()

    {:ok, w_p01} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p01,
        workspace: "ws_r20_p01",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start_seq" => 1,
            "start" => %{"slot" => "reviewer", "is_primary" => false}
          }
        ]
      })

    dev_p01 = w_p01.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_p01,
               make_r20_spec.(conv_p01, "R20 P0-1", dev_p01)
             )

    {:ok, %{"participants" => parts_p01}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p01)

    pid_p01 = Enum.find(parts_p01, &(&1["target_key"] == "reviewer"))["participant_id"]
    tr_p01 = SalixStore.CodingSandboxes.transport_id(conv_p01)

    {:ok, ^tr_p01, rec_p01} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_p01,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_p01),
          "workload_id" => w_p01.id,
          "workload_generation" => w_p01.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_p01
      )

    run_p01 = rec_p01["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p01,
        device_id: dev_p01,
        session: "ses_r20_p01_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_p01}
      })

    assert :ok =
             StationTasks.register_slot_binding(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_p01,
               device_id: dev_p01,
               session: "SA_r20_1",
               agent_id: ctx.agent,
               participant_id: pid_p01,
               give: false,
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "connector_run_id" => run_p01,
                 "start_seq" => 1
               }
             })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_p01.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_p01,
           "slot_seq_hwm" => %{"reviewer" => 1},
           "slot_confirmed_seq" => %{"reviewer" => 1}
         })}
      end)

    p01_calls = :atomics.new(1, [])

    FakeConnector.on("task.invite", fn params ->
      if params["slot"] == "reviewer" do
        n = :atomics.add_get(p01_calls, 1, 1)

        if n == 1 do
          # While B(2) is in-flight, background reconcile_invites hits permanent refusal;
          # Actor sees SA_r20_1 (:already_bound), but min_seq=2 MUST NOT mark B(2) succeeded!
          {:ok, w_mid} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_p01)
          {:ok, _} = CodingSandboxes.reconcile_invites(w_mid)

          {:ok, w_after_ref} =
            SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_p01)

          assert get_in(w_after_ref.spec, ["slot_confirmed_seq", "reviewer"]) == 1

          assert get_in(w_after_ref.spec, [
                   "pending_secondaries",
                   "by_slot",
                   "reviewer",
                   "request_seqs"
                 ]) != nil

          {:ok, %{"session" => "SB_r20_2", "slot" => "reviewer"}}
        else
          {:error, "policy denied"}
        end
      else
        {:ok, %{"session" => "ses_r20_p01_lead", "slot" => "lead"}}
      end
    end)

    assert :ok =
             CodingSandboxes.add_session_start(ctx.tenant, conv_p01, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_p01,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    {:ok, db_p01_end} = StationTaskSessions.of_task(ctx.group, conv_p01)
    rev_p01_end = Enum.find(db_p01_end, &(get_in(&1.start, ["slot"]) == "reviewer"))
    assert rev_p01_end.session == "SB_r20_2"
    assert rev_p01_end.start["start_seq"] == 2

    # ── 2. R20 P0-3: Stale pending_deactivation snapshot for B(2) MUST NOT deactivate C(3)'s participant! ──
    conv_p03 = Ids.new_conversation_id()

    {:ok, w_p03} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p03,
        workspace: "ws_r20_p03",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start_seq" => 2,
            "start" => %{"slot" => "reviewer", "is_primary" => false}
          }
        ]
      })

    dev_p03 = w_p03.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_p03,
               make_r20_spec.(conv_p03, "R20 P0-3", dev_p03)
             )

    {:ok, %{"participants" => parts_p03}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p03)

    pid_p03 = Enum.find(parts_p03, &(&1["target_key"] == "reviewer"))["participant_id"]
    tr_p03 = SalixStore.CodingSandboxes.transport_id(conv_p03)

    {:ok, ^tr_p03, rec_p03} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_p03,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_p03),
          "workload_id" => w_p03.id,
          "workload_generation" => w_p03.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_p03
      )

    run_p03 = rec_p03["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p03,
        device_id: dev_p03,
        session: "ses_r20_p03_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_p03}
      })

    # Snapshot with B(2) pending_deactivation: true
    {:ok, w_p03_stale_snap} =
      SalixStore.CodingSandboxes.update(w_p03.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_p03,
           "slot_seq_hwm" => %{"reviewer" => 2},
           "pending_secondaries" => %{
             "by_slot" => %{
               "reviewer" => %{
                 "pending_deactivation" => true,
                 "deactivation_seq" => 2,
                 "participant_id" => pid_p03,
                 "attempts" => 1
               }
             },
             "reconcile_pending" => true
           }
         })}
      end)

    # Now C(3) arrives for the SAME participant_id and times out (clearing pending_deactivation, seq=3, DB still 0 reviewer rows)
    FakeConnector.on("task.invite", fn _ -> {:error, :timeout} end)

    assert {:error, {:station_invite_unknown, :timeout}} =
             CodingSandboxes.add_session_start(ctx.tenant, conv_p03, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_p03,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    # Run stale B(2) pending_deactivation snapshot -> P0-3 guard inside Actor+device lock returns :superseded!
    {:ok, _} = CodingSandboxes.reconcile_invites(w_p03_stale_snap)

    # C(3)'s participant MUST remain active and C(3)'s request_id MUST remain intact!
    {:ok, %{"participants" => parts_p03_end}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p03)

    assert Enum.find(parts_p03_end, &(&1["participant_id"] == pid_p03))["state"] == "active"

    {:ok, w_p03_end} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_p03)

    req_seqs_p03 =
      get_in(w_p03_end.spec, ["pending_secondaries", "by_slot", "reviewer", "request_seqs"])

    assert is_map(req_seqs_p03) and Map.values(req_seqs_p03) == [3]

    # ── 3. R20 P1-3 (Elixir): permanent_slot_refusal? treats SQLITE_BUSY/persist failure as transient,
    # and local :station_outdated returns {:error, :binding_state_unavailable} when backoff persist fails! ──
    refute StationTasks.permanent_slot_refusal?(
             {:station_refused, "SQLITE_BUSY: failed to persist invite decision: locked"}
           )

    refute StationTasks.permanent_slot_refusal?({:station_refused, "SQLITE_LOCKED: table locked"})
    assert StationTasks.permanent_slot_refusal?({:station_refused, "policy denied"})
    assert StationTasks.permanent_slot_refusal?(:station_outdated)

    fail_ctr_p13 = :atomics.new(1, [])
    {:ok, _} = FlakyUnboundConversations.start_link(fail_ctr_p13)
    {:ok, _} = FlakyTaskSessions.start_link(fail_backoff: 1, fail_remove: 0)

    on_exit(fn ->
      FlakyUnboundConversations.stop()
      FlakyTaskSessions.stop()
    end)

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FlakyUnboundConversations,
      task_sessions: FlakyTaskSessions
    )

    conv_p13 = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_p13,
               make_r20_spec.(conv_p13, "R20 P1-3", ctx.device)
             )

    {:ok, %{"participants" => parts_p13}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_p13)

    pid_p13 = Enum.find(parts_p13, &(&1["target_key"] == "reviewer"))["participant_id"]

    # Register legacy station WITHOUT multi_session_tasks capability so local precheck returns :station_outdated!
    run_p13 = register_device(ctx, "r20_p13_old", %{"tasks" => 2})

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p13,
        device_id: ctx.device,
        session: "ses_r20_p13_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_p13}
      })

    # Deactivation fails (fail_ctr_p13==1) AND backoff persist fails (fail_backoff==1) ->
    # MUST return {:error, :binding_state_unavailable} instead of settled :station_outdated!
    assert {:error, :binding_state_unavailable} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_p13,
               device_id: ctx.device,
               agent_id: ctx.agent,
               participant_id: pid_p13,
               slot: "reviewer",
               start: %{"slot" => "reviewer", "is_primary" => false}
             })
  end

  test "R21 P0-1/P0-3/P1-1/P1-2: Actor-serialized reserve_station_session, outer station_outdated superseded guard, RPC station_transient boundary, pending param mismatch guard, and station_outdated giver wakeup",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations
    )

    now_r21 = SystemsClock.system_time(:millisecond)

    make_r21_spec = fn conv_id, title, dev_id ->
      %{
        "group_id" => ctx.group,
        "conversation_id" => conv_id,
        "title" => title,
        "creator_user_id" => "usr_owner",
        "status" => "active",
        "runs_on" => %{"kind" => "device", "device_id" => dev_id},
        "worker_agent_id" => ctx.agent,
        "conversation" => %{
          "conversation_id" => conv_id,
          "group_id" => ctx.group,
          "type" => "task",
          "title" => title,
          "status" => "active",
          "created_at" => now_r21,
          "updated_at" => now_r21,
          "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => dev_id}},
          "participants" => [
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => nil,
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r21,
              "updated_at" => now_r21
            },
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => "reviewer",
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r21,
              "updated_at" => now_r21
            }
          ]
        }
      }
    end

    # ── 1. R21 P0-1 (a): Inactive participant rejected by reserve_task_participant_session BEFORE allocating seq! ──
    conv_1a = Ids.new_conversation_id()

    {:ok, w_1a} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1a,
        workspace: "ws_r21_1a",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    dev_1a = w_1a.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_1a,
               make_r21_spec.(conv_1a, "R21 P0-1a", dev_1a)
             )

    {:ok, %{"participants" => parts_1a}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_1a)

    pid_1a = Enum.find(parts_1a, &(&1["target_key"] == "reviewer"))["participant_id"]
    tr_1a = SalixStore.CodingSandboxes.transport_id(conv_1a)

    {:ok, ^tr_1a, rec_1a} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_1a,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_1a),
          "workload_id" => w_1a.id,
          "workload_generation" => w_1a.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_1a
      )

    run_1a = rec_1a["connector_run_id"]

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_1a.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_1a
         })}
      end)

    # Deactivate pid_1a first -> add_session_start for pid_1a MUST fail with :participant_inactive
    # and allocate 0 start_seq / 0 starts!
    assert {:ok, _} =
             ConversationServer.deactivate_group_conversation_participant(
               ctx.group,
               conv_1a,
               pid_1a
             )

    assert {:error, :participant_inactive} =
             CodingSandboxes.add_session_start(ctx.tenant, conv_1a, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_1a,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    {:ok, w_1a_end} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_1a)
    assert Enum.map(w_1a_end.spec["starts"], & &1["slot"]) == ["lead"]
    assert w_1a_end.spec["pending_secondaries"] == nil

    # ── 2. R21 P0-1 (b): Outer :station_outdated reconcile with stale snapshot (seq=2) after C(3)
    # reserved MUST NOT deactivate C(3)'s participant or drop C(3)'s starts! ──
    conv_1b = Ids.new_conversation_id()

    {:ok, w_1b} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1b,
        workspace: "ws_r21_1b",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start_seq" => 2,
            "start" => %{"slot" => "reviewer", "is_primary" => false}
          }
        ]
      })

    dev_1b = w_1b.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_1b,
               make_r21_spec.(conv_1b, "R21 P0-1b", dev_1b)
             )

    {:ok, %{"participants" => parts_1b}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_1b)

    pid_1b = Enum.find(parts_1b, &(&1["target_key"] == "reviewer"))["participant_id"]
    tr_1b = SalixStore.CodingSandboxes.transport_id(conv_1b)

    # First connect WITH multi_session_tasks so C(3) can reserve seq=3
    {:ok, ^tr_1b, rec_1b} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_1b,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_1b),
          "workload_id" => w_1b.id,
          "workload_generation" => w_1b.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_1b
      )

    run_1b = rec_1b["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1b,
        device_id: dev_1b,
        session: "ses_r21_1b_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_1b}
      })

    {:ok, w_1b_stale_snap} =
      SalixStore.CodingSandboxes.update(w_1b.id, fn cur ->
        starts_with_pid =
          Enum.map(cur.spec["starts"], fn e ->
            if e["slot"] == "reviewer", do: Map.put(e, "participant_id", pid_1b), else: e
          end)

        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => true,
           "connector_run_id" => run_1b,
           "starts" => starts_with_pid,
           "slot_seq_hwm" => %{"reviewer" => 2}
         })}
      end)

    # C(3) reserves seq=3 and times out
    FakeConnector.on("task.invite", fn _ -> {:error, :timeout} end)

    assert {:error, {:station_invite_unknown, :timeout}} =
             CodingSandboxes.add_session_start(ctx.tenant, conv_1b, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_1b,
               "start" => %{"slot" => "reviewer", "is_primary" => false}
             })

    # Reconnect sandbox WITHOUT multi_session_tasks so outer reconcile_invites hits :station_outdated
    {:ok, ^tr_1b, _} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_1b,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_1b),
          "workload_id" => w_1b.id,
          "workload_generation" => w_1b.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2}
        },
        transport_id: tr_1b
      )

    # Run stale seq=2 snapshot through outer :station_outdated -> P0-1 guard sees live_seq(3) > 2
    # and returns :superseded: C(3)'s participant MUST remain active and starts MUST keep reviewer(3)!
    _ = CodingSandboxes.reconcile_invites(w_1b_stale_snap)

    {:ok, %{"participants" => parts_1b_end}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_1b)

    assert Enum.find(parts_1b_end, &(&1["participant_id"] == pid_1b))["state"] == "active"

    {:ok, w_1b_end} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_1b)
    assert Enum.find(w_1b_end.spec["starts"], &(&1["slot"] == "reviewer"))["start_seq"] == 3

    # ── 3. R21 P0-3: RPC boundary converts SQLITE_BUSY/failed to persist into {:station_transient, _}
    # so Sandbox & personal station keep pending and never treat it as permanent refusal! ──
    run_p03 = register_device(ctx, "r21_p03", %{"tasks" => 2, "multi_session_tasks" => true})

    FakeConnector.on("task.invite", fn _ ->
      {:error, "SQLITE_BUSY: failed to persist invite decision: database is locked"}
    end)

    assert {:error, {:station_transient, msg}} =
             StationTasks.invite_with_run(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: Ids.new_conversation_id(),
               device_id: ctx.device,
               start: %{"requester" => "u1", "slot" => "reviewer"},
               slot: "reviewer",
               join: true,
               multi_session: true
             })

    assert String.contains?(msg, "SQLITE_BUSY")

    # ── 4. R21 P1-1: Same slot pending with M1 -> calling with different M2 returns
    # {:error, {:slot_already_pending, _}} with 0 RPCs; calling with same M1 reuses (A, M1)! ──
    conv_p11 = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_p11,
               make_r21_spec.(conv_p11, "R21 P1-1", ctx.device)
             )

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_p11,
        device_id: ctx.device,
        session: "ses_r21_p11_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_p03}
      })

    p11_invites = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(p11_invites), do: Agent.stop(p11_invites) end)

    FakeConnector.on("task.put", fn _params ->
      {:ok, %{"ok" => true, "present" => ["ses_r21_p11_lead"]}}
    end)

    FakeConnector.on("task.invite", fn params ->
      Agent.update(p11_invites, &[params | &1])
      {:error, :timeout}
    end)

    m1_start = %{"slot" => "reviewer", "is_primary" => false, "model" => "m1"}
    m2_start = %{"slot" => "reviewer", "is_primary" => false, "model" => "m2"}

    assert {:error, {:station_invite_unknown, :timeout}} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_p11,
               device_id: ctx.device,
               agent_id: ctx.agent,
               slot: "reviewer",
               start: m1_start
             })

    [first_rpc] = Agent.get(p11_invites, & &1)
    inv_id_m1 = first_rpc["invite_id"]
    assert is_binary(inv_id_m1) and inv_id_m1 != ""

    # Calling with DIFFERENT start M2 MUST be rejected with {:slot_already_pending, _} and send 0 RPCs!
    assert {:error, {:slot_already_pending, _}} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_p11,
               device_id: ctx.device,
               agent_id: ctx.agent,
               slot: "reviewer",
               start: m2_start
             })

    assert length(Agent.get(p11_invites, & &1)) == 1

    # Re-entering with IDENTICAL M1 reuses the exact same persisted invite_id!
    assert {:error, {:station_invite_unknown, :timeout}} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_p11,
               device_id: ctx.device,
               agent_id: ctx.agent,
               slot: "reviewer",
               start: m1_start
             })

    [second_rpc, _] = Agent.get(p11_invites, & &1)
    assert second_rpc["invite_id"] == inv_id_m1
    assert second_rpc["start"]["model"] == "m1"

    # ── 5. R21 P1-2: Local :station_outdated on BOTH (a) deact ok + remove fail + backoff fail AND
    # (b) deact fail + backoff fail returns {:error, :binding_state_unavailable} AND wakes giver! ──
    # Case (a): deact succeeds, remove fails once, backoff fails once -> returns :binding_state_unavailable
    # AND wakes giver which clears pending_multi_starts automatically!
    {:ok, _} = FlakyTaskSessions.start_link(fail_backoff: 1, fail_remove: 1)
    on_exit(fn -> FlakyTaskSessions.stop() end)

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations,
      task_sessions: FlakyTaskSessions
    )

    conv_12a = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_12a,
               make_r21_spec.(conv_12a, "R21 P1-2a", ctx.device)
             )

    {:ok, %{"participants" => parts_12a}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_12a)

    pid_12a = Enum.find(parts_12a, &(&1["target_key"] == "reviewer"))["participant_id"]
    run_old_12 = register_device(ctx, "r21_p12_old", %{"tasks" => 2})

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_12a,
        device_id: ctx.device,
        session: "ses_r21_12a_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_old_12}
      })

    FakeConnector.on("task.put", fn _ -> {:ok, %{"through" => 0}} end)

    assert {:error, :binding_state_unavailable} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_12a,
               device_id: ctx.device,
               agent_id: ctx.agent,
               participant_id: pid_12a,
               slot: "reviewer",
               start: %{"slot" => "reviewer", "is_primary" => false}
             })

    # Giver was woken automatically by persist_refusal_and_schedule -> clears pending_multi_starts!
    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_12a) do
        {:ok, [row]} -> List.wrap(row.start["pending_multi_starts"]) == []
        _ -> false
      end
    end)

    # Case (b): deact fails once + backoff fails once -> returns :binding_state_unavailable
    # AND wakes giver which automatically completes deactivation & clears pending_multi_starts!
    fail_ctr_12b = :atomics.new(1, [])
    {:ok, _} = FlakyUnboundConversations.start_link(fail_ctr_12b)
    on_exit(fn -> FlakyUnboundConversations.stop() end)
    FlakyTaskSessions.set_failures(fail_backoff: 1, fail_remove: 0)

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FlakyUnboundConversations,
      task_sessions: FlakyTaskSessions
    )

    conv_12b = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_12b,
               make_r21_spec.(conv_12b, "R21 P1-2b", ctx.device)
             )

    {:ok, %{"participants" => parts_12b}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_12b)

    pid_12b = Enum.find(parts_12b, &(&1["target_key"] == "reviewer"))["participant_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_12b,
        device_id: ctx.device,
        session: "ses_r21_12b_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_old_12}
      })

    assert {:error, :binding_state_unavailable} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_12b,
               device_id: ctx.device,
               agent_id: ctx.agent,
               participant_id: pid_12b,
               slot: "reviewer",
               start: %{"slot" => "reviewer", "is_primary" => false}
             })

    # Giver was woken automatically (no manual give/3!) -> deactivates pid_12b and clears pending!
    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_12b) do
        {:ok, [row]} -> List.wrap(row.start["pending_multi_starts"]) == []
        _ -> false
      end
    end)

    {:ok, %{"participants" => parts_12b_end}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_12b)

    assert Enum.find(parts_12b_end, &(&1["participant_id"] == pid_12b))["state"] == "inactive"
  end

  test "R22 P0-1/P0-2/P1: primary station_transient keeps sandbox alive, stopped sandbox add_session_start reserves seq via Actor, online add_session honors pending_deactivation with 0 RPCs",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations
    )

    now_r22 = SystemsClock.system_time(:millisecond)

    make_r22_spec = fn conv_id, title, dev_id ->
      %{
        "group_id" => ctx.group,
        "conversation_id" => conv_id,
        "title" => title,
        "creator_user_id" => "usr_owner",
        "status" => "active",
        "runs_on" => %{"kind" => "device", "device_id" => dev_id},
        "worker_agent_id" => ctx.agent,
        "conversation" => %{
          "conversation_id" => conv_id,
          "group_id" => ctx.group,
          "type" => "task",
          "title" => title,
          "status" => "active",
          "created_at" => now_r22,
          "updated_at" => now_r22,
          "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => dev_id}},
          "participants" => [
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => nil,
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r22,
              "updated_at" => now_r22
            },
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => "reviewer",
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r22,
              "updated_at" => now_r22
            }
          ]
        }
      }
    end

    # ── 1. R22 P0-1: Empty-binding 2-slot sandbox whose primary first task.invite hits
    # SQLite `database is locked` ({:station_transient, _}) MUST NOT stop the sandbox;
    # keeps workload + starts + schedules reconcile_pending retry, and binds primary on retry! ──
    conv_1 = Ids.new_conversation_id()

    {:ok, w_1} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1,
        workspace: "ws_r22_1",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "reviewer", "is_primary" => false}
          }
        ]
      })

    dev_1 = w_1.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_1,
               make_r22_spec.(conv_1, "R22 P0-1", dev_1)
             )

    tr_1 = SalixStore.CodingSandboxes.transport_id(conv_1)

    {:ok, ^tr_1, rec_1} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_1,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_1),
          "workload_id" => w_1.id,
          "workload_generation" => w_1.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_1
      )

    run_1 = rec_1["connector_run_id"]

    {:ok, w_1_ready} =
      SalixStore.CodingSandboxes.update(w_1.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "ready",
           "invited" => false,
           "connector_run_id" => run_1
         })}
      end)

    p01_calls = Agent.start_link(fn -> 0 end) |> elem(1)
    on_exit(fn -> if Process.alive?(p01_calls), do: Agent.stop(p01_calls) end)

    FakeConnector.on("task.put", fn _params ->
      {:ok, %{"ok" => true, "present" => ["ses_r22_p01_lead", "ses_r22_p01_rev"]}}
    end)

    FakeConnector.on("task.invite", fn params ->
      n = Agent.get_and_update(p01_calls, &{&1 + 1, &1 + 1})

      cond do
        n == 1 ->
          {:error, "SQLITE_BUSY: database is locked"}

        params["slot"] == "lead" ->
          {:ok, %{"session" => "ses_r22_p01_lead", "slot" => "lead"}}

        true ->
          {:ok, %{"session" => "ses_r22_p01_rev", "slot" => params["slot"] || "reviewer"}}
      end
    end)

    # First reconcile_invites: primary gets SQLITE_BUSY -> MUST NOT stop sandbox!
    _ = CodingSandboxes.reconcile_invites(w_1_ready)

    {:ok, w_1_mid} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_1)
    assert w_1_mid.spec["state"] == "ready"
    assert Enum.map(w_1_mid.spec["starts"], & &1["slot"]) == ["lead", "reviewer"]
    assert get_in(w_1_mid.spec, ["pending_secondaries", "reconcile_pending"]) == true
    assert is_binary(w_1_mid.spec["next_check_at"])

    # Second reconcile_invites after lock clears -> binds primary & secondary cleanly!
    _ = CodingSandboxes.reconcile_invites(w_1_mid)

    {:ok, rows_1} = StationTaskSessions.of_task(ctx.group, conv_1)
    assert Enum.any?(rows_1, &(&1.session == "ses_r22_p01_lead"))
    assert Enum.any?(rows_1, &(&1.session == "ses_r22_p01_rev"))

    # ── 2. R22 P0-2: Stopped/non-ready sandbox re-adding a slot with gen-2 pending_deactivation
    # MUST reserve gen-3 through ParticipantActor, clear pending_deactivation, set reconcile_pending,
    # and bind gen-3 cleanly on recovery without executing stale gen-2 deactivation! ──
    conv_2 = Ids.new_conversation_id()

    {:ok, w_2} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2,
        workspace: "ws_r22_2",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    dev_2 = w_2.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_2,
               make_r22_spec.(conv_2, "R22 P0-2", dev_2)
             )

    {:ok, %{"participants" => parts_2}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_2)

    pid_2_rev = Enum.find(parts_2, &(&1["target_key"] == "reviewer"))["participant_id"]
    tr_2 = SalixStore.CodingSandboxes.transport_id(conv_2)

    {:ok, ^tr_2, rec_2} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_2,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_2),
          "workload_id" => w_2.id,
          "workload_generation" => w_2.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_2
      )

    run_2 = rec_2["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2,
        device_id: dev_2,
        session: "ses_r22_p02_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_2}
      })

    # Persist gen-2 pending_deactivation on a STOPPED sandbox
    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_2.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "stopped",
           "invited" => true,
           "connector_run_id" => run_2,
           "slot_seq_hwm" => %{"reviewer" => 2},
           "starts" => [
             %{
               "slot" => "lead",
               "is_primary" => true,
               "agent_id" => ctx.agent,
               "start" => %{"slot" => "lead", "is_primary" => true}
             },
             %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_2_rev,
               "start_seq" => 2,
               "start" => %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "participant_id" => pid_2_rev
               }
             }
           ],
           "pending_secondaries" => %{
             "reconcile_pending" => true,
             "by_slot" => %{
               "reviewer" => %{
                 "attempts" => 1,
                 "latest_seq" => 2,
                 "pending_deactivation" => true,
                 "deactivation_seq" => 2,
                 "deactivation_participant_id" => pid_2_rev
               }
             }
           }
         })}
      end)

    # Re-add reviewer while stopped -> MUST reserve gen 3, clear pending_deactivation, set reconcile_pending!
    assert :ok =
             CodingSandboxes.add_session_start(ctx.tenant, conv_2, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_2_rev,
               "start" => %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "participant_id" => pid_2_rev
               }
             })

    {:ok, w_2_after_add} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_2)
    rev_entry_2 = Enum.find(w_2_after_add.spec["starts"], &(&1["slot"] == "reviewer"))
    assert rev_entry_2["start_seq"] == 3
    assert w_2_after_add.spec["slot_seq_hwm"]["reviewer"] == 3

    rev_meta_2 = get_in(w_2_after_add.spec, ["pending_secondaries", "by_slot", "reviewer"])
    assert rev_meta_2["latest_seq"] == 3
    assert rev_meta_2["pending_deactivation"] == nil
    assert rev_meta_2["deactivation_seq"] == nil
    assert get_in(w_2_after_add.spec, ["pending_secondaries", "reconcile_pending"]) == true

    # Sandbox becomes ready again -> reconcile_invites invites gen 3 and binds reviewer; participant stays active!
    {:ok, w_2_ready} =
      SalixStore.CodingSandboxes.update(w_2.id, fn cur ->
        {:ok, Map.put(cur.spec, "state", "ready")}
      end)

    FakeConnector.on("task.put", fn _params ->
      {:ok, %{"ok" => true, "present" => ["ses_r22_p02_lead", "ses_r22_p02_rev_g3"]}}
    end)

    FakeConnector.on("task.invite", fn params ->
      {:ok, %{"session" => "ses_r22_p02_rev_g3", "slot" => params["slot"] || "reviewer"}}
    end)

    _ = CodingSandboxes.reconcile_invites(w_2_ready)

    {:ok, rows_2} = StationTaskSessions.of_task(ctx.group, conv_2)
    rev_row_2 = Enum.find(rows_2, &(&1.session == "ses_r22_p02_rev_g3"))
    assert rev_row_2 != nil
    assert rev_row_2.start["start_seq"] == 3

    {:ok, %{"participants" => parts_2_end}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_2)

    assert Enum.find(parts_2_end, &(&1["participant_id"] == pid_2_rev))["state"] == "active"

    # ── 3. R22 P1: Personal station local :station_outdated with persisted pending_deactivation: true
    # -> device upgrades to multi_session_tasks: true -> online add_session replay with identical params
    # BEFORE background cleanup MUST send 0 task.invite RPCs, add 0 reviewer bindings, return refusal,
    # and wake giver to complete deactivation! ──
    conv_3 = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_3,
               make_r22_spec.(conv_3, "R22 P1", ctx.device)
             )

    {:ok, %{"participants" => parts_3}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_3)

    pid_3_rev = Enum.find(parts_3, &(&1["target_key"] == "reviewer"))["participant_id"]

    # Connect outdated device (no multi_session_tasks capability)
    tr_3_old = "tr_r22_p1_old"

    {:ok, ^tr_3_old, rec_3_old} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r22_p1_old",
          "name" => "Outdated personal station",
          "capabilities" => %{"tasks" => 2}
        },
        transport_id: tr_3_old
      )

    run_3_old = rec_3_old["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_3,
        device_id: ctx.device,
        session: "ses_r22_p1_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_3_old}
      })

    # Persist pending_multi_starts with pending_deactivation: true & refusal_reason: "station_outdated"
    # (simulating local :station_outdated where initial deactivation temporarily failed and backoff persisted)
    p1_start = %{"slot" => "reviewer", "is_primary" => false, "participant_id" => pid_3_rev}

    {:ok, _} =
      StationTaskSessions.append_pending_multi_start(ctx.group, conv_3, ctx.device, %{
        "slot" => "reviewer",
        "is_primary" => false,
        "agent_id" => ctx.agent,
        "participant_id" => pid_3_rev,
        "invite_id" => "inv_r22_p1_fixed",
        "start" => p1_start
      })

    assert :ok =
             StationTaskSessions.update_pending_multi_starts_backoff(
               ctx.group,
               conv_3,
               ctx.device,
               %{
                 "reviewer" => %{
                   "attempts" => 1,
                   "next_retry_at" => SystemsClock.system_time(:millisecond) + 60_000,
                   "pending_deactivation" => true,
                   "refusal_reason" => "station_outdated"
                 }
               }
             )

    # Upgrade device to support multi_session_tasks BEFORE background cleanup runs!
    tr_3_new = "tr_r22_p1_new"

    {:ok, ^tr_3_new, _rec_3_new} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r22_p1_new",
          "name" => "Upgraded personal station",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_3_new
      )

    p1_rpc_count = Agent.start_link(fn -> 0 end) |> elem(1)
    on_exit(fn -> if Process.alive?(p1_rpc_count), do: Agent.stop(p1_rpc_count) end)

    FakeConnector.on("task.invite", fn _params ->
      Agent.update(p1_rpc_count, &(&1 + 1))
      {:ok, %{"session" => "ses_r22_p1_must_not_be_created"}}
    end)

    FakeConnector.on("task.put", fn _params ->
      {:ok, %{"ok" => true, "present" => ["ses_r22_p1_lead"]}}
    end)

    # Online replay with identical params MUST send 0 task.invite RPCs, add 0 reviewer bindings,
    # return {:error, :station_outdated}, and deactivate pid_3_rev!
    assert {:error, :station_outdated} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_3,
               device_id: ctx.device,
               agent_id: ctx.agent,
               participant_id: pid_3_rev,
               slot: "reviewer",
               start: p1_start
             })

    assert Agent.get(p1_rpc_count, & &1) == 0

    {:ok, rows_3} = StationTaskSessions.of_task(ctx.group, conv_3)
    assert Enum.map(rows_3, & &1.session) == ["ses_r22_p1_lead"]

    {:ok, %{"participants" => parts_3_end}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_3)

    assert Enum.find(parts_3_end, &(&1["participant_id"] == pid_3_rev))["state"] == "inactive"
  end

  test "R23 P0/P1-2/P1-3: invite_id-scoped remove & backoff protect new slot entry B, delayed add_session_start preserves earlier next_check_at, stopped re-add persists new model M2",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations
    )

    now_r23 = SystemsClock.system_time(:millisecond)

    make_r23_spec = fn conv_id, title, dev_id ->
      %{
        "group_id" => ctx.group,
        "conversation_id" => conv_id,
        "title" => title,
        "creator_user_id" => "usr_owner",
        "status" => "active",
        "runs_on" => %{"kind" => "device", "device_id" => dev_id},
        "worker_agent_id" => ctx.agent,
        "conversation" => %{
          "conversation_id" => conv_id,
          "group_id" => ctx.group,
          "type" => "task",
          "title" => title,
          "status" => "active",
          "created_at" => now_r23,
          "updated_at" => now_r23,
          "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => dev_id}},
          "participants" => [
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => nil,
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r23,
              "updated_at" => now_r23
            },
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => "reviewer",
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r23,
              "updated_at" => now_r23
            }
          ]
        }
      }
    end

    # ── 1. R23 P0: Concurrent replays holding refused A (invite_id_A) -> replay 2 removes A ->
    # device offline & new request B (invite_id_B) persists -> replay 1 calls remove & backoff with
    # invite_id_A -> B MUST remain intact (not deleted, not marked pending_deactivation)! ──
    conv_1 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1,
        device_id: ctx.device,
        session: "ses_r23_p0_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => "run_r23_p0"}
      })

    {:ok, entry_a} =
      StationTaskSessions.append_pending_multi_start(ctx.group, conv_1, ctx.device, %{
        "slot" => "reviewer",
        "is_primary" => false,
        "agent_id" => ctx.agent,
        "invite_id" => "inv_r23_A",
        "start" => %{"slot" => "reviewer", "is_primary" => false, "model" => "mA"}
      })

    assert entry_a["invite_id"] == "inv_r23_A"

    # Replay 2 finishes cleaning A by {slot, invite_id_A}
    assert {:ok, 1} =
             StationTaskSessions.remove_pending_multi_starts(
               ctx.group,
               conv_1,
               ctx.device,
               [{"reviewer", "inv_r23_A"}]
             )

    # Device goes offline; new request B persists with invite_id_B
    {:ok, entry_b} =
      StationTaskSessions.append_pending_multi_start(ctx.group, conv_1, ctx.device, %{
        "slot" => "reviewer",
        "is_primary" => false,
        "agent_id" => ctx.agent,
        "invite_id" => "inv_r23_B",
        "start" => %{"slot" => "reviewer", "is_primary" => false, "model" => "mB"}
      })

    assert entry_b["invite_id"] == "inv_r23_B"

    # Stale Replay 1 wakes up holding invite_id_A and calls remove + backoff with invite_id_A
    assert {:ok, 0} =
             StationTaskSessions.remove_pending_multi_starts(
               ctx.group,
               conv_1,
               ctx.device,
               [{"reviewer", "inv_r23_A"}]
             )

    assert :ok =
             StationTaskSessions.update_pending_multi_starts_backoff(
               ctx.group,
               conv_1,
               ctx.device,
               %{
                 "reviewer" => %{
                   "expected_invite_id" => "inv_r23_A",
                   "attempts" => 1,
                   "next_retry_at" => now_r23 + 60_000,
                   "pending_deactivation" => true,
                   "refusal_reason" => "station_outdated"
                 }
               }
             )

    # Assert B is completely untouched!
    {:ok, [lead_1]} = StationTaskSessions.of_task(ctx.group, conv_1)
    [kept_b] = lead_1.start["pending_multi_starts"]
    assert kept_b["invite_id"] == "inv_r23_B"
    assert kept_b["start"]["model"] == "mB"
    assert kept_b["pending_deactivation"] == nil
    assert kept_b["expected_invite_id"] == nil

    # ── 2. R23 P1-2: Starting sandbox with earlier next_check_at (5s from now) -> delayed
    # add_session_start MUST keep the earlier next_check_at (never push it back by 30s)! ──
    conv_2 = Ids.new_conversation_id()

    {:ok, w_2} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2,
        workspace: "ws_r23_2",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    dev_2 = w_2.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_2,
               make_r23_spec.(conv_2, "R23 P1-2", dev_2)
             )

    {:ok, %{"participants" => parts_2}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_2)

    pid_2_rev = Enum.find(parts_2, &(&1["target_key"] == "reviewer"))["participant_id"]

    earlier_iso =
      DateTime.from_unix!(now_r23 + 5_000, :millisecond) |> DateTime.to_iso8601()

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_2.id, fn cur ->
        {:ok, Map.merge(cur.spec, %{"state" => "starting", "next_check_at" => earlier_iso})}
      end)

    assert :ok =
             CodingSandboxes.add_session_start(ctx.tenant, conv_2, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_2_rev,
               "start" => %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "participant_id" => pid_2_rev
               }
             })

    {:ok, w_2_after} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_2)
    assert w_2_after.spec["next_check_at"] == earlier_iso
    assert get_in(w_2_after.spec, ["pending_secondaries", "reconcile_pending"]) == true

    # ── 3. R23 P1-3: Stopped sandbox with gen-2 model M1 pending_deactivation -> same participant
    # re-added with model M2 -> gen-3 persists M2, recovery RPC and DB binding both carry M2! ──
    conv_3 = Ids.new_conversation_id()

    {:ok, w_3} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_3,
        workspace: "ws_r23_3",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    dev_3 = w_3.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_3,
               make_r23_spec.(conv_3, "R23 P1-3", dev_3)
             )

    {:ok, %{"participants" => parts_3}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_3)

    pid_3_rev = Enum.find(parts_3, &(&1["target_key"] == "reviewer"))["participant_id"]
    tr_3 = SalixStore.CodingSandboxes.transport_id(conv_3)

    {:ok, ^tr_3, rec_3} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => dev_3,
          "connector_id" => SalixStore.CodingSandboxes.connector_id(conv_3),
          "workload_id" => w_3.id,
          "workload_generation" => w_3.generation,
          "name" => "Coding sandbox",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_3
      )

    run_3 = rec_3["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_3,
        device_id: dev_3,
        session: "ses_r23_p13_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_3}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_3.id, fn cur ->
        {:ok,
         Map.merge(cur.spec, %{
           "state" => "stopped",
           "invited" => true,
           "connector_run_id" => run_3,
           "slot_seq_hwm" => %{"reviewer" => 2},
           "starts" => [
             %{
               "slot" => "lead",
               "is_primary" => true,
               "agent_id" => ctx.agent,
               "start" => %{"slot" => "lead", "is_primary" => true}
             },
             %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_3_rev,
               "start_seq" => 2,
               "start" => %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "participant_id" => pid_3_rev,
                 "model" => "m1"
               }
             }
           ],
           "pending_secondaries" => %{
             "reconcile_pending" => true,
             "by_slot" => %{
               "reviewer" => %{
                 "attempts" => 1,
                 "latest_seq" => 2,
                 "pending_deactivation" => true,
                 "deactivation_seq" => 2,
                 "deactivation_participant_id" => pid_3_rev
               }
             }
           }
         })}
      end)

    # Re-add same participant with NEW model "m2" while stopped
    assert :ok =
             CodingSandboxes.add_session_start(ctx.tenant, conv_3, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_3_rev,
               "start" => %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "participant_id" => pid_3_rev,
                 "model" => "m2"
               }
             })

    {:ok, w_3_after_add} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_3)
    rev_3 = Enum.find(w_3_after_add.spec["starts"], &(&1["slot"] == "reviewer"))
    assert rev_3["start_seq"] == 3
    assert rev_3["start"]["model"] == "m2"

    {:ok, w_3_ready} =
      SalixStore.CodingSandboxes.update(w_3.id, fn cur ->
        {:ok, Map.put(cur.spec, "state", "ready")}
      end)

    p13_sent_models = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(p13_sent_models), do: Agent.stop(p13_sent_models) end)

    FakeConnector.on("task.put", fn _params ->
      {:ok, %{"ok" => true, "present" => ["ses_r23_p13_lead", "ses_r23_p13_rev_m2"]}}
    end)

    FakeConnector.on("task.invite", fn params ->
      Agent.update(p13_sent_models, &[get_in(params, ["start", "model"]) | &1])
      {:ok, %{"session" => "ses_r23_p13_rev_m2", "slot" => params["slot"] || "reviewer"}}
    end)

    _ = CodingSandboxes.reconcile_invites(w_3_ready)

    assert Agent.get(p13_sent_models, & &1) == ["m2"]
    {:ok, rows_3} = StationTaskSessions.of_task(ctx.group, conv_3)
    rev_row_3 = Enum.find(rows_3, &(&1.session == "ses_r23_p13_rev_m2"))
    assert rev_row_3 != nil
    assert rev_row_3.start["start_seq"] == 3
    assert rev_row_3.start["model"] == "m2"
  end

  test "R24 P0-1/P0-2/P1: invite_id-verified deactivation & ETS isolation, ensure_pending_invite_id entry_changed guard, and sandbox slot_config_conflict",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations
    )

    now_r24 = SystemsClock.system_time(:millisecond)

    make_r24_spec = fn conv_id, title, dev_id ->
      %{
        "group_id" => ctx.group,
        "conversation_id" => conv_id,
        "title" => title,
        "creator_user_id" => "usr_owner",
        "status" => "active",
        "runs_on" => %{"kind" => "device", "device_id" => dev_id},
        "worker_agent_id" => ctx.agent,
        "conversation" => %{
          "conversation_id" => conv_id,
          "group_id" => ctx.group,
          "type" => "task",
          "title" => title,
          "status" => "active",
          "created_at" => now_r24,
          "updated_at" => now_r24,
          "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => dev_id}},
          "participants" => [
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => nil,
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r24,
              "updated_at" => now_r24
            },
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => "reviewer",
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r24,
              "updated_at" => now_r24
            }
          ]
        }
      }
    end

    # ── 1. R24 P0-1: Stale deactivation for invite A MUST abort with :superseded after invite B
    # takes the slot for the same participant; B's participant stays active, B's pending stays
    # intact, and ETS refusal guard for A does NOT poison B! ──
    conv_1 = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_1,
               make_r24_spec.(conv_1, "R24 P0-1", ctx.device)
             )

    {:ok, %{"participants" => parts_1}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_1)

    pid_1_rev = Enum.find(parts_1, &(&1["target_key"] == "reviewer"))["participant_id"]

    tr_1 = "tr_r24_p01"

    {:ok, ^tr_1, rec_1} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r24_p01",
          "name" => "Personal station R24",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_1
      )

    run_1 = rec_1["connector_run_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1,
        device_id: ctx.device,
        session: "ses_r24_p01_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_1}
      })

    # Invite B is now the live pending entry for pid_1_rev
    b_start = %{"slot" => "reviewer", "is_primary" => false, "participant_id" => pid_1_rev}

    {:ok, _} =
      StationTaskSessions.append_pending_multi_start(ctx.group, conv_1, ctx.device, %{
        "slot" => "reviewer",
        "is_primary" => false,
        "agent_id" => ctx.agent,
        "participant_id" => pid_1_rev,
        "invite_id" => "inv_r24_B",
        "start" => b_start
      })

    # Stale verify_unbound_fun for old invite A MUST return {:abort, :superseded} under device lock!
    verify_a =
      StationTasks.slot_verify_unbound_fun(ctx.group, conv_1, ctx.device, "reviewer", "inv_r24_A")

    assert {:abort, :superseded} = verify_a.(nil)

    assert {:error, :superseded} =
             ConversationServer.deactivate_unbound_task_participant(
               ctx.group,
               conv_1,
               pid_1_rev,
               nil,
               verify_a
             )

    # Participant remains active and B remains intact
    {:ok, %{"participants" => parts_1_after}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_1)

    assert Enum.find(parts_1_after, &(&1["participant_id"] == pid_1_rev))["state"] == "active"

    # Even if an ETS refusal guard was recorded for invite A (same pid_1_rev!),
    # online replay of B MUST NOT hit A's ETS refusal guard and proceeds to invite!
    tid = :ets.whereis(:salix_station_task_refusal_guards)

    :ets.insert(
      tid,
      {{ctx.group, conv_1, ctx.device, "reviewer", {:invite, "inv_r24_A"}}, "station_outdated"}
    )

    FakeConnector.on("task.put", fn _params ->
      {:ok, %{"ok" => true, "present" => ["ses_r24_p01_lead", "ses_r24_p01_rev_B"]}}
    end)

    FakeConnector.on("task.invite", fn params ->
      assert params["invite_id"] == "inv_r24_B"
      {:ok, %{"session" => "ses_r24_p01_rev_B", "slot" => "reviewer"}}
    end)

    assert :ok =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_1,
               device_id: ctx.device,
               agent_id: ctx.agent,
               participant_id: pid_1_rev,
               slot: "reviewer",
               start: b_start
             })

    {:ok, rows_1} = StationTaskSessions.of_task(ctx.group, conv_1)
    assert Enum.any?(rows_1, &(&1.session == "ses_r24_p01_rev_B"))

    # ── 2. R24 P0-2: ensure_pending_invite_id rejects mismatched stale ID-less snapshot A/M1
    # when slot was replaced by B/M2, returning {:error, {:entry_changed, _}} (0 mixed RPCs)! ──
    conv_2 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2,
        device_id: ctx.device,
        session: "ses_r24_p02_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_1}
      })

    {:ok, entry_b2} =
      StationTaskSessions.append_pending_multi_start(ctx.group, conv_2, ctx.device, %{
        "slot" => "reviewer",
        "is_primary" => false,
        "agent_id" => ctx.agent,
        "invite_id" => "inv_r24_B2",
        "start" => %{"slot" => "reviewer", "is_primary" => false, "model" => "m2"}
      })

    assert entry_b2["invite_id"] == "inv_r24_B2"

    stale_a_m1 = %{
      "slot" => "reviewer",
      "is_primary" => false,
      "agent_id" => ctx.agent,
      "start" => %{"slot" => "reviewer", "is_primary" => false, "model" => "m1"}
    }

    assert {:error, {:entry_changed, %{"invite_id" => "inv_r24_B2"}}} =
             StationTaskSessions.ensure_pending_invite_id(
               ctx.group,
               conv_2,
               ctx.device,
               "reviewer",
               stale_a_m1
             )

    # B/M2 remains untouched in DB
    {:ok, [lead_2]} = StationTaskSessions.of_task(ctx.group, conv_2)
    [kept_b2] = lead_2.start["pending_multi_starts"]
    assert kept_b2["invite_id"] == "inv_r24_B2"
    assert kept_b2["start"]["model"] == "m2"

    # ── 3. R24 P1: Stopped sandbox with active binding S1(M1) rejects re-add with M2
    # via {:error, :slot_config_conflict}, preserving M1 in both workload and DB! ──
    conv_3 = Ids.new_conversation_id()

    {:ok, w_3} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_3,
        workspace: "ws_r24_3",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start_seq" => 1,
            "start" => %{"slot" => "reviewer", "is_primary" => false, "model" => "m1"}
          }
        ]
      })

    dev_3 = w_3.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_3,
               make_r24_spec.(conv_3, "R24 P1", dev_3)
             )

    {:ok, %{"participants" => parts_3}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_3)

    pid_3_rev = Enum.find(parts_3, &(&1["target_key"] == "reviewer"))["participant_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_3,
        device_id: dev_3,
        session: "ses_r24_p1_rev_s1",
        agent_id: ctx.agent,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "participant_id" => pid_3_rev,
          "model" => "m1"
        }
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_3.id, fn cur ->
        {:ok, Map.put(cur.spec, "state", "stopped")}
      end)

    assert {:error, :slot_config_conflict} =
             CodingSandboxes.add_session_start(ctx.tenant, conv_3, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_3_rev,
               "start" => %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "participant_id" => pid_3_rev,
                 "model" => "m2"
               }
             })

    {:ok, w_3_end} = SalixStore.CodingSandboxes.get_by_conversation(ctx.tenant, conv_3)
    rev_3_end = Enum.find(w_3_end.spec["starts"], &(&1["slot"] == "reviewer"))
    assert rev_3_end["start"]["model"] == "m1"
    assert rev_3_end["start_seq"] == 1
  end

  defmodule R25FailEnsureOnceStore do
    def fail_once_key, do: :r25_fail_ensure_once

    def ensure_pending_invite_id(group, conv, device, slot, expected_entry) do
      case :ets.whereis(fail_once_key()) do
        :undefined ->
          SalixStore.StationTaskSessions.ensure_pending_invite_id(
            group,
            conv,
            device,
            slot,
            expected_entry
          )

        tid ->
          case :ets.take(tid, slot) do
            [{^slot, :fail}] ->
              {:error, :db_timeout}

            _ ->
              SalixStore.StationTaskSessions.ensure_pending_invite_id(
                group,
                conv,
                device,
                slot,
                expected_entry
              )
          end
      end
    end

    def update_pending_multi_starts_backoff(g, c, d, u),
      do: SalixStore.StationTaskSessions.update_pending_multi_starts_backoff(g, c, d, u)

    def remove_pending_multi_starts(g, c, d, s),
      do: SalixStore.StationTaskSessions.remove_pending_multi_starts(g, c, d, s)
  end

  test "R25 P0-1/P0-2/P1-3/P1-4: Provider epoch/invite compensation, join expected_pending_invite_id, bounded retry & default slot conflict",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations
    )

    now_r25 = SystemsClock.system_time(:millisecond)

    make_r25_spec = fn conv_id, title, dev_id ->
      %{
        "group_id" => ctx.group,
        "conversation_id" => conv_id,
        "title" => title,
        "creator_user_id" => "usr_owner",
        "status" => "active",
        "runs_on" => %{"kind" => "device", "device_id" => dev_id},
        "worker_agent_id" => ctx.agent,
        "conversation" => %{
          "conversation_id" => conv_id,
          "group_id" => ctx.group,
          "type" => "task",
          "title" => title,
          "status" => "active",
          "created_at" => now_r25,
          "updated_at" => now_r25,
          "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => dev_id}},
          "participants" => [
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => nil,
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r25,
              "updated_at" => now_r25
            }
          ]
        }
      }
    end

    # ── 1. R25 P0-2 (a): join_with_token rejects stale A/M1 when pending was replaced by B/M2! ──
    tr_1 = "tr_r25_p02"

    {:ok, ^tr_1, rec_1} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r25_p02",
          "name" => "Personal station R25",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_1
      )

    run_1 = rec_1["connector_run_id"]
    conv_2 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2,
        device_id: ctx.device,
        session: "ses_r25_p02_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_1}
      })

    {:ok, _} =
      StationTaskSessions.append_pending_multi_start(ctx.group, conv_2, ctx.device, %{
        "slot" => "reviewer",
        "is_primary" => false,
        "agent_id" => ctx.agent,
        "invite_id" => "inv_r25_B2",
        "start" => %{"slot" => "reviewer", "is_primary" => false, "model" => "m2"}
      })

    # Stale giver holding A's invite_id attempts register_slot_binding -> rejected with :stale_slot_binding!
    assert {:error, {:stale_slot_binding, :invite_superseded}} =
             StationTasks.register_slot_binding(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_2,
               device_id: ctx.device,
               session: "ses_r25_stale_A_m1",
               agent_id: ctx.agent,
               answered: 0,
               expected_pending_invite_id: "inv_r25_A_old",
               start: %{"slot" => "reviewer", "is_primary" => false, "model" => "m1"},
               give: false
             })

    {:ok, rows_2} = StationTaskSessions.of_task(ctx.group, conv_2)
    assert Enum.map(rows_2, & &1.session) == ["ses_r25_p02_lead"]

    # ── 3. R25 P0-2 (b) & P1-3: Legacy ID-less pending entry that:
    # (b) reads back pending_deactivation: true -> 0 task.invite RPCs;
    # (P1-3) hits transient ensure_pending_invite_id failure once -> schedules bounded retry
    #        without blocking sibling slot, then succeeds on next wakeup! ──
    conv_3 = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_3,
               make_r25_spec.(conv_3, "R25 P0-2b & P1-3", ctx.device)
             )

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_3,
        device_id: ctx.device,
        session: "ses_r25_p13_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_1,
          "pending_multi_starts" => [
            %{
              "slot" => "legacy_deact",
              "is_primary" => false,
              "agent_id" => ctx.agent,
              "pending_deactivation" => true,
              "refusal_reason" => "station_outdated",
              "start" => %{"slot" => "legacy_deact", "is_primary" => false}
            },
            %{
              "slot" => "legacy_retry",
              "is_primary" => false,
              "agent_id" => ctx.agent,
              "start" => %{"slot" => "legacy_retry", "is_primary" => false}
            },
            %{
              "slot" => "healthy_qa",
              "is_primary" => false,
              "agent_id" => ctx.agent,
              "invite_id" => "inv_r25_qa_ok",
              "start" => %{"slot" => "healthy_qa", "is_primary" => false}
            }
          ]
        }
      })

    fail_tbl =
      :ets.new(R25FailEnsureOnceStore.fail_once_key(), [:named_table, :public, :set])

    on_exit(fn ->
      if :ets.whereis(R25FailEnsureOnceStore.fail_once_key()) != :undefined do
        :ets.delete(fail_tbl)
      end
    end)

    :ets.insert(fail_tbl, {"legacy_retry", :fail})

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations,
      task_sessions: R25FailEnsureOnceStore
    )

    p13_invited_slots = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(p13_invited_slots), do: Agent.stop(p13_invited_slots) end)

    FakeConnector.on("task.put", fn _params ->
      {:ok,
       %{
         "ok" => true,
         "present" => ["ses_r25_p13_lead", "ses_r25_qa_ok", "ses_r25_legacy_retry"]
       }}
    end)

    FakeConnector.on("task.invite", fn params ->
      slot = params["slot"]
      Agent.update(p13_invited_slots, &[slot | &1])
      {:ok, %{"session" => "ses_r25_#{slot}", "slot" => slot}}
    end)

    StationTasks.give(ctx.group, conv_3, ctx.device)

    # First pass: healthy_qa binds immediately (not blocked by legacy_retry!), legacy_deact sends
    # 0 task.invite RPCs and is cleaned up, then bounded SystemsClock timer wakes and binds legacy_retry!
    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_3) do
        {:ok, rows} -> Enum.any?(rows, &(&1.session == "ses_r25_healthy_qa"))
        _ -> false
      end
    end)

    # Advance virtual clock to fire bounded retry for legacy_retry!
    SystemsClock.advance(3_000)

    settle_until(fn ->
      case StationTaskSessions.of_task(ctx.group, conv_3) do
        {:ok, rows} -> Enum.any?(rows, &(&1.session == "ses_r25_legacy_retry"))
        _ -> false
      end
    end)

    invited_list = Agent.get(p13_invited_slots, & &1)
    refute "legacy_deact" in invited_list
    assert "healthy_qa" in invited_list
    assert "legacy_retry" in invited_list

    # Restore default task_sessions
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations
    )

    # ── 4. R25 P1-4: Default-config sandbox slot (model: nil, effort: nil) rejects explicit
    # model or effort request with {:error, :slot_config_conflict}! ──
    conv_4 = Ids.new_conversation_id()

    {:ok, w_4} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_4,
        workspace: "ws_r25_4",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          },
          %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "start_seq" => 1,
            "start" => %{"slot" => "reviewer", "is_primary" => false}
          }
        ]
      })

    dev_4 = w_4.spec["device_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_4,
        device_id: dev_4,
        session: "ses_r25_p14_rev_default",
        agent_id: ctx.agent,
        start: %{"slot" => "reviewer", "is_primary" => false}
      })

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_4.id, fn cur ->
        {:ok, Map.put(cur.spec, "state", "stopped")}
      end)

    assert {:error, :slot_config_conflict} =
             CodingSandboxes.add_session_start(ctx.tenant, conv_4, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "start" => %{"slot" => "reviewer", "is_primary" => false, "model" => "m2"}
             })

    assert {:error, :slot_config_conflict} =
             CodingSandboxes.add_session_start(ctx.tenant, conv_4, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "start" => %{"slot" => "reviewer", "is_primary" => false, "effort" => "high"}
             })
  end

  test "R26 P0-1/P0-2/P1: orphan task.leave on invite_superseded + authoritative_unbound, Sandbox verify_slot_unbound supersedes A when B reserved, same-invite_id online receipt returns idempotent :ok",
       ctx do
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: SalixWeb.StationTasks.Conversations
    )

    now_r26 = SystemsClock.system_time(:millisecond)

    make_r26_spec = fn conv_id, title, dev_id ->
      %{
        "group_id" => ctx.group,
        "conversation_id" => conv_id,
        "title" => title,
        "creator_user_id" => "usr_owner",
        "status" => "active",
        "runs_on" => %{"kind" => "device", "device_id" => dev_id},
        "worker_agent_id" => ctx.agent,
        "conversation" => %{
          "conversation_id" => conv_id,
          "group_id" => ctx.group,
          "type" => "task",
          "title" => title,
          "status" => "active",
          "created_at" => now_r26,
          "updated_at" => now_r26,
          "metadata" => %{"runs_on" => %{"kind" => "device", "device_id" => dev_id}},
          "participants" => [
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => nil,
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r26,
              "updated_at" => now_r26
            },
            %{
              "actor_type" => "agent",
              "agent_id" => ctx.agent,
              "role_label" => "worker",
              "target_key" => "reviewer",
              "state" => "active",
              "payload" => %{"session_id" => Ids.new_session_id()},
              "notification_filter" => %{"messages" => "none", "statuses" => "none"},
              "joined_at" => now_r26,
              "updated_at" => now_r26
            }
          ]
        }
      }
    end

    tr_1 = "tr_r26_p01"

    {:ok, ^tr_1, rec_1} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r26_p01",
          "name" => "Personal station R26",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_1
      )

    run_1 = rec_1["connector_run_id"]

    # ── 1. R26 P0-1: In-flight A creates orphan S_A on Station while DB swaps to B/M2 ->
    # A's registration is rejected with :invite_superseded AND immediately sends fenced
    # task.leave(slot, S_A); B/M2 sends authoritative_unbound: true and binds cleanly! ──
    conv_1 = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_1,
               make_r26_spec.(conv_1, "R26 P0-1", ctx.device)
             )

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1,
        device_id: ctx.device,
        session: "ses_r26_p01_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_1}
      })

    leaves_recorded = Agent.start_link(fn -> [] end) |> elem(1)
    invites_recorded = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(leaves_recorded), do: Agent.stop(leaves_recorded) end)
    on_exit(fn -> if Process.alive?(invites_recorded), do: Agent.stop(invites_recorded) end)

    FakeConnector.on("task.leave", fn params ->
      Agent.update(leaves_recorded, &[params | &1])
      {:ok, %{"ok" => true, "removed" => true, "kept" => false}}
    end)

    FakeConnector.on("task.put", fn _params ->
      {:ok, %{"ok" => true, "present" => ["ses_r26_p01_lead", "ses_r26_S_B"]}}
    end)

    FakeConnector.on("task.invite", fn params ->
      Agent.update(invites_recorded, &[params | &1])

      if params["invite_id"] == "inv_r26_A" do
        # While A's RPC is in flight, A is cleared and B/M2 takes the pending slot!
        {:ok, 1} =
          StationTaskSessions.remove_pending_multi_starts(
            ctx.group,
            conv_1,
            ctx.device,
            [{"reviewer", "inv_r26_A"}]
          )

        {:ok, _} =
          StationTaskSessions.append_pending_multi_start(ctx.group, conv_1, ctx.device, %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "invite_id" => "inv_r26_B",
            "start" => %{"slot" => "reviewer", "is_primary" => false, "model" => "m2"}
          })

        {:ok, %{"session" => "ses_r26_orphan_S_A", "slot" => "reviewer"}}
      else
        {:ok, %{"session" => "ses_r26_S_B", "slot" => "reviewer"}}
      end
    end)

    # Online A returns :invite_superseded AND immediately revokes orphan S_A via task.leave!
    assert {:error, {:stale_slot_binding, :invite_superseded}} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_1,
               device_id: ctx.device,
               agent_id: ctx.agent,
               invite_id: "inv_r26_A",
               slot: "reviewer",
               start: %{"slot" => "reviewer", "is_primary" => false, "model" => "m1"}
             })

    [leave_call] = Agent.get(leaves_recorded, & &1)
    assert leave_call["slot"] == "reviewer"
    assert leave_call["session"] == "ses_r26_orphan_S_A"
    assert leave_call["claim_token"] == "inv_r26_A"

    # Now B/M2 runs with claim_token == invite_id (NO authoritative_unbound) and binds cleanly!
    assert :ok =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_1,
               device_id: ctx.device,
               agent_id: ctx.agent,
               invite_id: "inv_r26_B",
               slot: "reviewer",
               start: %{"slot" => "reviewer", "is_primary" => false, "model" => "m2"}
             })

    b_invite = Enum.find(Agent.get(invites_recorded, & &1), &(&1["invite_id"] == "inv_r26_B"))
    assert b_invite["claim_token"] == "inv_r26_B"
    refute Map.has_key?(b_invite, "authoritative_unbound")

    {:ok, rows_1} = StationTaskSessions.of_task(ctx.group, conv_1)
    assert Enum.any?(rows_1, &(&1.session == "ses_r26_S_B" and &1.start["model"] == "m2"))

    # ── 2. R26 P0-2: StationTasks.verify_slot_unbound inspects Sandbox workload and returns
    # {:abort, :superseded} when B is reserved in stopped sandbox workload (same active participant)! ──
    conv_2 = Ids.new_conversation_id()

    {:ok, w_2} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2,
        workspace: "ws_r26_2",
        repo: nil,
        agent_id: ctx.agent,
        start: %{"requester" => "u1"},
        starts: [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "agent_id" => ctx.agent,
            "start" => %{"slot" => "lead", "is_primary" => true}
          }
        ]
      })

    dev_2 = w_2.spec["device_id"]

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_2,
               make_r26_spec.(conv_2, "R26 P0-2", dev_2)
             )

    {:ok, %{"participants" => parts_2}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_2)

    pid_2_rev = Enum.find(parts_2, &(&1["target_key"] == "reviewer"))["participant_id"]

    {:ok, _} =
      SalixStore.CodingSandboxes.update(w_2.id, fn cur ->
        {:ok, Map.put(cur.spec, "state", "stopped")}
      end)

    # Reserve B (invite_id: "inv_r26_sbx_B") on stopped sandbox
    assert :ok =
             CodingSandboxes.add_session_start(ctx.tenant, conv_2, %{
               "slot" => "reviewer",
               "is_primary" => false,
               "agent_id" => ctx.agent,
               "participant_id" => pid_2_rev,
               "invite_id" => "inv_r26_sbx_B",
               "start" => %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "participant_id" => pid_2_rev
               }
             })

    # Stale A ("inv_r26_sbx_A") calling verify_slot_unbound MUST get {:abort, :superseded}!
    assert {:abort, :superseded} =
             StationTasks.verify_slot_unbound(
               ctx.group,
               conv_2,
               dev_2,
               "reviewer",
               nil,
               "inv_r26_sbx_A"
             )

    # ── 3. R26 P1: Background commits same invite_id + session and clears pending BEFORE
    # online receipt calls register_slot_binding -> online add_session returns idempotent :ok! ──
    conv_3 = Ids.new_conversation_id()

    assert {:ok, _} =
             ConversationServer.create_task(
               ctx.group,
               conv_3,
               make_r26_spec.(conv_3, "R26 P1", ctx.device)
             )

    {:ok, %{"participants" => parts_3}} =
      Conversations.list_group_conversation_participants(ctx.group, conv_3)

    pid_3_rev = Enum.find(parts_3, &(&1["target_key"] == "reviewer"))["participant_id"]

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_3,
        device_id: ctx.device,
        session: "ses_r26_p1_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_1}
      })

    FakeConnector.on("task.put", fn _params ->
      {:ok, %{"ok" => true, "present" => ["ses_r26_p1_lead", "ses_r26_p1_same"]}}
    end)

    FakeConnector.on("task.invite", fn _params ->
      # Simulate background giver finishing bind + removing pending for the EXACT SAME invite_id
      # and session BEFORE the online call reaches register_slot_binding!
      assert :ok =
               StationTasks.register_slot_binding(%{
                 tenant_id: ctx.tenant,
                 group_id: ctx.group,
                 conversation_id: conv_3,
                 device_id: ctx.device,
                 session: "ses_r26_p1_same",
                 agent_id: ctx.agent,
                 answered: 0,
                 participant_id: pid_3_rev,
                 expected_pending_invite_id: "inv_r26_same_1",
                 start: %{
                   "slot" => "reviewer",
                   "is_primary" => false,
                   "participant_id" => pid_3_rev,
                   "connector_run_id" => run_1
                 },
                 give: false
               })

      {:ok, 1} =
        StationTaskSessions.remove_pending_multi_starts(
          ctx.group,
          conv_3,
          ctx.device,
          [{"reviewer", "inv_r26_same_1"}]
        )

      {:ok, %{"session" => "ses_r26_p1_same", "slot" => "reviewer"}}
    end)

    assert :ok =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_3,
               device_id: ctx.device,
               agent_id: ctx.agent,
               participant_id: pid_3_rev,
               invite_id: "inv_r26_same_1",
               slot: "reviewer",
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "participant_id" => pid_3_rev
               }
             })

    {:ok, rows_3} = StationTaskSessions.of_task(ctx.group, conv_3)
    same_row = Enum.find(rows_3, &(&1.session == "ses_r26_p1_same"))
    assert same_row != nil
    assert same_row.start["invite_id"] == "inv_r26_same_1"
    assert "inv_r26_same_1" in same_row.start["committed_invite_ids"]
  end

  test "R27 P1-3: offline orphan task.leave persists in pending_orphan_leaves and drains with claim_token BEFORE invite_secondary_list on reconnect",
       ctx do
    {:ok, _} =
      FakeConversations.start_link(
        messages: [%{"seq" => 1, "content" => "hi", "actor_type" => "user", "user_id" => "u1"}]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    tr_1 = "tr_r27_p1_3_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^tr_1, rec_1} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r27_p1_3",
          "name" => "R27 Station",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_1
      )

    run_1 = rec_1["connector_run_id"]
    conv = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv,
        device_id: ctx.device,
        session: "ses_r27_p1_3_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_1}
      })

    test_pid = self()
    events = Agent.start_link(fn -> [] end) |> elem(1)
    fail_leave = Agent.start_link(fn -> true end) |> elem(1)
    on_exit(fn -> if Process.alive?(events), do: Agent.stop(events) end)
    on_exit(fn -> if Process.alive?(fail_leave), do: Agent.stop(fail_leave) end)

    FakeConnector.on("task.leave", fn params ->
      if Agent.get(fail_leave, & &1) do
        {:error, :disconnected}
      else
        Agent.update(events, &(&1 ++ [{:leave, params}]))
        {:ok, %{"ok" => true, "removed" => true, "kept" => false}}
      end
    end)

    FakeConnector.on("task.put", fn _params ->
      {:ok, rows_now} = StationTaskSessions.of_task(ctx.group, conv)

      if Enum.any?(rows_now, &(&1.session == "ses_r27_p1_3_B")) do
        send(test_pid, :r27_p1_3_reconnected_and_bound)
      end

      {:ok,
       %{
         "through" => 1,
         "present_slots" => [
           %{"slot" => "lead", "session" => "ses_r27_p1_3_lead"},
           %{"slot" => "reviewer", "session" => "ses_r27_p1_3_B"}
         ]
       }}
    end)

    FakeConnector.on("task.invite", fn params ->
      Agent.update(events, &(&1 ++ [{:invite, params}]))

      if params["invite_id"] == "inv_r27_p1_3_A" do
        # Swap pending slot from A to B while A's RPC is in flight!
        {:ok, 1} =
          StationTaskSessions.remove_pending_multi_starts(
            ctx.group,
            conv,
            ctx.device,
            [{"reviewer", "inv_r27_p1_3_A"}]
          )

        {:ok, _} =
          StationTaskSessions.append_pending_multi_start(ctx.group, conv, ctx.device, %{
            "slot" => "reviewer",
            "is_primary" => false,
            "agent_id" => ctx.agent,
            "invite_id" => "inv_r27_p1_3_B",
            "start" => %{"slot" => "reviewer", "is_primary" => false, "model" => "m2"}
          })

        # task.leave will fail with {:error, :disconnected} while fail_leave is true!
        {:ok, %{"session" => "ses_r27_p1_3_orphan_A", "slot" => "reviewer"}}
      else
        {:ok, %{"session" => "ses_r27_p1_3_B", "slot" => "reviewer"}}
      end
    end)

    # A is superseded; task.leave fails while offline -> entry MUST remain in pending_orphan_leaves!
    assert {:error, {:stale_slot_binding, :invite_superseded}} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv,
               device_id: ctx.device,
               agent_id: ctx.agent,
               invite_id: "inv_r27_p1_3_A",
               slot: "reviewer",
               start: %{"slot" => "reviewer", "is_primary" => false, "model" => "m1"}
             })

    {:ok, [lead_offline]} = StationTaskSessions.of_task(ctx.group, conv)

    assert lead_offline.start["pending_orphan_leaves"] == [
             %{
               "slot" => "reviewer",
               "session" => "ses_r27_p1_3_orphan_A",
               "claim_token" => "inv_r27_p1_3_A"
             }
           ]

    # Station reconnects with new transport & run_id; task.leave succeeds now!
    Agent.update(fail_leave, fn _ -> false end)
    tr_2 = "tr_r27_p1_3_reconn_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^tr_2, rec_2} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r27_p1_3_2",
          "name" => "R27 Station",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_2
      )

    {:ok, %{}} =
      StationTasks.hello(
        %{
          tenant_id: ctx.tenant,
          group_id: ctx.group,
          device_id: ctx.device,
          connector_run_id: rec_2["connector_run_id"]
        },
        %{"tasks" => [%{"task" => conv, "fetched" => 0}]}
      )

    settle_receive(:r27_p1_3_reconnected_and_bound)

    {:ok, rows_after} = StationTaskSessions.of_task(ctx.group, conv)
    lead_after = Enum.find(rows_after, &(&1.session == "ses_r27_p1_3_lead"))
    b_row = Enum.find(rows_after, &(&1.session == "ses_r27_p1_3_B"))
    assert lead_after != nil
    assert lead_after.start["pending_orphan_leaves"] == nil
    assert b_row != nil

    # Verify ordering: fenced task.leave(claim_token: "inv_r27_p1_3_A") executed BEFORE B's task.invite!
    recorded = Agent.get(events, & &1)

    leave_idx =
      Enum.find_index(recorded, fn
        {:leave, p} ->
          p["slot"] == "reviewer" and p["session"] == "ses_r27_p1_3_orphan_A" and
            p["claim_token"] == "inv_r27_p1_3_A"

        _ ->
          false
      end)

    b_invite_idx =
      Enum.find_index(recorded, fn
        {:invite, p} -> p["invite_id"] == "inv_r27_p1_3_B"
        _ -> false
      end)

    assert is_integer(leave_idx)
    assert is_integer(b_invite_idx)
    assert leave_idx < b_invite_idx
  end

  test "R28 P1-2, P1-3, P1-4: quiet task confirms X via confirmed_claims and reconciles Y by invite_id; unpersisted offline leave falls back to pending_leave; reviewer leave timeout never starves qa or busy-waits 0ms",
       ctx do
    # ── 1. R28 P1-2: Quiet task (0 messages) sends empty-message task.put with confirmed_claims
    # to confirm X, marks claim_confirmed: true, and reconciles same-slot pending Y by invite_id! ──
    {:ok, _} = FakeConversations.start_link(messages: [])

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    tr_1 = "tr_r28_p1_2_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^tr_1, rec_1} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r28_p1_2",
          "name" => "R28 Station",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_1
      )

    run_1 = rec_1["connector_run_id"]
    conv_1 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1,
        device_id: ctx.device,
        session: "ses_r28_lead_1",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_1}
      })

    # X is bound on reviewer with claim_token "inv_r28_X" and claim_confirmed: false
    {:ok, _} =
      StationTaskSessions.append_pending_multi_start(ctx.group, conv_1, ctx.device, %{
        "slot" => "reviewer",
        "is_primary" => false,
        "agent_id" => ctx.agent,
        "invite_id" => "inv_r28_X",
        "start" => %{"slot" => "reviewer", "is_primary" => false}
      })

    assert :ok =
             StationTasks.register_slot_binding(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_1,
               device_id: ctx.device,
               session: "ses_r28_X",
               agent_id: ctx.agent,
               answered: 0,
               expected_pending_invite_id: "inv_r28_X",
               start: %{"slot" => "reviewer", "is_primary" => false, "connector_run_id" => run_1},
               give: false
             })

    {:ok, 1} =
      StationTaskSessions.remove_pending_multi_starts(ctx.group, conv_1, ctx.device, [
        {"reviewer", "inv_r28_X"}
      ])

    # Y is now pending on the SAME slot "reviewer" with invite_id "inv_r28_Y"
    {:ok, _} =
      StationTaskSessions.append_pending_multi_start(ctx.group, conv_1, ctx.device, %{
        "slot" => "reviewer",
        "is_primary" => false,
        "agent_id" => ctx.agent,
        "invite_id" => "inv_r28_Y",
        "start" => %{"slot" => "reviewer", "is_primary" => false}
      })

    test_pid = self()
    put_claims = Agent.start_link(fn -> [] end) |> elem(1)
    y_invites = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(put_claims), do: Agent.stop(put_claims) end)
    on_exit(fn -> if Process.alive?(y_invites), do: Agent.stop(y_invites) end)

    FakeConnector.on("task.put", fn params ->
      if is_list(params["confirmed_claims"]) do
        Agent.update(put_claims, &[params["confirmed_claims"] | &1])
      end

      send(test_pid, :r28_quiet_put_sent)

      {:ok,
       %{
         "through" => 0,
         "present_slots" => [
           %{"slot" => "lead", "session" => "ses_r28_lead_1"},
           %{"slot" => "reviewer", "session" => "ses_r28_X"}
         ],
         "committed_slots" => [
           %{"slot" => "lead", "session" => "ses_r28_lead_1"},
           %{"slot" => "reviewer", "session" => "ses_r28_X"}
         ],
         "confirmed_claims" => params["confirmed_claims"] || []
       }}
    end)

    FakeConnector.on("task.invite", fn params ->
      Agent.update(y_invites, &[params | &1])
      {:ok, %{"session" => "ses_r28_X", "slot" => "reviewer"}}
    end)

    # Trigger hello on quiet task (0 messages): Y MUST NOT be filtered by bare slot name,
    # Y commits into committed_invite_ids AND empty-message task.put confirms X!
    {:ok, %{}} =
      StationTasks.hello(
        %{
          tenant_id: ctx.tenant,
          group_id: ctx.group,
          device_id: ctx.device,
          connector_run_id: run_1
        },
        %{"tasks" => [%{"task" => conv_1, "fetched" => 0}]}
      )

    settle_receive(:r28_quiet_put_sent)

    settle_until(fn ->
      {:ok, rows_now} = StationTaskSessions.of_task(ctx.group, conv_1)
      x_now = Enum.find(rows_now, &(&1.session == "ses_r28_X"))

      x_now != nil and x_now.start["claim_confirmed"] == true and
        "inv_r28_Y" in List.wrap(x_now.start["committed_invite_ids"])
    end)

    claims_sent = Agent.get(put_claims, & &1) |> List.flatten()

    assert Enum.any?(claims_sent, fn c ->
             c["slot"] == "reviewer" and c["session"] == "ses_r28_X" and
               c["claim_token"] == "inv_r28_X"
           end)

    {:ok, rows_1} = StationTaskSessions.of_task(ctx.group, conv_1)
    x_row = Enum.find(rows_1, &(&1.session == "ses_r28_X"))
    assert x_row.start["claim_confirmed"] == true
    assert "inv_r28_X" in x_row.start["committed_invite_ids"]
    assert "inv_r28_Y" in x_row.start["committed_invite_ids"]

    # ── 2. R28 P1-4: Online reviewer orphan leave timeout MUST NOT starve independent qa slot,
    # MUST persist reviewer backoff next_retry_at > now_ms, and NEVER busy-wait 0ms! ──
    conv_2 = Ids.new_conversation_id()
    now_ms = SystemsClock.system_time(:millisecond)

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2,
        device_id: ctx.device,
        session: "ses_r28_lead_2",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_1,
          "pending_orphan_leaves" => [
            %{
              "slot" => "reviewer",
              "session" => "ses_r28_orphan_rev",
              "claim_token" => "inv_r28_orphan_rev"
            }
          ],
          "pending_multi_starts" => [
            %{
              "slot" => "reviewer",
              "is_primary" => false,
              "agent_id" => ctx.agent,
              "invite_id" => "inv_r28_rev_blocked",
              "start" => %{"slot" => "reviewer", "is_primary" => false}
            },
            %{
              "slot" => "qa",
              "is_primary" => false,
              "agent_id" => ctx.agent,
              "invite_id" => "inv_r28_qa_due",
              "next_retry_at" => now_ms - 5_000,
              "start" => %{"slot" => "qa", "is_primary" => false}
            }
          ]
        }
      })

    qa_invited = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(qa_invited), do: Agent.stop(qa_invited) end)

    FakeConnector.on("task.leave", fn _params ->
      {:error, :timeout}
    end)

    FakeConnector.on("task.invite", fn params ->
      Agent.update(qa_invited, &[params["slot"] | &1])

      if params["slot"] == "qa" do
        send(test_pid, :r28_qa_invited)
        {:ok, %{"session" => "ses_r28_qa_live", "slot" => "qa"}}
      else
        {:ok, %{"session" => "ses_unexpected", "slot" => params["slot"]}}
      end
    end)

    FakeConnector.on("task.put", fn params ->
      {:ok,
       %{
         "through" => 0,
         "present_slots" => [
           %{"slot" => "lead", "session" => "ses_r28_lead_2"},
           %{"slot" => "qa", "session" => "ses_r28_qa_live"}
         ],
         "committed_slots" => [
           %{"slot" => "lead", "session" => "ses_r28_lead_2"},
           %{"slot" => "qa", "session" => "ses_r28_qa_live"}
         ],
         "confirmed_claims" => params["confirmed_claims"] || []
       }}
    end)

    StationTasks.give(ctx.group, conv_2, ctx.device)
    settle_receive(:r28_qa_invited)

    settle_until(fn ->
      {:ok, rows_now} = StationTaskSessions.of_task(ctx.group, conv_2)
      Enum.any?(rows_now, &(&1.session == "ses_r28_qa_live"))
    end)

    # qa was invited and bound cleanly, while reviewer remained blocked (NOT invited)!
    invited_slots = Agent.get(qa_invited, & &1)
    assert "qa" in invited_slots
    refute "reviewer" in invited_slots

    {:ok, rows_2} = StationTaskSessions.of_task(ctx.group, conv_2)
    assert Enum.any?(rows_2, &(&1.session == "ses_r28_qa_live"))
    lead_2 = Enum.find(rows_2, &(&1.session == "ses_r28_lead_2"))
    [orphan_after] = lead_2.start["pending_orphan_leaves"]
    assert orphan_after["attempts"] >= 1
    assert orphan_after["next_retry_at"] >= now_ms + 1_000

    # ── 3. R28 P1-3: record_pending_orphan_leave DB timeout + offline task.leave falls back to
    # schedule_pending_leave so revocation is NEVER silently dropped! ──
    conv_3 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_3,
        device_id: ctx.device,
        session: "ses_r28_lead_3",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_1}
      })

    defmodule FailOrphanRecordSessions do
      def record_pending_orphan_leave(_g, _c, _d, _entry), do: {:error, :db_timeout}

      def remove_pending_orphan_leave(g, c, d, sl, s, t),
        do: StationTaskSessions.remove_pending_orphan_leave(g, c, d, sl, s, t)

      def update_pending_orphan_leave_backoff(g, c, d, sl, s, t, m),
        do: StationTaskSessions.update_pending_orphan_leave_backoff(g, c, d, sl, s, t, m)

      def mark_claims_confirmed(g, c, d, sessions),
        do: StationTaskSessions.mark_claims_confirmed(g, c, d, sessions)

      def remove_pending_multi_starts(g, c, d, slots),
        do: StationTaskSessions.remove_pending_multi_starts(g, c, d, slots)

      def update_pending_multi_starts_backoff(g, c, d, updates),
        do: StationTaskSessions.update_pending_multi_starts_backoff(g, c, d, updates)

      def ensure_pending_invite_id(g, c, d, slot, entry),
        do: StationTaskSessions.ensure_pending_invite_id(g, c, d, slot, entry)
    end

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations,
      task_sessions: FailOrphanRecordSessions
    )

    FakeConnector.on("task.leave", fn _params -> {:error, :disconnected} end)

    FakeConnector.on("task.invite", fn _params ->
      {:ok, 1} =
        StationTaskSessions.remove_pending_multi_starts(ctx.group, conv_3, ctx.device, [
          {"reviewer", "inv_r28_p1_3_A"}
        ])

      {:ok, %{"session" => "ses_r28_p1_3_orphan", "slot" => "reviewer"}}
    end)

    assert {:error, {:orphan_leave_unpersisted, {:error, :db_timeout}}} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_3,
               device_id: ctx.device,
               agent_id: ctx.agent,
               invite_id: "inv_r28_p1_3_A",
               slot: "reviewer",
               start: %{"slot" => "reviewer", "is_primary" => false}
             })

    # Recoverable pending_leave worker MUST be registered in StationTasks.Registry!
    key =
      {:pending_leave, ctx.group, conv_3, ctx.device, "reviewer", "inv_r28_p1_3_A"}

    settle_until(fn ->
      match?([{_pid, _}], SystemsRuntime.Registry.lookup(SalixWeb.StationTasks.Registry, key))
    end)

    assert [{_pid, _}] = SystemsRuntime.Registry.lookup(SalixWeb.StationTasks.Registry, key)
  end

  test "R29 P0-2/P0-3/P1-4/P1-5: recovery claim_token, committed_slots, mark_claims_confirmed backoff, orphan leave drain",
       ctx do
    {:ok, _} = FakeConversations.start_link(messages: [])

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    tr_1 = "tr_r29_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^tr_1, rec_1} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r29",
          "name" => "R29 Station",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_1
      )

    run_1 = rec_1["connector_run_id"]
    test_pid = self()

    # ── 1. R29 P0-2: Demoted reviewer (old token A, claim_confirmed: true) recovers with NEW token B,
    # claim_confirmed: false, and do_put sends confirmed_claims with B! ──
    conv_1 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1,
        device_id: ctx.device,
        session: "ses_r29_lead_1",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_1}
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1,
        device_id: ctx.device,
        session: "ses_r29_rev_old",
        agent_id: ctx.agent,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "connector_run_id" => run_1,
          "claim_token" => "tok_old_A",
          "claim_confirmed" => true,
          "invite_id" => "tok_old_A"
        }
      })

    {:ok, rows_before} = StationTaskSessions.of_task(ctx.group, conv_1)
    rev_old = Enum.find(rows_before, &(&1.session == "ses_r29_rev_old"))

    assert :ok =
             StationTaskSessions.demote_missing_secondaries(
               ctx.group,
               conv_1,
               ctx.device,
               [rev_old],
               run_1
             )

    {:ok, [lead_demoted]} = StationTaskSessions.of_task(ctx.group, conv_1)
    [pending_rev] = lead_demoted.start["pending_multi_starts"]
    new_token_b = pending_rev["invite_id"]
    assert new_token_b != "tok_old_A"

    assert :ok =
             StationTasks.register_slot_binding(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_1,
               device_id: ctx.device,
               session: "ses_r29_rev_new",
               agent_id: ctx.agent,
               answered: 0,
               expected_pending_invite_id: new_token_b,
               start: Map.put(pending_rev["start"], "connector_run_id", run_1),
               give: false
             })

    {:ok, rows_rec} = StationTaskSessions.of_task(ctx.group, conv_1)
    rev_new = Enum.find(rows_rec, &(&1.session == "ses_r29_rev_new"))
    assert rev_new.start["claim_token"] == new_token_b
    assert rev_new.start["claim_confirmed"] == false

    # ── 2. R29 P0-3b: Station ACK returns present_slots WITH reviewer, but committed_slots WITHOUT reviewer ->
    # reviewer's sent MUST stay 0, claim_confirmed MUST stay false, and reviewer is NOT demoted! ──
    FakeConnector.on("task.put", fn _params ->
      send(test_pid, :r29_p03_put_done)

      {:ok,
       %{
         "through" => 5,
         "present_slots" => [
           %{"slot" => "lead", "session" => "ses_r29_lead_1"},
           %{"slot" => "reviewer", "session" => "ses_r29_rev_new"}
         ],
         "committed_slots" => [
           %{"slot" => "lead", "session" => "ses_r29_lead_1"}
         ]
       }}
    end)

    {:ok, 1} =
      StationTaskSessions.remove_pending_multi_starts(ctx.group, conv_1, ctx.device, [
        {"reviewer", new_token_b}
      ])

    StationTasks.give(ctx.group, conv_1, ctx.device)
    settle_receive(:r29_p03_put_done)

    {:ok, rows_uncommitted} = StationTaskSessions.of_task(ctx.group, conv_1)
    rev_uncommitted = Enum.find(rows_uncommitted, &(&1.session == "ses_r29_rev_new"))
    assert rev_uncommitted != nil
    assert rev_uncommitted.sent == 0
    assert rev_uncommitted.start["claim_confirmed"] == false

    # ── 3. R29 P1-4: mark_claims_confirmed DB failure stops recursive empty task.put loop! ──
    conv_2 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2,
        device_id: ctx.device,
        session: "ses_r29_lead_2",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_1,
          "claim_token" => "tok_r29_p14",
          "claim_confirmed" => false
        }
      })

    defmodule FailMarkConfirmedSessions do
      def mark_claims_confirmed(_g, _c, _d, _sessions), do: {:error, :db_unavailable}

      def record_pending_orphan_leave(g, c, d, e),
        do: StationTaskSessions.record_pending_orphan_leave(g, c, d, e)

      def remove_pending_orphan_leave(g, c, d, sl, s, t),
        do: StationTaskSessions.remove_pending_orphan_leave(g, c, d, sl, s, t)

      def update_pending_orphan_leave_backoff(g, c, d, sl, s, t, m),
        do: StationTaskSessions.update_pending_orphan_leave_backoff(g, c, d, sl, s, t, m)

      def remove_pending_multi_starts(g, c, d, slots),
        do: StationTaskSessions.remove_pending_multi_starts(g, c, d, slots)

      def update_pending_multi_starts_backoff(g, c, d, u),
        do: StationTaskSessions.update_pending_multi_starts_backoff(g, c, d, u)

      def ensure_pending_invite_id(g, c, d, sl, e),
        do: StationTaskSessions.ensure_pending_invite_id(g, c, d, sl, e)
    end

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations,
      task_sessions: FailMarkConfirmedSessions
    )

    put_count = Agent.start_link(fn -> 0 end) |> elem(1)
    on_exit(fn -> if Process.alive?(put_count), do: Agent.stop(put_count) end)

    FakeConnector.on("task.put", fn params ->
      c = Agent.get_and_update(put_count, fn n -> {n + 1, n + 1} end)
      send(test_pid, {:r29_p14_put, c})

      {:ok,
       %{
         "through" => 0,
         "present_slots" => [%{"slot" => "lead", "session" => "ses_r29_lead_2"}],
         "committed_slots" => [%{"slot" => "lead", "session" => "ses_r29_lead_2"}],
         "confirmed_claims" => params["confirmed_claims"] || []
       }}
    end)

    StationTasks.give(ctx.group, conv_2, ctx.device)
    settle_receive({:r29_p14_put, 1})
    settle_refute_receive({:r29_p14_put, 2})

    # ── 4. R29 P1-5: session-less {slot, "", inv_A} orphan leave recorded atomically on remove
    # drains cleanly on reconnect with claim_token: inv_A! ──
    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    conv_3 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_3,
        device_id: ctx.device,
        session: "ses_r29_lead_3",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_1,
          "pending_multi_starts" => [
            %{
              "slot" => "reviewer",
              "is_primary" => false,
              "invite_id" => "inv_r29_p15_orphan",
              "start" => %{"slot" => "reviewer", "is_primary" => false}
            }
          ]
        }
      })

    assert {:ok, 1} =
             StationTaskSessions.remove_pending_multi_starts(
               ctx.group,
               conv_3,
               ctx.device,
               [{"reviewer", "inv_r29_p15_orphan"}],
               record_orphan_claim?: true
             )

    FakeConnector.on("task.leave", fn params ->
      send(test_pid, {:r29_p15_leave, params})
      {:ok, %{"ok" => true, "removed" => true, "kept" => false}}
    end)

    {:ok, %{}} =
      StationTasks.hello(
        %{
          tenant_id: ctx.tenant,
          group_id: ctx.group,
          device_id: ctx.device,
          connector_run_id: run_1
        },
        %{"tasks" => [%{"task" => conv_3, "fetched" => 0}]}
      )

    settle_receive({:r29_p15_leave, leave_params})
    assert leave_params["slot"] == "reviewer"
    assert leave_params["claim_token"] == "inv_r29_p15_orphan"

    settle_until(fn ->
      {:ok, [l]} = StationTaskSessions.of_task(ctx.group, conv_3)
      l.start["pending_orphan_leaves"] == nil
    end)
  end

  test "R30 P0-1/P0-2/P1-1/P1-2/P1-3: fenced leave capability gate, committed_slots override & unconfirm, 101 invisible-page pagination, unconfirmed-vs-confirmed pagination, and dispatched-aware orphan recording",
       ctx do
    test_pid = self()

    # ── 1. R30 P0-1: Old Station (no multi_session_tasks) reconnect MUST send 0 task.leave RPCs,
    # keep pending_orphan_leaves with backoff, and drain cleanly once compatible Station connects! ──
    {:ok, _} = FakeConversations.start_link(messages: [])

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    tr_old = "tr_r30_old_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^tr_old, rec_old} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r30_old",
          "name" => "Old Station",
          "capabilities" => %{"tasks" => 2}
        },
        transport_id: tr_old
      )

    conv_1 = Ids.new_conversation_id()
    now_ms = SystemsClock.system_time(:millisecond)

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1,
        device_id: ctx.device,
        session: "ses_r30_lead_1",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => rec_old["connector_run_id"],
          "pending_orphan_leaves" => [
            %{
              "slot" => "reviewer",
              "session" => "ses_r30_orphan_1",
              "claim_token" => "inv_r30_orphan_1"
            }
          ]
        }
      })

    leave_calls = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(leave_calls), do: Agent.stop(leave_calls) end)

    FakeConnector.on("task.leave", fn params ->
      Agent.update(leave_calls, &[params | &1])
      send(test_pid, {:r30_p01_leave, params})
      {:ok, %{"ok" => true, "removed" => true, "kept" => false}}
    end)

    {:ok, %{}} =
      StationTasks.hello(
        %{
          tenant_id: ctx.tenant,
          group_id: ctx.group,
          device_id: ctx.device,
          connector_run_id: rec_old["connector_run_id"]
        },
        %{"tasks" => [%{"task" => conv_1, "fetched" => 0}]}
      )

    settle_until(fn ->
      {:ok, [l]} = StationTaskSessions.of_task(ctx.group, conv_1)

      case l.start["pending_orphan_leaves"] do
        [%{"attempts" => a, "next_retry_at" => t}] when a >= 1 and t >= now_ms + 1_000 -> true
        _ -> false
      end
    end)

    # Zero task.leave RPCs sent to old Station!
    assert Agent.get(leave_calls, & &1) == []

    # Compatible Station reconnects -> after backoff elapses, fenced leave drains cleanly!
    tr_new = "tr_r30_new_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^tr_new, rec_new} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r30_new",
          "name" => "New Station",
          "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
        },
        transport_id: tr_new
      )

    run_new = rec_new["connector_run_id"]
    SystemsClock.advance(2_000)

    {:ok, %{}} =
      StationTasks.hello(
        %{
          tenant_id: ctx.tenant,
          group_id: ctx.group,
          device_id: ctx.device,
          connector_run_id: run_new
        },
        %{"tasks" => [%{"task" => conv_1, "fetched" => 0}]}
      )

    settle_receive({:r30_p01_leave, p01_leave})
    assert p01_leave["claim_token"] == "inv_r30_orphan_1"

    settle_until(fn ->
      {:ok, [l]} = StationTaskSessions.of_task(ctx.group, conv_1)
      l.start["pending_orphan_leaves"] == nil
    end)

    # ── 2. R30 P0-2: (a) Legacy task.put ACK without present_slots when confirmed_claims sent
    # NEVER advances sent or marks claim_confirmed; (b) Explicit committed_slots negation
    # overrides local claim_confirmed: true, resets it to false, and next put re-confirms! ──
    FakeConversations.stop()

    {:ok, _} =
      FakeConversations.start_link(
        messages: [%{"seq" => 1, "content" => "m1", "actor_type" => "user", "user_id" => "u1"}]
      )

    conv_2a = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2a,
        device_id: ctx.device,
        session: "ses_r30_2a_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_new,
          "claim_token" => "tok_2a",
          "claim_confirmed" => false
        }
      })

    FakeConnector.on("task.put", fn _params ->
      send(test_pid, :r30_2a_put)
      {:ok, %{"ok" => true}}
    end)

    StationTasks.give(ctx.group, conv_2a, ctx.device)
    settle_receive(:r30_2a_put)

    {:ok, [r2a]} = StationTaskSessions.of_task(ctx.group, conv_2a)
    assert r2a.sent == 0
    assert r2a.start["claim_confirmed"] == false

    # (b) Local claim_confirmed: true overridden by Station explicit committed_slots: [] -> reset to false!
    conv_2b = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2b,
        device_id: ctx.device,
        session: "ses_r30_2b_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_new,
          "claim_token" => "tok_2b",
          "claim_confirmed" => true
        }
      })

    FakeConnector.on("task.put", fn _params ->
      send(test_pid, :r30_2b_put)

      {:ok,
       %{
         "through" => 1,
         "present_slots" => [%{"slot" => "lead", "session" => "ses_r30_2b_lead"}],
         "committed_slots" => []
       }}
    end)

    StationTasks.give(ctx.group, conv_2b, ctx.device)
    settle_receive(:r30_2b_put)

    settle_until(fn ->
      {:ok, [r2b]} = StationTaskSessions.of_task(ctx.group, conv_2b)
      r2b.sent == 0 and r2b.start["claim_confirmed"] == false
    end)

    # ── 3. R30 P1-1: 101 messages where 1..100 are invisible to sole worker and 101 is visible ->
    # single give advances past 100 and delivers 101 (NOT truncated by quiet_confirm?)! ──
    FakeConversations.stop()

    msgs_101 =
      for seq <- 1..101 do
        if seq <= 100 do
          %{
            "seq" => seq,
            "content" => "hidden-#{seq}",
            "actor_type" => "user",
            "user_id" => "u1",
            "delivery_filter" => %{"participant_ids" => ["prt_someone_else"]}
          }
        else
          %{
            "seq" => seq,
            "content" => "visible-101",
            "actor_type" => "user",
            "user_id" => "u1"
          }
        end
      end

    {:ok, _} =
      FakeConversations.start_link(
        participants: [
          %{
            "participant_id" => "prt_r30_lead",
            "actor_type" => "agent",
            "role_label" => "worker",
            "target_key" => "lead",
            "state" => "active"
          }
        ],
        messages: msgs_101
      )

    conv_3 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_3,
        device_id: ctx.device,
        session: "ses_r30_3_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "participant_id" => "prt_r30_lead",
          "connector_run_id" => run_new
        }
      })

    put_throughs_3 = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(put_throughs_3), do: Agent.stop(put_throughs_3) end)

    FakeConnector.on("task.put", fn params ->
      Agent.update(put_throughs_3, &[params["through"] | &1])

      {:ok,
       %{
         "through" => params["through"],
         "present_slots" => [%{"slot" => "lead", "session" => "ses_r30_3_lead"}],
         "committed_slots" => [%{"slot" => "lead", "session" => "ses_r30_3_lead"}]
       }}
    end)

    StationTasks.give(ctx.group, conv_3, ctx.device)

    settle_until(fn ->
      {:ok, [r3]} = StationTaskSessions.of_task(ctx.group, conv_3)
      r3.sent == 101
    end)

    assert 101 in Agent.get(put_throughs_3, & &1)

    # ── 4. R30 P1-2 + R31 self-review: lead (confirmed, answered=50) + reviewer (unconfirmed,
    # answered=0, sent=0) with 101 messages -> lead advances to sent == 101 while reviewer stays
    # sent == 0 & claim_confirmed == false, AND page-2 task.put still carries full multi-slot
    # roster, answered_by_slot, conservative min(answered)==0, and NO reviewer confirmed_claims! ──
    conv_4 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_4,
        device_id: ctx.device,
        session: "ses_r30_4_lead",
        agent_id: ctx.agent,
        answered: 50,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "participant_id" => "prt_r30_lead",
          "connector_run_id" => run_new,
          "claim_token" => "tok_r30_4_lead",
          "claim_confirmed" => true
        }
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_4,
        device_id: ctx.device,
        session: "ses_r30_4_rev",
        agent_id: ctx.agent,
        answered: 0,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "connector_run_id" => run_new,
          "claim_token" => "tok_r30_4_rev",
          "claim_confirmed" => false
        }
      })

    put_calls_4 = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(put_calls_4), do: Agent.stop(put_calls_4) end)

    FakeConnector.on("task.put", fn params ->
      Agent.update(put_calls_4, &[params | &1])

      {:ok,
       %{
         "through" => params["through"],
         "present_slots" => [
           %{"slot" => "lead", "session" => "ses_r30_4_lead"},
           %{"slot" => "reviewer", "session" => "ses_r30_4_rev"}
         ],
         "committed_slots" => [
           %{"slot" => "lead", "session" => "ses_r30_4_lead"}
         ]
       }}
    end)

    StationTasks.give(ctx.group, conv_4, ctx.device)

    settle_until(fn ->
      {:ok, rows_4} = StationTaskSessions.of_task(ctx.group, conv_4)
      lead_4 = Enum.find(rows_4, &(&1.session == "ses_r30_4_lead"))
      lead_4 != nil and lead_4.sent == 101
    end)

    {:ok, rows_4} = StationTaskSessions.of_task(ctx.group, conv_4)
    rev_4 = Enum.find(rows_4, &(&1.session == "ses_r30_4_rev"))
    assert rev_4.sent == 0
    assert rev_4.start["claim_confirmed"] == false

    page2_put_4 =
      Agent.get(put_calls_4, & &1)
      |> Enum.find(&(&1["through"] == 101))

    assert page2_put_4 != nil
    assert is_list(page2_put_4["roster"])
    assert Enum.map(page2_put_4["roster"], & &1["slot"]) |> Enum.sort() == ["lead", "reviewer"]
    assert page2_put_4["answered_by_slot"] == %{"lead" => 50, "reviewer" => 0}
    # Conservative thread_answered = min(50, 0) = 0 (never raised to lead's 50; omitted when 0)
    assert Map.get(page2_put_4, "answered", 0) == 0
    # Page 2 drains confirmed `lead` only: must NOT carry reviewer's confirmed_claims
    refute Enum.any?(page2_put_4["confirmed_claims"] || [], &(&1["slot"] == "reviewer"))
    assert Map.get(page2_put_4, "confirmed_claims") == nil

    # ── 4b. R31 self-review P1: `task.status` fallback (committed_slots == nil) preserves
    # already-confirmed `lead` (`claim_confirmed: true`) and does NOT reset it to false, while
    # still keeping unconfirmed `reviewer` at sent == 0 & claim_confirmed == false! ──
    conv_4b = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_4b,
        device_id: ctx.device,
        session: "ses_r30_4b_lead",
        agent_id: ctx.agent,
        answered: 10,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "participant_id" => "prt_r30_lead",
          "connector_run_id" => run_new,
          "claim_token" => "tok_r30_4b_lead",
          "claim_confirmed" => true
        }
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_4b,
        device_id: ctx.device,
        session: "ses_r30_4b_rev",
        agent_id: ctx.agent,
        answered: 0,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "connector_run_id" => run_new,
          "claim_token" => "tok_r30_4b_rev",
          "claim_confirmed" => false
        }
      })

    FakeConnector.on("task.put", fn params ->
      # Legacy multi-session ACK without present_slots / committed_slots -> triggers task.status fallback
      {:ok, %{"through" => params["through"]}}
    end)

    FakeConnector.on("task.status", fn _params ->
      {:ok,
       %{
         "slots" => [
           %{"slot" => "lead", "session" => "ses_r30_4b_lead", "state" => "idle", "pending" => 0},
           %{
             "slot" => "reviewer",
             "session" => "ses_r30_4b_rev",
             "state" => "idle",
             "pending" => 0
           }
         ]
       }}
    end)

    StationTasks.give(ctx.group, conv_4b, ctx.device)

    settle_until(fn ->
      {:ok, rows_4b} = StationTaskSessions.of_task(ctx.group, conv_4b)
      lead_4b = Enum.find(rows_4b, &(&1.session == "ses_r30_4b_lead"))
      lead_4b != nil and lead_4b.sent == 101
    end)

    {:ok, rows_4b} = StationTaskSessions.of_task(ctx.group, conv_4b)
    lead_4b = Enum.find(rows_4b, &(&1.session == "ses_r30_4b_lead"))
    rev_4b = Enum.find(rows_4b, &(&1.session == "ses_r30_4b_rev"))
    assert lead_4b.start["claim_confirmed"] == true
    assert rev_4b.sent == 0
    assert rev_4b.start["claim_confirmed"] == false

    # ── 5. R30 P1-3: Dispatched entry hitting :station_outdated records {slot, "", invite_id}
    # in pending_orphan_leaves; never-dispatched entry hitting :station_outdated does NOT! ──
    FakeConversations.stop()
    {:ok, _} = FakeConversations.start_link(messages: [])

    tr_old2 = "tr_r30_old2_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^tr_old2, rec_old2} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r30_old2",
          "name" => "Old Station 2",
          "capabilities" => %{"tasks" => 2}
        },
        transport_id: tr_old2
      )

    conv_5 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_5,
        device_id: ctx.device,
        session: "ses_r30_5_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => rec_old2["connector_run_id"],
          "pending_multi_starts" => [
            %{
              "slot" => "reviewer",
              "is_primary" => false,
              "invite_id" => "inv_r30_dispatched",
              "dispatched" => true,
              "start" => %{"slot" => "reviewer", "is_primary" => false}
            },
            %{
              "slot" => "qa",
              "is_primary" => false,
              "invite_id" => "inv_r30_never_sent",
              "start" => %{"slot" => "qa", "is_primary" => false}
            }
          ]
        }
      })

    StationTasks.give(ctx.group, conv_5, ctx.device)

    settle_until(fn ->
      {:ok, [l5]} = StationTaskSessions.of_task(ctx.group, conv_5)
      l5.start["pending_multi_starts"] == nil
    end)

    {:ok, [l5_after]} = StationTaskSessions.of_task(ctx.group, conv_5)
    orphans_5 = l5_after.start["pending_orphan_leaves"] || []

    assert Enum.any?(orphans_5, fn o ->
             o["slot"] == "reviewer" and o["session"] == "" and
               o["claim_token"] == "inv_r30_dispatched"
           end)

    refute Enum.any?(orphans_5, fn o ->
             o["slot"] == "qa" or o["claim_token"] == "inv_r30_never_sent"
           end)
  end

  test "R31 P0-1/P0-2/P1-3/P1-4/P1-5: active-row orphan guard, pinned pagination generation fencing, linearized dispatched/remove, missing-thread idempotent leave, and run_id-fenced claim_confirmed",
       ctx do
    test_pid = self()

    # ── 1. R31 P0-1: remove_pending_multi_starts NEVER writes pending_orphan_leaves for an
    # invite_id already registered on an active row (invite_id / claim_token / committed_invite_ids). ──
    run_a = register_device(ctx, "r31_a", %{"tasks" => 2, "multi_session_tasks" => true})
    conv_1 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1,
        device_id: ctx.device,
        session: "ses_r31_p01_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_a,
          "pending_multi_starts" => [
            %{
              "slot" => "reviewer",
              "is_primary" => false,
              "invite_id" => "inv_r31_p01_committed",
              "dispatched" => true,
              "start" => %{"slot" => "reviewer", "is_primary" => false}
            }
          ]
        }
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1,
        device_id: ctx.device,
        session: "ses_r31_p01_rev",
        agent_id: ctx.agent,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "connector_run_id" => run_a,
          "invite_id" => "inv_r31_p01_committed",
          "claim_token" => "inv_r31_p01_committed"
        }
      })

    assert {:ok, 1} =
             StationTaskSessions.remove_pending_multi_starts(
               ctx.group,
               conv_1,
               ctx.device,
               [{"reviewer", "inv_r31_p01_committed", :record_orphan}],
               []
             )

    {:ok, rows_1} = StationTaskSessions.of_task(ctx.group, conv_1)
    lead_1 = Enum.find(rows_1, &(&1.session == "ses_r31_p01_lead"))
    assert lead_1.start["pending_multi_starts"] == nil
    assert lead_1.start["pending_orphan_leaves"] == nil

    # ── 2. R31 P1-3: mark_pending_multi_start_dispatched returns :pending_invite_not_found /
    # :pending_deactivation under lock; remove_pending_multi_starts with :record_orphan_if_dispatched
    # checks latest DB row inside lock_device_tx! ──
    conv_3 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_3,
        device_id: ctx.device,
        session: "ses_r31_p13_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_a,
          "pending_multi_starts" => [
            %{
              "slot" => "reviewer",
              "is_primary" => false,
              "invite_id" => "inv_r31_p13_disp",
              "start" => %{"slot" => "reviewer", "is_primary" => false}
            },
            %{
              "slot" => "qa",
              "is_primary" => false,
              "invite_id" => "inv_r31_p13_undisp",
              "start" => %{"slot" => "qa", "is_primary" => false}
            },
            %{
              "slot" => "ops",
              "is_primary" => false,
              "invite_id" => "inv_r31_p13_deact",
              "pending_deactivation" => true,
              "start" => %{"slot" => "ops", "is_primary" => false}
            }
          ]
        }
      })

    assert {:error, :pending_invite_not_found} =
             StationTaskSessions.mark_pending_multi_start_dispatched(
               ctx.group,
               conv_3,
               ctx.device,
               "reviewer",
               "inv_wrong_id"
             )

    assert {:error, :pending_deactivation} =
             StationTaskSessions.mark_pending_multi_start_dispatched(
               ctx.group,
               conv_3,
               ctx.device,
               "ops",
               "inv_r31_p13_deact"
             )

    assert :ok =
             StationTaskSessions.mark_pending_multi_start_dispatched(
               ctx.group,
               conv_3,
               ctx.device,
               "reviewer",
               "inv_r31_p13_disp"
             )

    assert {:ok, 2} =
             StationTaskSessions.remove_pending_multi_starts(
               ctx.group,
               conv_3,
               ctx.device,
               [
                 {"reviewer", "inv_r31_p13_disp", :record_orphan_if_dispatched},
                 {"qa", "inv_r31_p13_undisp", :record_orphan_if_dispatched}
               ],
               []
             )

    {:ok, [lead_3]} = StationTaskSessions.of_task(ctx.group, conv_3)
    orphans_3 = lead_3.start["pending_orphan_leaves"] || []

    assert Enum.any?(orphans_3, fn o ->
             o["slot"] == "reviewer" and o["session"] == "" and
               o["claim_token"] == "inv_r31_p13_disp"
           end)

    refute Enum.any?(orphans_3, fn o ->
             o["slot"] == "qa" or o["claim_token"] == "inv_r31_p13_undisp"
           end)

    # ── 3. R31 P1-4 (Salix side): drain_pending_orphan_leaves clears entry on idempotent
    # {ok: true, removed: false, kept: false} from a missing-thread compatible Station! ──
    {:ok, _} = FakeConversations.start_link(messages: [])

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    conv_4 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_4,
        device_id: ctx.device,
        session: "ses_r31_p14_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_a,
          "pending_orphan_leaves" => [
            %{
              "slot" => "reviewer",
              "session" => "",
              "claim_token" => "inv_r31_p14_missing"
            }
          ]
        }
      })

    FakeConnector.on("task.leave", fn params ->
      send(test_pid, {:r31_p14_leave, params})
      {:ok, %{"ok" => true, "removed" => false, "kept" => false}}
    end)

    StationTasks.give(ctx.group, conv_4, ctx.device)
    settle_receive({:r31_p14_leave, p14_leave})
    assert p14_leave["claim_token"] == "inv_r31_p14_missing"

    settle_until(fn ->
      {:ok, [l4]} = StationTaskSessions.of_task(ctx.group, conv_4)
      l4.start["pending_orphan_leaves"] == nil
    end)

    # ── 4. R31 P0-2 + R32 P0-1: Independent pagination pinned to run_A stops immediately when
    # device reconnects as run_B AFTER page 1 ACK is committed to DB and BEFORE page 2 task.put
    # is sent (inside `drain_confirmed_rows_pages`) -> run_B NEVER gets stale 101..200! ──
    FakeConversations.stop()

    msgs_201 =
      for seq <- 1..201 do
        %{
          "seq" => seq,
          "content" => "m-#{seq}",
          "actor_type" => "user",
          "user_id" => "u1"
        }
      end

    switched_2 = :atomics.new(1, [])

    {:ok, _} =
      FakeConversations.start_link(
        messages: msgs_201,
        on_messages_after: fn after_seq ->
          # Trigger reconnect STRICTLY when `drain_confirmed_rows_pages` reads page 2 (`after_seq == 100`),
          # i.e. AFTER page 1 ACK has already committed `lead.sent = 100` to DB and BEFORE page 2 `task.put`!
          if after_seq == 100 and :atomics.compare_exchange(switched_2, 1, 0, 1) == :ok do
            tr_b = "tr_r31_b_#{SystemsRuntime.Proc.unique_integer([:positive])}"

            {:ok, ^tr_b, rec_b} =
              Registry.connect(
                "test-node",
                %{
                  "tenant_id" => ctx.tenant,
                  "group_id" => ctx.group,
                  "device_id" => ctx.device,
                  "connector_id" => "conn_r31_b",
                  "name" => "Station B",
                  "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
                },
                transport_id: tr_b
              )

            send(test_pid, {:r31_p02_run_b, rec_b["connector_run_id"]})
          end
        end
      )

    conv_2 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2,
        device_id: ctx.device,
        session: "ses_r31_p02_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_a
        }
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_2,
        device_id: ctx.device,
        session: "ses_r31_p02_rev",
        agent_id: ctx.agent,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "connector_run_id" => run_a,
          "claim_token" => "tok_r31_p02_rev",
          "claim_confirmed" => false
        }
      })

    put_log_2 = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(put_log_2), do: Agent.stop(put_log_2) end)

    FakeConnector.on("task.put", fn run_id, params ->
      Agent.update(put_log_2, &[{run_id, params["through"]} | &1])

      {:ok,
       %{
         "through" => params["through"],
         "present_slots" => [
           %{"slot" => "lead", "session" => "ses_r31_p02_lead"},
           %{"slot" => "reviewer", "session" => "ses_r31_p02_rev"}
         ],
         "committed_slots" => [
           %{"slot" => "lead", "session" => "ses_r31_p02_lead"}
         ]
       }}
    end)

    StationTasks.give(ctx.group, conv_2, ctx.device)
    settle_receive({:r31_p02_run_b, run_b})

    # Page 1 committed lead.sent == 100 on run_A, then drain_confirmed_rows_pages saw run_B
    # and aborted page 2 without EVER sending 101..200 to run_B!
    SystemsClock.advance(200)
    calls_before_hello = Agent.get(put_log_2, &Enum.reverse(&1))
    assert Enum.any?(calls_before_hello, fn {rid, th} -> rid == run_a and th == 100 end)
    refute Enum.any?(calls_before_hello, fn {rid, _th} -> rid == run_b end)
    {:ok, rows_2_mid} = StationTaskSessions.of_task(ctx.group, conv_2)
    assert Enum.find(rows_2_mid, &(&1.session == "ses_r31_p02_lead")).sent == 100

    # Now run_B says hello (resetting fetched=0) -> run_B starts cleanly from 1..100 -> 200 -> 201!
    {:ok, %{}} =
      StationTasks.hello(
        %{
          tenant_id: ctx.tenant,
          group_id: ctx.group,
          device_id: ctx.device,
          connector_run_id: run_b
        },
        %{"tasks" => [%{"task" => conv_2, "fetched" => 0}]}
      )

    settle_until(fn ->
      {:ok, rows_2} = StationTaskSessions.of_task(ctx.group, conv_2)
      l2 = Enum.find(rows_2, &(&1.session == "ses_r31_p02_lead"))
      l2 != nil and l2.sent == 201
    end)

    run_b_throughs =
      Agent.get(put_log_2, &Enum.reverse(&1))
      |> Enum.filter(fn {rid, _} -> rid == run_b end)
      |> Enum.map(&elem(&1, 1))

    assert hd(run_b_throughs) == 100

    # ── 5. R31 P1-5: Delayed negative ACK from run_A after run_B took over S
    # (connector_run_id == run_B, claim_confirmed == true) NEVER resets claim_confirmed to false! ──
    conv_5 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_5,
        device_id: ctx.device,
        session: "ses_r31_p15_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => run_b,
          "claim_token" => "tok_r31_p15",
          "claim_confirmed" => true
        }
      })

    # Stale run_A attempting mark_claims_unconfirmed matches 0 rows due to connector_run_id fence!
    assert :ok =
             StationTaskSessions.mark_claims_unconfirmed(
               ctx.group,
               conv_5,
               ctx.device,
               ["ses_r31_p15_lead"],
               run_a
             )

    {:ok, [r5_after_stale]} = StationTaskSessions.of_task(ctx.group, conv_5)
    assert r5_after_stale.start["claim_confirmed"] == true

    # Matching run_B CAN reset claim_confirmed to false when Station explicitly negates it
    assert :ok =
             StationTaskSessions.mark_claims_unconfirmed(
               ctx.group,
               conv_5,
               ctx.device,
               ["ses_r31_p15_lead"],
               run_b
             )

    {:ok, [r5_after_live]} = StationTaskSessions.of_task(ctx.group, conv_5)
    assert r5_after_live.start["claim_confirmed"] == false
  end

  test "R32 P0-1/P1-4/P1-5: give_active generation pinning, old-binding-A vs dispatched-X orphan recording, and add_session idempotent :ok on background-completed X",
       ctx do
    test_pid = self()

    # ── 1. R32 P0-1 (normal give_active): lead has sent=100 under run_A; during give_active
    # between reading rows and sending task.put, Station reconnects as run_B (and hello resets
    # sent=0) -> run_B NEVER receives stale 101..200 and starts cleanly at 1..100! ──
    run_a = register_device(ctx, "r32_a", %{"tasks" => 2, "multi_session_tasks" => true})

    msgs_201 =
      for seq <- 1..201 do
        %{"seq" => seq, "content" => "r32-#{seq}", "actor_type" => "user", "user_id" => "u1"}
      end

    conv_1 = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_1,
        device_id: ctx.device,
        session: "ses_r32_p01_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_a}
      })

    :ok =
      StationTaskSessions.sent_sessions(
        ctx.group,
        conv_1,
        ctx.device,
        [{"ses_r32_p01_lead", 0}],
        100,
        run_a
      )

    switched_1 = :atomics.new(1, [])

    {:ok, _} =
      FakeConversations.start_link(
        messages: msgs_201,
        on_messages_after: fn after_seq ->
          if after_seq == 100 and :atomics.compare_exchange(switched_1, 1, 0, 1) == :ok do
            tr_b = "tr_r32_b_#{SystemsRuntime.Proc.unique_integer([:positive])}"

            {:ok, ^tr_b, rec_b} =
              Registry.connect(
                "test-node",
                %{
                  "tenant_id" => ctx.tenant,
                  "group_id" => ctx.group,
                  "device_id" => ctx.device,
                  "connector_id" => "conn_r32_b",
                  "name" => "Station B",
                  "capabilities" => %{"tasks" => 2, "multi_session_tasks" => true}
                },
                transport_id: tr_b
              )

            # Simulate hello on run_B resetting sent=0 and stamping run_B
            :ok =
              StationTaskSessions.fetched(
                ctx.group,
                conv_1,
                ctx.device,
                0,
                rec_b["connector_run_id"]
              )

            send(test_pid, {:r32_p01_run_b, rec_b["connector_run_id"]})
          end
        end
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    put_log_1 = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(put_log_1), do: Agent.stop(put_log_1) end)

    FakeConnector.on("task.put", fn run_id, params ->
      Agent.update(put_log_1, &[{run_id, params["through"]} | &1])

      {:ok,
       %{
         "through" => params["through"],
         "present_slots" => [%{"slot" => "lead", "session" => "ses_r32_p01_lead"}],
         "committed_slots" => [%{"slot" => "lead", "session" => "ses_r32_p01_lead"}]
       }}
    end)

    StationTasks.give(ctx.group, conv_1, ctx.device)
    settle_receive({:r32_p01_run_b, run_b})

    settle_until(fn ->
      {:ok, [l1]} = StationTaskSessions.of_task(ctx.group, conv_1)
      l1.sent == 201
    end)

    run_b_throughs =
      Agent.get(put_log_1, &Enum.reverse(&1))
      |> Enum.filter(fn {rid, _} -> rid == run_b end)
      |> Enum.map(&elem(&1, 1))

    # First delivery to run_B MUST be 1..100 (through == 100), NEVER stale 101..200!
    assert hd(run_b_throughs) == 100

    # ── 2. R32 P1-4: Old active binding A occupies `reviewer` while dispatched pending X hits
    # `:station_outdated` + Actor `{:ok, :already_bound}` -> MUST record `{reviewer, "", X}`
    # in `pending_orphan_leaves` (tested on background `give` path AND online `add_session` path)! ──
    defmodule AlreadyBoundConversations do
      def participants(_g, _c), do: {:ok, []}
      def messages_after(_g, _c, _after, _limit), do: {:ok, []}
      def reserve_task_participant_session(_g, _c, _pid, fun), do: fun.()

      def deactivate_unbound_task_participant(_g, _c, _pid, _stale, _vf),
        do: {:ok, :already_bound}
    end

    tr_old = "tr_r32_old_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^tr_old, rec_old} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device,
          "connector_id" => "conn_r32_old",
          "name" => "Old Station",
          "capabilities" => %{"tasks" => 2}
        },
        transport_id: tr_old
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: AlreadyBoundConversations
    )

    conv_4_bg = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_4_bg,
        device_id: ctx.device,
        session: "ses_r32_p14_bg_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => rec_old["connector_run_id"],
          "pending_multi_starts" => [
            %{
              "slot" => "reviewer",
              "is_primary" => false,
              "invite_id" => "inv_r32_bg_X",
              "dispatched" => true,
              "participant_id" => "prt_r32_rev",
              "start" => %{
                "slot" => "reviewer",
                "is_primary" => false,
                "participant_id" => "prt_r32_rev"
              }
            }
          ]
        }
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_4_bg,
        device_id: ctx.device,
        session: "ses_r32_p14_bg_old_A",
        agent_id: ctx.agent,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "connector_run_id" => rec_old["connector_run_id"],
          "invite_id" => "inv_r32_bg_OLD_A"
        }
      })

    StationTasks.give(ctx.group, conv_4_bg, ctx.device)

    settle_until(fn ->
      {:ok, rows_bg} = StationTaskSessions.of_task(ctx.group, conv_4_bg)
      l_bg = Enum.find(rows_bg, &(&1.session == "ses_r32_p14_bg_lead"))
      l_bg != nil and l_bg.start["pending_multi_starts"] == nil
    end)

    {:ok, rows_bg} = StationTaskSessions.of_task(ctx.group, conv_4_bg)
    l_bg = Enum.find(rows_bg, &(&1.session == "ses_r32_p14_bg_lead"))

    assert Enum.any?(l_bg.start["pending_orphan_leaves"] || [], fn o ->
             o["slot"] == "reviewer" and o["session"] == "" and o["claim_token"] == "inv_r32_bg_X"
           end)

    # Online `add_session` path: old binding A occupies `reviewer`, pending X is already dispatched,
    # device is outdated -> `:already_bound` MUST still record orphan `{reviewer, "", X}`!
    conv_4_on = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_4_on,
        device_id: ctx.device,
        session: "ses_r32_p14_on_lead",
        agent_id: ctx.agent,
        start: %{
          "slot" => "lead",
          "is_primary" => true,
          "connector_run_id" => rec_old["connector_run_id"],
          "pending_multi_starts" => [
            %{
              "slot" => "reviewer",
              "is_primary" => false,
              "agent_id" => ctx.agent,
              "invite_id" => "inv_r32_on_X",
              "dispatched" => true,
              "participant_id" => "prt_r32_rev_on",
              "start" => %{
                "slot" => "reviewer",
                "is_primary" => false,
                "participant_id" => "prt_r32_rev_on"
              }
            }
          ]
        }
      })

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_4_on,
        device_id: ctx.device,
        session: "ses_r32_p14_on_old_A",
        agent_id: ctx.agent,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "connector_run_id" => rec_old["connector_run_id"],
          "invite_id" => "inv_r32_on_OLD_A"
        }
      })

    assert {:error, :station_outdated} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_4_on,
               device_id: ctx.device,
               slot: "reviewer",
               agent_id: ctx.agent,
               participant_id: "prt_r32_rev_on",
               start: %{
                 "slot" => "reviewer",
                 "is_primary" => false,
                 "participant_id" => "prt_r32_rev_on"
               }
             })

    {:ok, rows_on} = StationTaskSessions.of_task(ctx.group, conv_4_on)
    l_on = Enum.find(rows_on, &(&1.session == "ses_r32_p14_on_lead"))

    assert Enum.any?(l_on.start["pending_orphan_leaves"] || [], fn o ->
             o["slot"] == "reviewer" and o["session"] == "" and o["claim_token"] == "inv_r32_on_X"
           end)

    # ── 3. R32 P1-5: Background already committed X and deleted pending -> online `add_session`
    # hitting `:pending_invite_not_found` re-reads active row matching X and returns `:ok`!
    # If active row holds a different invite Y (or none), returns `{:error, :pending_invite_not_found}`. ──
    run_c = register_device(ctx, "r32_c", %{"tasks" => 2, "multi_session_tasks" => true})

    defmodule R32PreemptingTaskSessions do
      def append_pending_multi_start(g, c, d, entry) do
        StationTaskSessions.append_pending_multi_start(g, c, d, entry)
      end

      def mark_pending_multi_start_dispatched(g, c, d, slot, invite_id) do
        # Simulate background committing this invite (or a different invite Y) and deleting pending
        # right before `mark_pending_multi_start_dispatched` acquires the lock!
        {:ok, _} =
          StationTaskSessions.remove_pending_multi_starts(g, c, d, [{slot, invite_id}], [])

        case Process.get(:r32_p15_mode) do
          :commit_same ->
            :ok =
              StationTaskSessions.join(%{
                tenant_id: Process.get(:r32_p15_tenant),
                group_id: g,
                conversation_id: c,
                device_id: d,
                session: "ses_r32_p15_bg_same",
                agent_id: Process.get(:r32_p15_agent),
                start: %{
                  "slot" => slot,
                  "is_primary" => false,
                  "invite_id" => invite_id,
                  "claim_token" => invite_id
                }
              })

          :commit_different ->
            :ok =
              StationTaskSessions.join(%{
                tenant_id: Process.get(:r32_p15_tenant),
                group_id: g,
                conversation_id: c,
                device_id: d,
                session: "ses_r32_p15_bg_other",
                agent_id: Process.get(:r32_p15_agent),
                start: %{
                  "slot" => slot,
                  "is_primary" => false,
                  "invite_id" => "inv_different_Y",
                  "claim_token" => "inv_different_Y"
                }
              })

          :none ->
            :ok
        end

        StationTaskSessions.mark_pending_multi_start_dispatched(g, c, d, slot, invite_id)
      end
    end

    Process.put(:r32_p15_tenant, ctx.tenant)
    Process.put(:r32_p15_agent, ctx.agent)

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations,
      task_sessions: R32PreemptingTaskSessions
    )

    conv_5a = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_5a,
        device_id: ctx.device,
        session: "ses_r32_p15a_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_c}
      })

    Process.put(:r32_p15_mode, :commit_same)

    assert :ok =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_5a,
               device_id: ctx.device,
               slot: "reviewer",
               agent_id: ctx.agent,
               start: %{"slot" => "reviewer", "is_primary" => false}
             })

    conv_5b = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_5b,
        device_id: ctx.device,
        session: "ses_r32_p15b_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_c}
      })

    Process.put(:r32_p15_mode, :commit_different)

    assert {:error, :pending_invite_not_found} =
             StationTasks.add_session(%{
               tenant_id: ctx.tenant,
               group_id: ctx.group,
               conversation_id: conv_5b,
               device_id: ctx.device,
               slot: "reviewer",
               agent_id: ctx.agent,
               start: %{"slot" => "reviewer", "is_primary" => false}
             })
  end

  test "R33 P0: vm_ready never bleaches run_A sent>0 to run_B, legacy unstamped sent>0 safely resets to 0, and hello without tasks resets sent=0",
       ctx do
    msgs_201 =
      for seq <- 1..201 do
        %{"seq" => seq, "content" => "r33-#{seq}", "actor_type" => "user", "user_id" => "u1"}
      end

    {:ok, _} = FakeConversations.start_link(messages: msgs_201)

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    # ── (a) vm_ready arrives BEFORE hello(run_B): must NOT stamp run_B onto run_A's sent=100
    # and must NOT send 101..200 to run_B; once hello(run_B, fetched: 0) arrives, delivers 1..100 first! ──
    run_a = register_device(ctx, "r33_a", %{"tasks" => 2, "multi_session_tasks" => true})
    conv_a = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_a,
        device_id: ctx.device,
        session: "ses_r33_a_lead",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_a}
      })

    :ok =
      StationTaskSessions.sent_sessions(
        ctx.group,
        conv_a,
        ctx.device,
        [{"ses_r33_a_lead", 0}],
        100,
        run_a
      )

    run_b = register_device(ctx, "r33_b", %{"tasks" => 2, "multi_session_tasks" => true})

    put_log_a = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(put_log_a), do: Agent.stop(put_log_a) end)

    FakeConnector.on("task.put", fn run_id, params ->
      Agent.update(put_log_a, &[{run_id, params["through"]} | &1])

      {:ok,
       %{
         "through" => params["through"],
         "present_slots" => [%{"slot" => "lead", "session" => "ses_r33_a_lead"}],
         "committed_slots" => [%{"slot" => "lead", "session" => "ses_r33_a_lead"}]
       }}
    end)

    :ok =
      StationTasks.vm_ready(
        %{"status" => "waking"},
        %{
          "status" => "ready",
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group,
          "device_id" => ctx.device
        }
      )

    SystemsClock.advance(200)
    # Zero task.put sent to run_B before hello(run_B), and connector_run_id is STILL run_a!
    assert Agent.get(put_log_a, & &1) == []
    {:ok, [row_a_mid]} = StationTaskSessions.of_task(ctx.group, conv_a)
    assert row_a_mid.start["connector_run_id"] == run_a
    assert row_a_mid.sent == 100

    # Now hello(run_B, fetched: 0) arrives -> resets sent=0, stamps run_B, delivers 1..100 first!
    {:ok, %{}} =
      StationTasks.hello(
        %{
          tenant_id: ctx.tenant,
          group_id: ctx.group,
          device_id: ctx.device,
          connector_run_id: run_b
        },
        %{"tasks" => [%{"task" => conv_a, "fetched" => 0}]}
      )

    settle_until(fn ->
      {:ok, [r]} = StationTaskSessions.of_task(ctx.group, conv_a)
      r.sent == 201
    end)

    run_b_throughs_a =
      Agent.get(put_log_a, &Enum.reverse(&1))
      |> Enum.filter(fn {rid, _} -> rid == run_b end)
      |> Enum.map(&elem(&1, 1))

    assert hd(run_b_throughs_a) == 100

    # ── (b) Legacy PR 1 row with sent=100 and missing connector_run_id: give_active_pinned
    # safely resets sent=0 & stamps run_B instead of skipping 1..100! ──
    conv_b = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_b,
        device_id: ctx.device,
        session: "ses_r33_b_legacy",
        agent_id: ctx.agent,
        start: %{}
      })

    :ok =
      StationTaskSessions.sent(ctx.group, conv_b, ctx.device, 100)

    put_log_b = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(put_log_b), do: Agent.stop(put_log_b) end)

    FakeConnector.on("task.put", fn run_id, params ->
      Agent.update(put_log_b, &[{run_id, params["through"]} | &1])

      {:ok,
       %{
         "through" => params["through"],
         "present_slots" => [%{"slot" => "lead", "session" => "ses_r33_b_legacy"}],
         "committed_slots" => [%{"slot" => "lead", "session" => "ses_r33_b_legacy"}]
       }}
    end)

    StationTasks.give(ctx.group, conv_b, ctx.device)

    settle_until(fn ->
      {:ok, [r]} = StationTaskSessions.of_task(ctx.group, conv_b)
      r.sent == 201
    end)

    run_b_throughs_b =
      Agent.get(put_log_b, &Enum.reverse(&1))
      |> Enum.map(&elem(&1, 1))

    assert hd(run_b_throughs_b) == 100

    # ── (c) hello without "tasks" (had == nil, very old Station): resets sent=0 & stamps run_c! ──
    run_c = register_device(ctx, "r33_c", %{"tasks" => 2, "multi_session_tasks" => true})
    conv_c = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv_c,
        device_id: ctx.device,
        session: "ses_r33_c_oldhello",
        agent_id: ctx.agent,
        start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_b}
      })

    :ok =
      StationTaskSessions.sent_sessions(
        ctx.group,
        conv_c,
        ctx.device,
        [{"ses_r33_c_oldhello", 0}],
        100,
        run_b
      )

    put_log_c = Agent.start_link(fn -> [] end) |> elem(1)
    on_exit(fn -> if Process.alive?(put_log_c), do: Agent.stop(put_log_c) end)

    FakeConnector.on("task.put", fn run_id, params ->
      Agent.update(put_log_c, &[{run_id, params["through"]} | &1])

      {:ok,
       %{
         "through" => params["through"],
         "present_slots" => [%{"slot" => "lead", "session" => "ses_r33_c_oldhello"}],
         "committed_slots" => [%{"slot" => "lead", "session" => "ses_r33_c_oldhello"}]
       }}
    end)

    {:ok, %{}} =
      StationTasks.hello(
        %{
          tenant_id: ctx.tenant,
          group_id: ctx.group,
          device_id: ctx.device,
          connector_run_id: run_c
        },
        %{}
      )

    settle_until(fn ->
      {:ok, [r]} = StationTaskSessions.of_task(ctx.group, conv_c)
      r.sent == 201
    end)

    run_c_throughs =
      Agent.get(put_log_c, &Enum.reverse(&1))
      |> Enum.filter(fn {rid, _} -> rid == run_c end)
      |> Enum.map(&elem(&1, 1))

    assert hd(run_c_throughs) == 100
  end

  test "R34 P1-1: give_device continues processing remaining Tasks when one Task's fetched update fails",
       ctx do
    run_old = register_device(ctx, "r34_old", %{"tasks" => 2, "multi_session_tasks" => true})
    conv_fail = Ids.new_conversation_id()
    conv_ok = Ids.new_conversation_id()

    for {conv, sess} <- [{conv_fail, "ses_r34_fail"}, {conv_ok, "ses_r34_ok"}] do
      :ok =
        StationTaskSessions.join(%{
          tenant_id: ctx.tenant,
          group_id: ctx.group,
          conversation_id: conv,
          device_id: ctx.device,
          session: sess,
          agent_id: ctx.agent,
          start: %{"slot" => "lead", "is_primary" => true, "connector_run_id" => run_old}
        })

      :ok =
        StationTaskSessions.sent_sessions(
          ctx.group,
          conv,
          ctx.device,
          [{sess, 0}],
          50,
          run_old
        )
    end

    defmodule R34PartialFailTaskSessions do
      def fetched(group, conv, device, fetched, run_id) do
        if conv == Process.get(:r34_fail_conv) do
          {:error, :db_busy}
        else
          StationTaskSessions.fetched(group, conv, device, fetched, run_id)
        end
      end
    end

    Process.put(:r34_fail_conv, conv_fail)

    {:ok, _} =
      FakeConversations.start_link(
        messages: [
          %{"seq" => 1, "content" => "m1", "actor_type" => "user", "user_id" => "u1"}
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations,
      task_sessions: R34PartialFailTaskSessions
    )

    run_new = register_device(ctx, "r34_new", %{"tasks" => 2, "multi_session_tasks" => true})

    FakeConnector.on("task.put", fn _run_id, params ->
      {:ok,
       %{
         "through" => params["through"],
         "present_slots" => [%{"slot" => "lead", "session" => "ses_r34_ok"}],
         "committed_slots" => [%{"slot" => "lead", "session" => "ses_r34_ok"}]
       }}
    end)

    assert {:error, :db_busy} =
             StationTasks.hello(
               %{
                 tenant_id: ctx.tenant,
                 group_id: ctx.group,
                 device_id: ctx.device,
                 connector_run_id: run_new
               },
               %{
                 "tasks" => [
                   %{"task" => conv_fail, "fetched" => 0},
                   %{"task" => conv_ok, "fetched" => 0}
                 ]
               }
             )

    # Even though conv_fail failed, conv_ok MUST still be updated to run_new and delivered!
    settle_until(fn ->
      {:ok, [r_ok]} = StationTaskSessions.of_task(ctx.group, conv_ok)
      r_ok.start["connector_run_id"] == run_new and r_ok.sent == 1
    end)
  end

  test "R35 P0: unconfirmed claim A requires exact {slot, session, claim_token} triple in ACK confirmed_claims",
       ctx do
    test_pid = self()
    run_live = register_device(ctx, "r35_p0", %{"tasks" => 2, "multi_session_tasks" => true})

    {:ok, _} =
      FakeConversations.start_link(
        messages: [
          %{"seq" => 1, "content" => "r35-m1", "actor_type" => "user", "user_id" => "u1"}
        ]
      )

    SystemsRuntime.put_env(:salix_web, :station_tasks,
      connector: FakeConnector,
      conversations: FakeConversations
    )

    conv = Ids.new_conversation_id()

    :ok =
      StationTaskSessions.join(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: conv,
        device_id: ctx.device,
        session: "ses_r35_rev",
        agent_id: ctx.agent,
        start: %{
          "slot" => "reviewer",
          "is_primary" => false,
          "connector_run_id" => run_live,
          "claim_token" => "tok_r35_A",
          "claim_confirmed" => false
        }
      })

    # Phase 1a: Station ACK omits `confirmed_claims` completely while `committed_slots` includes
    # `{reviewer, ses_r35_rev}` -> MUST NOT fall back to 2-tuple or confirm A!
    FakeConnector.on("task.put", fn _run_id, params ->
      send(test_pid, {:r35_put_1a, params})

      {:ok,
       %{
         "through" => params["through"],
         "present_slots" => [%{"slot" => "reviewer", "session" => "ses_r35_rev"}],
         "committed_slots" => [%{"slot" => "reviewer", "session" => "ses_r35_rev"}]
       }}
    end)

    StationTasks.give(ctx.group, conv, ctx.device)
    settle_receive({:r35_put_1a, _})
    SystemsClock.advance(100)

    {:ok, [r_mid_a]} = StationTaskSessions.of_task(ctx.group, conv)
    assert r_mid_a.sent == 0
    assert r_mid_a.start["claim_confirmed"] == false

    # Phase 1b: Station ACK includes `{reviewer, ses_r35_rev}` in `committed_slots` and
    # `confirmed_claims` has empty list / missing-slot entry -> MUST NOT advance sent or confirm A!
    FakeConnector.on("task.put", fn _run_id, params ->
      send(test_pid, {:r35_put_1, params})

      {:ok,
       %{
         "through" => params["through"],
         "present_slots" => [%{"slot" => "reviewer", "session" => "ses_r35_rev"}],
         "committed_slots" => [%{"slot" => "reviewer", "session" => "ses_r35_rev"}],
         "confirmed_claims" => [
           %{"session" => "ses_r35_rev", "claim_token" => "tok_r35_A"}
         ]
       }}
    end)

    StationTasks.give(ctx.group, conv, ctx.device)
    settle_receive({:r35_put_1, _})
    SystemsClock.advance(100)

    {:ok, [r_mid]} = StationTaskSessions.of_task(ctx.group, conv)
    assert r_mid.sent == 0
    assert r_mid.start["claim_confirmed"] == false

    # Phase 2: Once ACK returns exact triple `{reviewer, ses_r35_rev, tok_r35_A}` in `confirmed_claims`,
    # `sent` advances to 1 and `claim_confirmed` becomes true!
    FakeConnector.on("task.put", fn _run_id, params ->
      {:ok,
       %{
         "through" => params["through"],
         "present_slots" => [%{"slot" => "reviewer", "session" => "ses_r35_rev"}],
         "committed_slots" => [%{"slot" => "reviewer", "session" => "ses_r35_rev"}],
         "confirmed_claims" => [
           %{
             "slot" => "reviewer",
             "session" => "ses_r35_rev",
             "claim_token" => "tok_r35_A"
           }
         ]
       }}
    end)

    StationTasks.give(ctx.group, conv, ctx.device)

    settle_until(fn ->
      {:ok, [r_done]} = StationTaskSessions.of_task(ctx.group, conv)
      r_done.sent == 1 and r_done.start["claim_confirmed"] == true
    end)
  end
end
