defmodule SalixAgent.IFCRoundE2ETest do
  @moduledoc """
  The information-flow check as a running round sees it
  (`docs/verification.md` §9, §12).

  `ifc_check_test.exs` calls `SalixAgent.IFC.Check.authorize/2` directly, which
  proves the algebra reaches the right verdict. What it cannot prove is that
  the verdict is *wired* — that the dispatch step actually runs on the way to
  the Tools seam, that a refused effect never reaches the provider, and that a
  streaming draft does not publish the very text the refusal was about.

  So this drives whole rounds through `SalixAgent.Server` with a scripted
  model and a recording IM provider, and asserts on product effects: what
  crossed the provider seam, and what a person could see while it was being
  decided.

  The draft is the case worth stating plainly. A draft reaches the
  conversation's audience while the model is still writing, necessarily before
  it has declared what the reply drew on — so nothing has authorized it, and
  the refusal that stops the completed send arrives after the text has been
  seen. Clearing a draft does not unsee it. Under `enforce` the draft
  therefore waits for the decision; under `audit` it must not, because audit
  may never change what happens.
  """

  use ExUnit.Case, async: false

  alias SalixAgent.{DraftSurface, Fleet, Server}
  alias SalixAgent.LLM.Mock

  @pid_key {__MODULE__, :test_pid}
  @session_id "ses1_0000000000000000931"
  @conversation_id "conv-ifc-e2e"
  @source_message_id "msg1_0000000000000000931"
  @participant_id "par1_0000000000000000931"
  @group_id "grp1_0000000000000000931"
  @encoded_source "groupconv:conv-ifc-e2e:msg1_0000000000000000931:par1_0000000000000000931"
  @requester "comma_user|par1_0000000000000000931"

  # The Group's mode, and one resolver answer. Configured per test through the
  # same runtime seam production uses.
  defmodule Facts do
    @moduledoc false

    def mode(_tenant_id, _group_id), do: :persistent_term.get({SalixAgent.IFCRoundE2ETest, :mode})

    def resolve(request) do
      {:ok,
       %{
         "mode" => :persistent_term.get({SalixAgent.IFCRoundE2ETest, :mode}),
         "destination" => %{"label" => destination(request), "writers" => "any"},
         "scopes" => %{},
         "membership" => %{},
         "placements" => %{},
         "receipts" => [],
         "policy" => %{},
         "display_names" => %{},
         "now" => System.system_time(:millisecond)
       }}
    end

    def consume_receipt(_request), do: {:ok, true}

    # The real resolver reads the descriptor; this one only needs to tell the
    # agent's own workspace apart from a conversation.
    defp destination(%{"destination" => %{"kind" => "agent_private"}}), do: ["agent_private"]

    defp destination(_request),
      do: :persistent_term.get({SalixAgent.IFCRoundE2ETest, :destination})
  end

  # Records every notification alongside whatever draft was live at that
  # instant. `SalixAgent.VisibleReply.publish_delta/5` notifies immediately
  # after the draft changes, so a draft that was ever published is a draft this
  # sees.
  defmodule DraftWatchingNotifier do
    @moduledoc false
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, {:session_activity_updated, session_id} = event) do
      forward(agent_id, event)

      case DraftSurface.get(agent_id, session_id) do
        %{} = draft -> forward(agent_id, {:draft_seen, draft})
        _absent -> :ok
      end

      :ok
    end

    def notify(agent_id, event) do
      forward(agent_id, event)
      :ok
    end

    defp forward(agent_id, event) do
      case :persistent_term.get({SalixAgent.IFCRoundE2ETest, :test_pid}, nil) do
        nil -> :ok
        pid -> send(pid, {:notified, agent_id, event})
      end
    end
  end

  defmodule RecordingIMProvider do
    @moduledoc false
    @behaviour SalixAgent.Tools.ImRouter

    @owner_key {__MODULE__, :owner}

    def set_owner(owner), do: :persistent_term.put(@owner_key, owner)
    def clear, do: :persistent_term.erase(@owner_key)

    @impl true
    def list_connects(_agent_id),
      do:
        {:ok,
         [
           %{"connect_id" => "internal", "provider" => "internal"},
           %{"connect_id" => "slack-1", "provider" => "slack"}
         ]}

    @impl true
    def provider_manual("internal") do
      {:ok,
       %{
         "provider" => "internal",
         "apis" => [
           %{
             "name" => "internal.task.create",
             "safety" => "write",
             "parameters" => %{"content" => "Task command", "workflow" => "Workflow"},
             "required_params" => ["content"]
           },
           %{
             "name" => "internal.send_message",
             "safety" => "write",
             "description" => "Send an internal conversation message.",
             "parameters" => %{
               "conversation_id" => "Conversation id.",
               "content" => "Message content.",
               "request_id" => "Idempotent send request id.",
               "delivery_filter" => "Optional participant delivery filter.",
               "mentions" => "Optional mentions."
             },
             "required_params" => ["conversation_id", "content"]
           }
         ]
       }}
    end

    def provider_manual("slack") do
      {:ok,
       %{
         "provider" => "slack",
         "apis" =>
           for {name, safety} <- [
                 {"slack.post_message", "write"},
                 {"slack.post_task_card", "write"},
                 {"slack.get_channel_history", "read"}
               ] do
             %{
               "name" => name,
               "safety" => safety,
               "required_params" => ["channel"],
               "parameters" => %{
                 "channel" => "Channel",
                 "conversation_id" => "Task",
                 "text" => "Text",
                 "thread_ts" => "Thread"
               }
             }
           end
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(agent_id, provider, api, args) do
      owner = :persistent_term.get(@owner_key)
      send(owner, {:im_provider_call, agent_id, provider, api, args})

      if get_in(args, ["params", "request_id"]) == "deferred-ifc-result" do
        send(owner, {:deferred_ifc_result, self()})

        receive do
          :finish_ifc_result -> :ok
        after
          5_000 -> raise "test did not release deferred result"
        end
      end

      if api == "slack.get_channel_history" do
        send(owner, {:onboarding_read, self()})

        receive do
          :finish_onboarding_read -> :ok
        after
          5_000 -> raise "test did not release onboarding read"
        end
      end

      case api do
        "internal.task.create" ->
          {:ok, %{"created" => true, "conversation_id" => "task-card-test"}}

        "slack.post_task_card" ->
          {:ok, %{"delivery_status" => "queued"}}

        _ ->
          {:ok, %{"ok" => true}}
      end
    end
  end

  defmodule TestVisibleReply do
    @moduledoc false
    @behaviour SalixAgent.VisibleReply

    @impl true
    def authorize(_agent_id, _scope), do: :ok
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    previous = %{
      s3: Application.get_env(:salix_store, :s3_backend),
      notifier: Application.get_env(:salix_agent, :notifier),
      llm: Application.get_env(:salix_agent, :llm),
      im: Application.get_env(:salix_agent, :im_provider_mod),
      visible_reply: Application.get_env(:salix_agent, :visible_reply_mod),
      facts: Application.get_env(:salix_agent, :ifc_facts_mod)
    }

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)
    Application.put_env(:salix_agent, :notifier, DraftWatchingNotifier)
    Application.put_env(:salix_agent, :im_provider_mod, RecordingIMProvider)
    Application.put_env(:salix_agent, :visible_reply_mod, TestVisibleReply)
    Application.put_env(:salix_agent, :ifc_facts_mod, Facts)
    RecordingIMProvider.set_owner(self())
    :persistent_term.put(@pid_key, self())
    put_mode("off")
    put_destination(["conversation|#{@conversation_id}"])

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      RecordingIMProvider.clear()
      :persistent_term.erase(@pid_key)
      :persistent_term.erase({__MODULE__, :mode})
      :persistent_term.erase({__MODULE__, :destination})
      restore(:salix_store, :s3_backend, previous.s3)
      restore(:salix_agent, :notifier, previous.notifier)
      restore(:salix_agent, :llm, previous.llm)
      restore(:salix_agent, :im_provider_mod, previous.im)
      restore(:salix_agent, :visible_reply_mod, previous.visible_reply)
      restore(:salix_agent, :ifc_facts_mod, previous.facts)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    {:ok, agent: agent}
  end

  test "automatic Task cards inherit only create dependencies through the real dispatch seam", %{
    agent: agent
  } do
    put_mode("enforce")
    put_destination(["space|slack-1"])
    source = "im_provider:slack:slack-1:task-card-test"

    origin = %{
      "provider" => "slack",
      "source_actor_type" => "provider_user",
      "agent_group_id" => @group_id,
      "source_message_id" => source,
      "provider_context" => %{
        "connect_id" => "slack-1",
        "channel_id" => "C1",
        "thread_ts" => "1.2"
      },
      "ifc" => %{
        "label" => ["space|slack-1"],
        "integrity" => "command",
        "principal" => "provider_user|slack-1|U1"
      }
    }

    input = %{id: 1, role: "user", source_message_id: source, trusted_origin: origin}

    old = %{
      id: 2,
      role: "tool",
      content: "PRIVATE_HISTORY_CANARY",
      ifc: %{"label" => ["agent_private"]}
    }

    ctx =
      %{
        agent_id: agent,
        session_id: @session_id,
        group_id: @group_id,
        role: "router",
        runtime_kind: :internal,
        trusted_origin: origin,
        source_message_id: source,
        source_message_ids: [source],
        ifc_mode: :enforce,
        ifc:
          SalixAgent.IFC.Context.build(%{messages: [input, old]},
            source_message_id: source,
            source_message_ids: [source],
            trusted_origin: origin
          )
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize("router", :internal, ctx)
      )

    declaration = %{"request" => "src:q-1", "sources" => ["src:q-1"]}

    call = %{
      id: "create-with-history",
      name: "im_api.internal.task.create",
      args: %{"connect_id" => "internal", "content" => "Analyze videos"},
      ifc: declaration
    }

    [result] = SalixAgent.SessionToolDispatch.execute([call], ctx)
    assert result.status == "completed", inspect(result)
    assert get_in(Jason.decode!(result.content), ["task_card", "status"]) == "queued"
    assert_receive {:im_provider_call, ^agent, "slack", "slack.post_task_card", card}
    assert get_in(card, ["tool_context", "ifc_evidence", "sources_label"]) == ["space|slack-1"]
    assert card["params"]["channel"] == "C1"
    assert card["params"]["thread_ts"] == "1.2"

    private_ref = Enum.find(ctx.ifc["items"], &(&1["label"] == ["agent_private"]))["ref"]

    child_ctx =
      ctx
      |> Map.put(:tool_call_id, "private-create")
      |> Map.put(:tool_deadline_ms, System.monotonic_time(:millisecond) + 10_000)
      |> Map.put(:ifc_declaration, %{"request" => "src:q-1", "sources" => [private_ref]})

    failed =
      SalixAgent.Tools.TaskCard.after_create(
        %{"created" => true, "conversation_id" => "task-card-test"},
        child_ctx
      )

    assert failed["task_card"]["status"] == "failed"
    refute_receive {:im_provider_call, ^agent, "slack", "slack.post_task_card", _}, 20

    put_mode("audit")

    audited =
      SalixAgent.Tools.TaskCard.after_create(
        %{"created" => true, "conversation_id" => "task-card-test"},
        Map.put(child_ctx, :ifc_mode, :audit)
      )

    assert audited["task_card"]["status"] == "queued"
    assert_receive {:im_provider_call, ^agent, "slack", "slack.post_task_card", _}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp put_mode(mode), do: :persistent_term.put({__MODULE__, :mode}, mode)
  defp put_destination(atoms), do: :persistent_term.put({__MODULE__, :destination}, atoms)

  # One inbound from a person, into a conversation the agent may reply into, so
  # the round has a visible reply scope and a request it can cite.
  defp deliver_source(agent, conversation_kind \\ "user_chat", origin_overrides \\ %{}) do
    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent, @session_id, [
        %{"type" => "session_created", "session_id" => @session_id}
      ])

    {:ok, _pid} = Fleet.ensure_started(agent, create: true)

    {:ok, :created} =
      SalixAgent.deliver(
        agent,
        %{
          content: "what did legal say?",
          session_id: @session_id,
          trusted_origin:
            Map.merge(
              %{
                "provider" => "internal",
                "conversation_id" => @conversation_id,
                "conversation_kind" => conversation_kind,
                "message_id" => @source_message_id,
                "participant_id" => @participant_id,
                "source_actor_type" => "user",
                "agent_group_id" => @group_id,
                "ifc" => %{
                  "label" => ["conversation|#{@conversation_id}"],
                  "integrity" => "command",
                  "principal" => @requester
                }
              },
              origin_overrides
            )
        },
        source_message_id: @encoded_source
      )

    :ok
  end

  # The model streams a reply into the source conversation, which is what a
  # draft is published from.
  defp script_reply(text) do
    Mock.script([
      {:assistant, "composing the reply",
       [
         inspector_call("reply-1", "im_api.internal.send_message", %{
           "connect_id" => "internal",
           "conversation_id" => @conversation_id,
           "reply_to_message_id" => @source_message_id,
           "content" => [%{"type" => "text", "text" => text}]
         })
       ]},
      {:final, "done"}
    ])
  end

  defp settle(agent) do
    Server.wake(agent)
    result = Server.info(agent)
    assert eventually(fn -> settled?(agent) end, 400)
    result
  end

  # `settled?/1` accepts a session that waits on a running tool: admission
  # commits the auto-wait before dispatch, so the reply tool may still be on
  # its way to the provider seam. Tests that assert on that seam wait for the
  # actor's tool work to finish as well.
  defp settle_quiet(agent) do
    result = settle(agent)
    :ok = SalixAgent.TestSupport.await_session_quiet(agent, @session_id)
    result
  end

  defp settled?(agent) do
    case SalixAgent.InternalSessionStore.list(agent) do
      {:ok, sessions} ->
        Enum.all?(
          sessions,
          &(SalixAgent.InternalSession.derived_state(&1) not in [:queued, :active])
        )

      {:error, _reason} ->
        false
    end
  end

  defp eventually(fun, retries) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  # Every draft that was live at some notification during the round.
  defp drafts_seen(agent) do
    receive do
      {:notified, ^agent, {:draft_seen, draft}} -> [draft | drafts_seen(agent)]
      {:notified, ^agent, _other} -> drafts_seen(agent)
    after
      0 -> []
    end
  end

  defp written?(agent, path) do
    match?({:ok, _entry}, SalixAgent.AgentWorkspace.entry(agent, path))
  end

  defp provider_calls(agent) do
    receive do
      {:im_provider_call, ^agent, provider, api, args} ->
        [{provider, api, args} | provider_calls(agent)]
    after
      0 -> []
    end
  end

  defp assistant_contents(agent) do
    {:ok, session} = SalixAgent.InternalSessionStore.read(agent, @session_id)

    for message <- SalixAgent.InternalSession.get(session, :messages),
        message.role == "assistant",
        do: message.content
  end

  # ---------------------------------------------------------------------------

  for send_with_read <- [false, true] do
    @send_with_read send_with_read
    @tag :onboarding
    if send_with_read, do: @tag(:onboarding_mixed)

    test "a denied welcome yields to a queued human (mixed read: #{send_with_read})", %{
      agent: _worker
    } do
      agent = SalixAgent.TestSupport.new_agent_id()
      record = SalixAgent.TestSupport.create_control_agent!(agent, %{"role" => "router"})
      {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(record)
      group_id = record["group_id"]
      SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent})
      put_mode("enforce")
      put_destination(["space|slack-1"])
      source = "im_provider:slack:slack-1:channel_joined:C_JOIN:EvJoin"

      origin = %{
        "provider" => "slack",
        "source_actor_type" => "provider_user",
        "agent_group_id" => group_id,
        "source_message_id" => source,
        "provider_context" => %{
          "connect_id" => "slack-1",
          "channel_id" => "C_JOIN",
          "event_id" => "EvJoin",
          "event_type" => "member_joined_channel"
        },
        "ifc" => %{"label" => ["space|slack-1"], "integrity" => "data", "principal" => nil}
      }

      call = fn id, tool, params, sources ->
        %{
          id: id,
          name: "call",
          args: %{
            "tool" => tool,
            "params" => Map.put(params, "connect_id", "slack-1"),
            "ifc" => %{"sources" => sources}
          }
        }
      end

      research =
        call.("research", "im_api.slack.get_channel_history", %{"channel" => "C_JOIN"}, [])

      welcome =
        call.(
          "welcome",
          "im_api.slack.post_message",
          %{"channel" => "C_JOIN", "text" => "private research"},
          "context"
        )

      startup =
        if @send_with_read do
          # Non-standalone send is withheld, while the independent read remains
          # running. Its completion must retain the already-committed refusal.
          [{:assistant, "welcome with research", [welcome, research]}]
        else
          # The private read result denies an otherwise standalone welcome.
          [{:assistant, "inspect this channel", [research]}, {:assistant, "welcome", [welcome]}]
        end

      Mock.script(
        startup ++
          [
            {:assistant, "answer the next person",
             [
               call.(
                 "human-reply",
                 "im_api.slack.post_message",
                 %{"channel" => "C_HUMAN", "thread_ts" => "100.1", "text" => "Hello"},
                 []
               )
             ]},
            {:final, "done"}
          ]
      )

      {:ok, _} = Fleet.ensure_started(agent, create: true)

      assert {:ok, :created} =
               SalixAgent.deliver(
                 agent,
                 %{session_id: session_id, content: "Optional welcome", trusted_origin: origin},
                 source_message_id: source
               )

      Server.wake(agent)
      assert_receive {:onboarding_read, reader}, 5_000

      human_origin = %{
        origin
        | "source_message_id" => "human-B",
          "provider_context" => %{
            "connect_id" => "slack-1",
            "channel_id" => "C_HUMAN",
            "thread_ts" => "100.1",
            "user_id" => "U1",
            "event_type" => "app_mention"
          },
          "ifc" => %{
            "label" => ["space|slack-1"],
            "integrity" => "command",
            "principal" => "provider_user|slack-1|U1"
          }
      }

      assert {:ok, :created} =
               SalixAgent.deliver(
                 agent,
                 %{session_id: session_id, content: "hi", trusted_origin: human_origin},
                 source_message_id: "human-B"
               )

      send(reader, :finish_onboarding_read)

      assert eventually(
               fn ->
                 {:ok, current} = SalixAgent.InternalSessionStore.read(agent, session_id)

                 case Enum.find(
                        SalixAgent.InternalSession.get(current, :messages),
                        &(&1[:source_message_id] == "human-B")
                      ) do
                   nil ->
                     false

                   human ->
                     SalixAgent.InternalSession.get(current, :last_ack_message_id) >= human.id and
                       settled?(agent)
                 end
               end,
               1_000
             )

      calls = provider_calls(agent)

      assert Enum.count(calls, fn {_, api, args} ->
               api == "slack.post_message" and
                 get_in(args, ["params", "channel"]) == "C_HUMAN"
             end) == 1

      refute Enum.any?(calls, fn {_, api, args} ->
               api == "slack.post_message" and
                 get_in(args, ["params", "channel"]) == "C_JOIN"
             end)

      {:ok, session} = SalixAgent.InternalSessionStore.read(agent, session_id)

      assert Enum.any?(
               SalixAgent.InternalSession.get(session, :events),
               &(&1["kind"] == "channel_onboarding_settled")
             )

      assert Enum.any?(
               SalixAgent.InternalSession.get(session, :messages),
               &(&1[:tool_call_id] == "welcome" and &1[:status] == "guidance")
             )

      assert Enum.any?(
               SalixAgent.InternalSession.get(session, :messages),
               &(&1[:source_message_id] == "human-B")
             )
    end
  end

  for scenario <- [:welcome, :research_budget, :repeated_reads, :missing_settlement] do
    @scenario scenario
    @tag :onboarding
    if scenario == :repeated_reads, do: @tag(:onboarding_early_guard)

    test "optional onboarding ends after #{@scenario}", %{agent: _worker} do
      if @scenario == :repeated_reads do
        # Force the supported repeated-result guard to stop before the larger
        # onboarding budget, independent of sync/async completion timing.
        previous = Application.get_env(:salix_agent, :repeated_tool_result_cap)
        Application.put_env(:salix_agent, :repeated_tool_result_cap, 2)
        on_exit(fn -> restore(:salix_agent, :repeated_tool_result_cap, previous) end)
      end

      agent = SalixAgent.TestSupport.new_agent_id()
      record = SalixAgent.TestSupport.create_control_agent!(agent, %{"role" => "router"})
      {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(record)
      group = record["group_id"]
      SalixAgent.TestSupport.create_control_group!(group, %{"router_agent_id" => agent})
      source = "im_provider:slack:slack-1:channel_joined:C_JOIN:EvJoin"

      origin = %{
        "provider" => "slack",
        "source_actor_type" => "provider_user",
        "agent_group_id" => group,
        "source_message_id" => source,
        "provider_context" => %{
          "connect_id" => "slack-1",
          "channel_id" => "C_JOIN",
          "event_id" => "EvJoin",
          "event_type" => "member_joined_channel"
        },
        "ifc" => %{"label" => ["space|slack-1"], "integrity" => "data", "principal" => nil}
      }

      put_mode("enforce")
      put_destination(["space|slack-1"])

      responses =
        if @scenario == :welcome do
          [
            {:assistant, "welcome",
             [
               %{
                 id: "welcome",
                 name: "call",
                 args: %{
                   "tool" => "im_api.slack.post_message",
                   "params" => %{
                     "connect_id" => "slack-1",
                     "channel" => "C_JOIN",
                     "text" => "Hello"
                   },
                   "ifc" => %{"sources" => []}
                 }
               }
             ]}
          ]
        else
          for n <- 1..30 do
            if @scenario == :missing_settlement do
              {:assistant, "still researching", []}
            else
              {:assistant, "unrelated successful research",
               [
                 %{
                   id: "read-#{n}",
                   name: "call",
                   args: %{
                     "tool" => "help",
                     "params" => %{
                       "tool" =>
                         if(@scenario == :repeated_reads or rem(n, 2) == 0,
                           do: "history.list",
                           else: "history.get"
                         )
                     }
                   }
                 }
               ]}
            end
          end
        end

      Mock.script(responses)
      {:ok, _} = Fleet.ensure_started(agent, create: true)

      assert {:ok, :created} =
               SalixAgent.deliver(
                 agent,
                 %{session_id: session_id, content: "Optional welcome", trusted_origin: origin},
                 source_message_id: source
               )

      Server.wake(agent)

      assert eventually(
               fn ->
                 {:ok, current} = SalixAgent.InternalSessionStore.read(agent, session_id)

                 Enum.any?(
                   SalixAgent.InternalSession.get(current, :events),
                   &(&1["kind"] == "channel_onboarding_settled")
                 ) or
                   SalixAgent.InternalSession.repeated_tool_results_exhausted?(current) or
                   SalixAgent.InternalSession.runaway_unsettled_rounds_exhausted?(current)
               end,
               2_000
             )

      {:ok, session} = SalixAgent.InternalSessionStore.read(agent, session_id)

      assert Enum.any?(
               SalixAgent.InternalSession.get(session, :events),
               &(&1["kind"] == "channel_onboarding_settled")
             )

      refute SalixAgent.InternalSession.needs_transcript_continuation?(session)

      if @scenario == :welcome do
        assert Enum.count(provider_calls(agent), fn {_, api, _} -> api == "slack.post_message" end) ==
                 1
      else
        assert Enum.count(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1.role == "assistant")
               ) < 30

        refute Enum.any?(provider_calls(agent), fn {_, api, _} -> api == "slack.post_message" end)
      end
    end
  end

  describe "Inspector effect authority" do
    for response_kind <- [:explicit_send, :end_turn, :raw_final] do
      @tag :inspector_scheduled_failure
      test "a scheduled Inspector records a safe internal failure through #{response_kind}", %{
        agent: agent
      } do
        assert {:ok, _} =
                 SalixAgent.AgentControl.configure(agent, %{
                   "inspector_policy" => SalixAgent.TestSupport.inspector_policy()
                 })

        schedule_id = "sch1_0000000000000000001"
        scheduled_for = 1_788_256_680_000

        :ok =
          deliver_source(agent, "agent_task", %{
            "source_actor_type" => "system",
            "task_schedule" => %{"schedule_id" => schedule_id, "scheduled_for" => scheduled_for}
          })

        failure_response =
          case unquote(response_kind) do
            :explicit_send ->
              {:assistant, "reporting the failed inspection",
               [
                 inspector_call("failure-report", "im_api.internal.send_message", %{
                   "connect_id" => "internal",
                   "conversation_id" => @conversation_id,
                   "content" => [
                     %{"type" => "text", "text" => "private source failure must not appear"}
                   ],
                   "delivery_filter" => %{"participant_ids" => []}
                 })
               ]}

            :end_turn ->
              {:assistant, "private source failure must not appear",
               [%{id: "failure-end-turn", name: "end_turn", args: %{"outcome" => "done"}}]}

            :raw_final ->
              {:raw,
               {:final, "private source failure must not appear",
                %{
                  "responses_items" => [%{"type" => "reasoning", "id" => "inspection-reasoning"}]
                }, %{}}}
          end

        failure_response =
          case failure_response do
            {:assistant, content, calls} ->
              {:assistant, content, calls,
               %{
                 "responses_items" =>
                   [%{"type" => "reasoning", "id" => "inspection-reasoning"}] ++
                     Enum.map(calls, fn call ->
                       %{
                         "type" => "function_call",
                         "call_id" => call.id,
                         "name" => call.name,
                         "arguments" => Jason.encode!(call.args)
                       }
                     end)
               }}

            raw ->
              raw
          end

        Mock.script([
          {:assistant, "reading the inspection input",
           [inspector_call("missing-source", "fs.read_file", %{"path" => "/missing-source.md"})]},
          failure_response,
          {:final, "done"}
        ])

        {:parked, _owned} = settle(agent)

        assert_receive {:im_provider_call, ^agent, "internal", "internal.send_message",
                        %{"params" => params}},
                       2_000

        assert params["conversation_id"] == @conversation_id
        assert params["delivery_filter"] == %{"participant_ids" => []}
        assert params["mentions"] == nil

        assert params["request_id"] ==
                 "scheduled-task-safe-failure:#{schedule_id}:#{scheduled_for}"

        assert [%{"type" => "text", "text" => text}] = params["content"]
        assert text =~ "This scheduled run could not be completed"
        refute text =~ "/missing-source.md"
        refute text =~ "private source failure must not appear"
        assert drafts_seen(agent) == []

        assert eventually(
                 fn ->
                   {:ok, session} = SalixAgent.InternalSessionStore.read(agent, @session_id)

                   not SalixAgent.VisibleReplyPolicy.repair_required?(
                     SalixAgent.VisibleReplyPolicy.phase(session)
                   )
                 end,
                 400
               )

        assert provider_calls(agent) == []

        {:ok, session} = SalixAgent.InternalSessionStore.read(agent, @session_id)

        replay =
          SalixLlm.ConvertOpenAI.to_responses(SalixAgent.InternalSession.get(session, :messages))

        request_id = params["request_id"]

        assert Enum.any?(
                 replay,
                 &(&1["type"] == "reasoning" and &1["id"] == "inspection-reasoning")
               )

        assert Enum.count(
                 replay,
                 &(&1["type"] == "function_call" and &1["call_id"] == request_id)
               ) == 1

        assert Enum.count(
                 replay,
                 &(&1["type"] == "function_call_output" and &1["call_id"] == request_id)
               ) == 1

        Enum.reduce(replay, MapSet.new(), fn item, called ->
          case item["type"] do
            "function_call" ->
              MapSet.put(called, item["call_id"])

            "function_call_output" ->
              assert MapSet.member?(called, item["call_id"]),
                     "orphan provider result #{item["call_id"]}"

              called

            _ ->
              called
          end
        end)

        if unquote(response_kind) != :raw_final do
          original_id =
            if unquote(response_kind) == :end_turn, do: "failure-end-turn", else: "failure-report"

          old_result =
            Enum.find(
              replay,
              &(&1["type"] == "function_call_output" and &1["call_id"] == original_id)
            )

          assert old_result

          assert Enum.count(
                   replay,
                   &(&1["type"] == "function_call_output" and &1["call_id"] == original_id)
                 ) == 1

          assert Jason.decode!(old_result["output"]) == %{
                   "status" => "not_settled",
                   "reason" => "repair_required"
                 }
        end
      end
    end

    test "a forbidden send never streams or dispatches, while its private report survives", %{
      agent: agent
    } do
      assert {:ok, _} =
               SalixAgent.AgentControl.configure(agent, %{
                 "inspector_policy" => SalixAgent.TestSupport.inspector_policy()
               })

      put_mode("audit")
      :ok = deliver_source(agent)

      report_path = "/.shape-up-inspector/reports/run-1.md"

      Mock.script([
        {:assistant, "recording the inspection",
         [
           inspector_call("send", "im_api.internal.send_message", %{
             "connect_id" => "internal",
             "conversation_id" => @conversation_id,
             "content" => [%{"type" => "text", "text" => "must stay private"}]
           }),
           inspector_call("outside", "fs.write_file", %{
             "path" => "/business.md",
             "content" => "forbidden"
           }),
           inspector_call("report", "fs.write_file", %{
             "path" => report_path,
             "content" => "inspection report"
           })
         ]},
        {:final, "inspection recorded"}
      ])

      {:parked, _owned} = settle(agent)
      assert drafts_seen(agent) == []
      assert provider_calls(agent) == []
      refute written?(agent, "/business.md")
      assert eventually(fn -> written?(agent, report_path) end, 400)
      assert {:ok, config} = SalixAgent.AgentActor.runtime_session_config(agent, %{})

      [readback] =
        SalixAgent.SessionToolDispatch.execute(
          [%{id: "readback", name: "fs.read_file", args: %{"path" => report_path}}],
          Map.merge(config, %{
            agent_id: agent,
            session_id: @session_id,
            runtime_kind: :internal,
            ifc_mode: :off
          })
        )

      refute readback.error
      assert readback.content =~ "inspection report"
    end

    test "only the current Task with no delivery recipients receives the result", %{agent: agent} do
      assert {:ok, _} =
               SalixAgent.AgentControl.configure(agent, %{
                 "inspector_policy" => SalixAgent.TestSupport.inspector_policy()
               })

      :ok = deliver_source(agent, "agent_task")

      safe = %{
        "connect_id" => "internal",
        "conversation_id" => @conversation_id,
        "content" => [%{"type" => "text", "text" => "inspection complete"}],
        "delivery_filter" => %{"participant_ids" => []}
      }

      Mock.script([
        {:assistant, "returning the result",
         [
           inspector_call("other-task", "im_api.internal.send_message", %{
             safe
             | "conversation_id" => "other-task"
           }),
           inspector_call("provider-recipient", "im_api.internal.send_message", %{
             safe
             | "delivery_filter" => %{"participant_ids" => ["slack-participant"]}
           }),
           inspector_call("safe-result", "im_api.internal.send_message", safe)
         ]},
        {:final, "done"}
      ])

      {:parked, _owned} = settle_quiet(agent)

      assert [{"internal", "internal.send_message", %{"params" => params}}] =
               provider_calls(agent)

      assert params["conversation_id"] == @conversation_id
      assert params["delivery_filter"] == %{"participant_ids" => []}
      assert drafts_seen(agent) == []
    end
  end

  defp inspector_call(id, tool, params),
    do: %{id: id, name: "call", args: %{"tool" => tool, "params" => params}}

  describe "the streaming draft" do
    test "waits for the decision under enforce", %{agent: agent} do
      put_mode("enforce")
      :ok = deliver_source(agent)
      script_reply("legal said the deal closes Friday")

      {:parked, _owned} = settle_quiet(agent)

      # Not one draft reached the conversation while the round was still
      # deciding. Deleting the gate from `on_tool_delta` fails here: the
      # fragments would publish exactly the text the check had not yet allowed.
      assert drafts_seen(agent) == []

      # And the reply itself did go, once it was allowed — withholding the
      # draft is a delay, not a refusal.
      assert Enum.any?(provider_calls(agent), fn {_provider, api, _args} ->
               api == "internal.send_message"
             end)
    end

    test "streams as before under audit, which may never change an outcome", %{agent: agent} do
      put_mode("audit")
      :ok = deliver_source(agent)
      script_reply("legal said the deal closes Friday")

      {:parked, _owned} = settle_quiet(agent)

      drafts = drafts_seen(agent)
      assert drafts != [], "audit mode must stream exactly as `off` does"

      # A draft is a prefix of the reply being written, never the session
      # transcript around it.
      for %{"text" => text} <- drafts do
        assert String.starts_with?("legal said the deal closes Friday", text)
      end

      assert Enum.any?(provider_calls(agent), fn {_provider, api, _args} ->
               api == "internal.send_message"
             end)
    end

    test "streams as before when the Group never opted in", %{agent: agent} do
      put_mode("off")
      :ok = deliver_source(agent)
      script_reply("legal said the deal closes Friday")

      {:parked, _owned} = settle(agent)

      assert drafts_seen(agent) != []
    end
  end

  describe "a refused effect" do
    for response <- [:explain, :silent] do
      @response response
      test "IFC reports both restricted sources before the agent can choose #{@response} and settle",
           %{
             agent: agent
           } do
        put_mode("enforce")
        put_destination(["scope|cnx1|C_ELSEWHERE"])
        :ok = deliver_source(agent)
        # Keep the first source as history before the second request starts its activation.
        Mock.script([{:final, ""}])
        {:parked, _} = settle(agent)

        assert {:ok, :created} =
                 SalixAgent.deliver(
                   agent,
                   %{
                     content: "also use the private follow-up",
                     session_id: @session_id,
                     trusted_origin: %{
                       "provider" => "internal",
                       "conversation_id" => @conversation_id,
                       "conversation_kind" => "user_chat",
                       "message_id" => "msg1_0000000000000000932",
                       "participant_id" => @participant_id,
                       "source_actor_type" => "user",
                       "agent_group_id" => @group_id,
                       "ifc" => %{
                         "label" => ["conversation|#{@conversation_id}"],
                         "integrity" => "command",
                         "principal" => @requester
                       }
                     }
                   },
                   source_message_id:
                     "groupconv:conv-ifc-e2e:msg1_0000000000000000932:par1_0000000000000000931"
                 )

        {:ok, initial} = SalixAgent.InternalSessionStore.read(agent, @session_id)

        {input_events, _, _} =
          SalixAgent.InternalSession.materialize_pending_input_events(initial)

        initial = SalixAgent.InternalSession.apply_events(initial, input_events)

        assert [first, latest] =
                 initial
                 |> SalixAgent.InternalSession.get(:messages)
                 |> Enum.filter(&(&1.role == "user"))

        source_refs = Enum.map([first, latest], &SalixAgent.IFC.input_ref(&1.id))
        request_ref = SalixAgent.IFC.input_ref(latest.id)

        refused =
          {:assistant, "trying the requested transfer",
           [
             %{
               id: "refused-send",
               name: "call",
               args: %{
                 "tool" => "im_api.internal.send_message",
                 "params" => %{
                   "connect_id" => "internal",
                   "conversation_id" => "conv-elsewhere",
                   "content" => [%{"type" => "text", "text" => "restricted answer"}]
                 },
                 "ifc" => %{"request" => request_ref, "sources" => source_refs}
               }
             }
           ]}

        explanation =
          {:assistant, "explaining without source content",
           [
             %{
               id: "generic-explanation",
               name: "call",
               args: %{
                 "tool" => "im_api.internal.send_message",
                 "params" => %{
                   "connect_id" => "internal",
                   "conversation_id" => @conversation_id,
                   "content" => [
                     %{"type" => "text", "text" => "I cannot provide that information here."}
                   ]
                 },
                 "ifc" => %{"request" => request_ref, "sources" => []}
               }
             }
           ]}

        end_turn =
          {:assistant, "",
           [
             %{
               id: "stop",
               name: "end_turn",
               args: %{
                 "outcome" => "blocked",
                 "reason" => "The requested transfer is not authorized."
               }
             }
           ],
           %{
             "responses_items" => [
               %{"type" => "function_call", "call_id" => "stop", "name" => "end_turn"}
             ]
           }}

        Mock.script(
          [refused] ++ if(@response == :explain, do: [explanation], else: []) ++ [end_turn]
        )

        {:parked, _owned} = settle(agent)

        assert eventually(
                 fn ->
                   {:ok, session} = SalixAgent.InternalSessionStore.read(agent, @session_id)

                   SalixAgent.InternalSession.get(session, :last_ack_message_id) >
                     SalixAgent.InternalSession.get(initial, :last_ack_message_id) and
                     not SalixAgent.InternalSession.needs_transcript_continuation?(session)
                 end,
                 600
               )

        {:ok, current} = SalixAgent.InternalSessionStore.read(agent, @session_id)

        refusal =
          current
          |> SalixAgent.InternalSession.get(:messages)
          |> Enum.find(&(&1[:tool_call_id] == "refused-send"))

        assert refusal
        guidance = Jason.decode!(refusal.content)
        assert guidance["clause"] in ["membership_unknown", "flow_denied"], inspect(guidance)
        assert Enum.map(guidance["source_failures"], & &1["ref"]) == source_refs

        sends =
          Enum.filter(provider_calls(agent), fn {_, api, _} -> api == "internal.send_message" end)

        assert length(sends) == if(@response == :explain, do: 1, else: 0)
        refute inspect(sends) =~ "restricted answer"

        if @response == :explain,
          do: assert(inspect(sends) =~ "I cannot provide that information here.")

        terminal = List.last(SalixAgent.InternalSession.get(current, :messages))
        assert SalixAgent.InternalSession.get(current, :last_ack_message_id) >= terminal.id

        assert Enum.any?(terminal.provider_meta["responses_items"], fn
                 %{"type" => "function_call_output", "call_id" => "stop", "output" => output} ->
                   Jason.decode!(output) == %{"status" => "accepted", "outcome" => "blocked"}

                 _ ->
                   false
               end)

        refute SalixAgent.InternalSession.needs_transcript_continuation?(current)
        refute SalixAgent.InternalSession.repeated_tool_results_exhausted?(current)
        refute SalixAgent.InternalSession.runaway_unsettled_rounds_exhausted?(current)
      end
    end

    test "never reaches the provider seam, and says so to the person", %{agent: agent} do
      # The destination is a place the requester's own conversation is not a
      # subset of, and nothing establishes membership, so the flow cannot be
      # allowed. Under enforce that is a refusal before the Tools seam.
      put_mode("enforce")
      put_destination(["scope|cnx1|C_ELSEWHERE"])
      :ok = deliver_source(agent)

      Mock.script([
        {:assistant, "relaying it",
         [
           %{
             id: "send-1",
             name: "call",
             args: %{
               "tool" => "im_api.internal.send_message",
               "params" => %{
                 "connect_id" => "internal",
                 "conversation_id" => "conv-elsewhere",
                 "content" => [%{"type" => "text", "text" => "the answer"}]
               },
               "ifc" => %{"request" => "src:q-1", "sources" => ["src:q-1"]}
             }
           }
         ]},
        {:final, "I could not carry that over"}
      ])

      {:parked, _owned} = settle(agent)

      # Nothing crossed the seam. This is the whole point of deciding before
      # `Tools.execute/2` rather than after.
      refute Enum.any?(provider_calls(agent), fn {_provider, api, _args} ->
               api == "internal.send_message"
             end)

      # And the round still finished with something to say.
      assert "I could not carry that over" in assistant_contents(agent)
    end

    test "executes anyway under audit, which is what makes audit measurable", %{agent: agent} do
      put_mode("audit")
      put_destination(["scope|cnx1|C_ELSEWHERE"])
      :ok = deliver_source(agent)

      Mock.script([
        {:assistant, "relaying it",
         [
           %{
             id: "send-1",
             name: "call",
             args: %{
               "tool" => "im_api.internal.send_message",
               "params" => %{
                 "connect_id" => "internal",
                 "conversation_id" => "conv-elsewhere",
                 "content" => [%{"type" => "text", "text" => "the answer"}]
               },
               "ifc" => %{"request" => "src:q-1", "sources" => ["src:q-1"]}
             }
           }
         ]},
        {:final, "sent"}
      ])

      {:parked, _owned} = settle_quiet(agent)

      # The same decision was made and archived; the effect ran regardless.
      assert Enum.any?(provider_calls(agent), fn {_provider, api, args} ->
               api == "internal.send_message" and
                 get_in(args, ["params", "conversation_id"]) == "conv-elsewhere"
             end)
    end
  end

  describe "asynchronous result provenance" do
    test "a deferred write completion can be cited back to its original audience", %{agent: agent} do
      put_mode("enforce")
      :ok = deliver_source(agent)

      Mock.script([
        {:assistant, "sending",
         [
           %{
             id: "deferred-write",
             name: "call",
             args: %{
               "tool" => "im_api.internal.send_message",
               "params" => %{
                 "connect_id" => "internal",
                 "conversation_id" => @conversation_id,
                 "content" => "what they told me",
                 "request_id" => "deferred-ifc-result"
               },
               "ifc" => %{"request" => "src:q-1", "sources" => ["src:q-1"]}
             }
           }
         ]},
        {:final, "sent"}
      ])

      Server.wake(agent)
      assert_receive {:deferred_ifc_result, worker}, 5_000

      assert eventually(
               fn ->
                 {:ok, session} = SalixAgent.InternalSessionStore.read(agent, @session_id)

                 match?(
                   {:ok, %{"status" => "running"}},
                   SalixAgent.InternalSession.lookup_async_call(session, "deferred-write")
                 )
               end,
               400
             )

      send(worker, :finish_ifc_result)

      assert eventually(
               fn ->
                 {:ok, session} = SalixAgent.InternalSessionStore.read(agent, @session_id)

                 Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
                   message[:type] == "tool_call_completed" and
                     message[:source_tool_call_id] == "deferred-write"
                 end)
               end,
               400
             )

      {:ok, session} = SalixAgent.InternalSessionStore.read(agent, @session_id)

      notification =
        Enum.find(SalixAgent.InternalSession.get(session, :messages), fn message ->
          message[:type] == "tool_call_completed" and
            message[:source_tool_call_id] == "deferred-write"
        end)

      assert notification.ifc == %{"label" => ["conversation|#{@conversation_id}"]}

      assert {:ok, %{"result" => %{"ifc" => label}}} =
               SalixAgent.InternalSession.lookup_async_call(session, "deferred-write")

      assert label == notification.ifc

      wire =
        SalixAgent.IFC.Context.build(session,
          source_message_id: @encoded_source,
          source_message_ids: [@encoded_source]
        )

      followup = %{
        id: "cite-completion",
        name: "im_api.internal.send_message",
        args: %{"connect_id" => "internal", "conversation_id" => @conversation_id},
        ifc: %{"request" => "src:q-1", "sources" => ["src:a-#{notification.id}"]}
      }

      assert [{:execute, _}] =
               SalixAgent.IFC.Check.authorize([{:execute, followup}], %{
                 ifc: wire,
                 ifc_mode: :enforce,
                 agent_id: agent,
                 session_id: @session_id
               })
    end
  end

  describe "what the workspace holds afterwards" do
    test "a file written under enforce records what the write drew on", %{agent: agent} do
      put_mode("enforce")
      :ok = deliver_source(agent)

      Mock.script([
        {:assistant, "noting it down",
         [
           %{
             id: "write-1",
             name: "call",
             args: %{
               "tool" => "fs.write_file",
               "params" => %{
                 "path" => "/notes/from-the-conversation.md",
                 "content" => "what they told me"
               },
               "ifc" => %{"request" => "src:q-1", "sources" => ["src:q-1"]}
             }
           }
         ]},
        {:final, "noted"}
      ])

      {:parked, _owned} = settle(agent)

      # The durable product effect: the file exists and carries the audience of
      # the message it was written from, so a later activation reading it is no
      # weaker than reading that message would have been (§8). The write runs
      # asynchronously, so this waits for it rather than for the round.
      assert eventually(fn -> written?(agent, "/notes/from-the-conversation.md") end, 400)

      assert SalixAgent.AgentWorkspace.label(agent, "/notes/from-the-conversation.md") ==
               ["conversation|#{@conversation_id}"]
    end

    test "a file written while the Group is off records nothing", %{agent: agent} do
      # Nothing was decided, so nothing is claimed. The file reads as
      # agent-private the day the Group turns the check on, which is the
      # fail-closed reading.
      put_mode("off")
      :ok = deliver_source(agent)

      Mock.script([
        {:assistant, "noting it down",
         [
           %{
             id: "write-1",
             name: "call",
             args: %{
               "tool" => "fs.write_file",
               "params" => %{"path" => "/notes/plain.md", "content" => "hello"}
             }
           }
         ]},
        {:final, "noted"}
      ])

      {:parked, _owned} = settle(agent)

      assert eventually(fn -> written?(agent, "/notes/plain.md") end, 400)
      assert SalixAgent.AgentWorkspace.label(agent, "/notes/plain.md") == nil
    end

    # The file from the previous test is the dangerous one: it reads as
    # agent-private because nobody recorded its audience, and an edit that
    # keeps most of it can honestly declare only the request that caused it.
    # If the write took that declaration alone, a marker edit would publish
    # whatever the Group turned enforcement on to protect.
    test "an edit cannot relabel the part of an unlabelled file it kept", %{agent: agent} do
      put_mode("off")
      :ok = write_unlabelled(agent, "/notes/kept.md", "TODO ship\nSalary: 123")
      assert SalixAgent.AgentWorkspace.label(agent, "/notes/kept.md") == nil

      put_mode("enforce")
      :ok = deliver_source(agent)

      Mock.script([
        {:assistant, "flipping the marker",
         [
           %{
             id: "edit-1",
             name: "call",
             args: %{
               "tool" => "fs.edit_file",
               "params" => %{"path" => "/notes/kept.md", "old" => "TODO", "new" => "DONE"},
               "ifc" => %{"request" => "src:q-1", "sources" => []}
             }
           }
         ]},
        {:final, "done"}
      ])

      {:parked, _owned} = settle(agent)

      # `sources: []` is an honest declaration — the edit really did draw on
      # nothing but the request. The salary line survives regardless, so the
      # file keeps the only audience its content can be read under.
      assert eventually(fn -> edited?(agent, "/notes/kept.md", "DONE ship") end, 400)
      assert SalixAgent.AgentWorkspace.label(agent, "/notes/kept.md") == ["agent_private"]
    end

    test "a full replacement of an unlabelled file inherits nothing", %{agent: agent} do
      put_mode("off")
      :ok = write_unlabelled(agent, "/notes/replaced.md", "Salary: 123")

      put_mode("enforce")
      :ok = deliver_source(agent)

      Mock.script([
        {:assistant, "replacing it",
         [
           %{
             id: "write-2",
             name: "call",
             args: %{
               "tool" => "fs.write_file",
               "params" => %{"path" => "/notes/replaced.md", "content" => "what they told me"},
               "ifc" => %{"request" => "src:q-1", "sources" => ["src:q-1"]}
             }
           }
         ]},
        {:final, "replaced"}
      ])

      {:parked, _owned} = settle(agent)

      # Nothing of the old file survives, so inheriting its audience would
      # strand an ordinary note as agent-private for no reason.
      assert eventually(fn -> edited?(agent, "/notes/replaced.md", "what they told me") end, 400)

      assert SalixAgent.AgentWorkspace.label(agent, "/notes/replaced.md") ==
               ["conversation|#{@conversation_id}"]
    end
  end

  # A file the check never saw: written while the Group was `off`, so the
  # manifest entry exists and carries no `ifc_label`.
  defp write_unlabelled(agent, path, content) do
    {:ok, event} = SalixAgent.StorageAuthorization.prepare_write(agent, path, content, %{})
    {:ok, _} = SalixAgent.AgentActor.commit_workspace_operation(agent, path, nil, [event], [])
    :ok
  end

  defp edited?(agent, path, expected) do
    case SalixAgent.FileBackend.read(%{agent_id: agent}, path) do
      {:ok, body, _truncated} -> String.contains?(body, expected)
      _other -> false
    end
  end
end
