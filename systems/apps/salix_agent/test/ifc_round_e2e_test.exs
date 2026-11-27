defmodule SalixAgent.IFCRoundE2ETest do
  require SystemsRuntime.Proc

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
  therefore waits for the decision. Audit keeps incremental drafts before
  declaration validation and permission checks. Completed calls still require
  valid declarations, but permission denials do not block audit execution.
  """

  use SystemsClock.Case, async: false

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

    def mode(_tenant_id, _group_id),
      do: SystemsRuntime.PersistentTerm.get({SalixAgent.IFCRoundE2ETest, :mode})

    def resolve(request) do
      case SystemsRuntime.PersistentTerm.get({SalixAgent.IFCRoundE2ETest, :test_pid}, nil) do
        pid when is_pid(pid) ->
          SystemsRuntime.Proc.send(pid, {:ifc_resolve, request["destination"]})

        _none ->
          :ok
      end

      {:ok,
       %{
         "mode" => SystemsRuntime.PersistentTerm.get({SalixAgent.IFCRoundE2ETest, :mode}),
         "destination" => %{"label" => destination(request), "writers" => "any"},
         "scopes" => %{},
         "membership" => %{},
         "placements" => %{},
         "receipts" => [],
         "policy" => %{},
         "display_names" => %{},
         "now" => SystemsClock.system_time(:millisecond)
       }}
    end

    def consume_receipt(_request), do: {:ok, true}

    # The real resolver reads the descriptor; this one only needs to tell the
    # agent's own workspace apart from a conversation.
    defp destination(%{"destination" => %{"kind" => "agent_private"}}), do: ["agent_private"]

    defp destination(%{
           "destination" => %{"kind" => "provider_direct", "provider" => "lark", "user_id" => id}
         }) do
      SystemsRuntime.PersistentTerm.get({SalixAgent.IFCRoundE2ETest, :destination})
      |> Map.fetch!(id)
    end

    defp destination(_request) do
      case SystemsRuntime.PersistentTerm.get({SalixAgent.IFCRoundE2ETest, :destination}) do
        %{} = destinations -> Map.fetch!(destinations, "default")
        atoms -> atoms
      end
    end
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
      case SystemsRuntime.PersistentTerm.get({SalixAgent.IFCRoundE2ETest, :test_pid}, nil) do
        nil -> :ok
        pid -> SystemsRuntime.Proc.send(pid, {:notified, agent_id, event})
      end
    end
  end

  defmodule RecordingIMProvider do
    @moduledoc false
    @behaviour SalixAgent.Tools.ImRouter

    @owner_key {__MODULE__, :owner}

    def set_owner(owner), do: SystemsRuntime.PersistentTerm.put(@owner_key, owner)
    def clear, do: SystemsRuntime.PersistentTerm.erase(@owner_key)

    @impl true
    def list_connects(_agent_id),
      do:
        {:ok,
         [
           %{"connect_id" => "internal", "provider" => "internal"},
           %{"connect_id" => "slack-1", "provider" => "slack"},
           %{"connect_id" => "lark-1", "provider" => "lark"}
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
                 {"slack.reply_message", "write"},
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

    def provider_manual("lark") do
      {:ok,
       %{
         "provider" => "lark",
         "apis" => [
           %{
             "name" => "lark.send_message",
             "safety" => "write",
             "required_params" => ["text"],
             "parameters" => %{
               "chat_id" => "Chat ID",
               "user_id" => "Person",
               "reply_to" => "Message ID",
               "text" => "Text"
             }
           }
           | for api <- ~w(lark.create_chat lark.add_chat_members) do
               %{
                 "name" => api,
                 "safety" => "admin",
                 "required_params" => ["user_ids"],
                 "parameters" => %{
                   "name" => "Group name",
                   "chat_id" => "Group ID",
                   "user_ids" => "Member IDs"
                 }
               }
             end
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    def builtin_provider_manual(provider), do: provider_manual(provider)

    @impl true
    def call_api(agent_id, provider, api, args) do
      owner = SystemsRuntime.PersistentTerm.get(@owner_key)
      SystemsRuntime.Proc.send(owner, {:im_provider_call, agent_id, provider, api, args})

      if get_in(args, ["params", "request_id"]) == "deferred-ifc-result" do
        SystemsRuntime.Proc.send(owner, {:deferred_ifc_result, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
          :finish_ifc_result -> :ok
        after
          5_000 -> raise "test did not release deferred result"
        end
      end

      if api == "slack.get_channel_history" do
        SystemsRuntime.Proc.send(owner, {:onboarding_read, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
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
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      notifier: SystemsRuntime.get_env(:salix_agent, :notifier),
      llm: SystemsRuntime.get_env(:salix_agent, :llm),
      im: SystemsRuntime.get_env(:salix_agent, :im_provider_mod),
      visible_reply: SystemsRuntime.get_env(:salix_agent, :visible_reply_mod),
      facts: SystemsRuntime.get_env(:salix_agent, :ifc_facts_mod)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)
    SystemsRuntime.put_env(:salix_agent, :notifier, DraftWatchingNotifier)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, RecordingIMProvider)
    SystemsRuntime.put_env(:salix_agent, :visible_reply_mod, TestVisibleReply)
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, Facts)
    RecordingIMProvider.set_owner(SystemsRuntime.Proc.self())
    SystemsRuntime.PersistentTerm.put(@pid_key, SystemsRuntime.Proc.self())
    put_mode("off")
    put_destination(["conversation|#{@conversation_id}"])

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      RecordingIMProvider.clear()
      SystemsRuntime.PersistentTerm.erase(@pid_key)
      SystemsRuntime.PersistentTerm.erase({__MODULE__, :mode})
      SystemsRuntime.PersistentTerm.erase({__MODULE__, :destination})
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

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp put_mode(mode), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :mode}, mode)

  defp put_destination(atoms),
    do: SystemsRuntime.PersistentTerm.put({__MODULE__, :destination}, atoms)

  # One inbound from a person, into a conversation the agent may reply into, so
  # the round has a visible reply scope and a request it can cite.
  defp commit_thread_inputs(agent, first, second) do
    queued = fn queue_source, principal ->
      %{
        "type" => "queue_append",
        "session_id" => @session_id,
        "kind" => "user_message",
        "wake" => true,
        "dedupe_key" => queue_source,
        "payload" => %{
          "source_message_id" => queue_source,
          "content" => queue_source,
          "role" => "user",
          "trusted_origin" => %{
            "provider" => "slack",
            "source_actor_type" => "provider_user",
            "source_message_id" => queue_source,
            "provider_context" => %{
              "connect_id" => "cnx1",
              "channel_id" => "C1",
              "thread_ts" => "1.0"
            },
            "ifc" => %{
              "label" => ["scope|cnx1|C1"],
              "integrity" => "command",
              "principal" => principal
            }
          }
        }
      }
    end

    {:ok, _session} =
      SalixAgent.TestSupport.SessionFixture.commit(agent, @session_id, [
        %{"type" => "session_created", "session_id" => @session_id},
        queued.("im_provider:slack:cnx1:first", first),
        queued.("im_provider:slack:cnx1:second", second)
      ])
  end

  defp deliver_source(agent, conversation_kind \\ "user_chat", origin_overrides \\ %{}) do
    {:ok, _session} =
      SalixAgent.TestSupport.SessionFixture.commit(agent, @session_id, [
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
                "source_message_id" => @encoded_source,
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
    assert eventually(fn -> settled?(agent) end, 3000)
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
      true -> SystemsRuntime.Proc.sleep(10) && eventually(fun, retries - 1)
    end
  end

  # Every draft that was live at some notification during the round.
  defp drafts_seen(agent) do
    SystemsRuntime.Proc.receive do
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
    SystemsRuntime.Proc.receive do
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

  for {members, allowed} <- [{["ou_alice"], true}, {["ou_alice", "ou_bob"], false}] do
    @lark_members members
    @lark_creation_allowed allowed
    test "Lark group creation checks every recipient under enforce (allowed: #{allowed})", %{
      agent: agent
    } do
      put_mode("enforce")

      put_destination(%{
        "default" => ["conversation|#{@conversation_id}"],
        "ou_alice" => ["conversation|#{@conversation_id}"],
        "ou_bob" => ["public"]
      })

      :ok = deliver_source(agent)

      Mock.script([
        {:assistant, "creating the requested group",
         [
           %{
             id: "create-group",
             name: "call",
             args: %{
               "tool" => "im_api.lark.create_chat",
               "params" => %{
                 "connect_id" => "lark-1",
                 "name" => "Project",
                 "user_ids" => @lark_members
               },
               "ifc" => %{"request" => "src:q-1", "sources" => ["src:q-1"]}
             }
           }
         ]},
        {:final, "done"}
      ])

      {:parked, _owned} = settle_quiet(agent)

      if @lark_creation_allowed do
        assert [{"lark", "lark.create_chat", %{"params" => params}}] = provider_calls(agent)
        assert params["name"] == "Project"
        assert params["user_ids"] == @lark_members
      else
        assert provider_calls(agent) == []
      end
    end
  end

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
          ["src:t-research"]
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
      assert_receive {:onboarding_read, reader}

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

      SystemsRuntime.Proc.send(reader, :finish_onboarding_read)

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
               3000
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
        previous = SystemsRuntime.get_env(:salix_agent, :repeated_tool_result_cap)
        SystemsRuntime.put_env(:salix_agent, :repeated_tool_result_cap, 2)
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
                     "ifc" => %{"sources" => []},
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
               3000
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

  # Lark's (and Feishu's) bot joins a chat, not a channel: the welcome is a
  # chat send to the joined chat itself, and a reply in it is not a welcome.
  for {target, sent} <- [
        {%{"chat_id" => "oc_join"}, true},
        {%{"chat_id" => "oc_join", "reply_to" => "om_1"}, false},
        {%{"chat_id" => "oc_other"}, false}
      ] do
    @target target
    @sent sent
    @tag :onboarding

    test "a Lark welcome #{inspect(target)} settles the optional activation (sent: #{sent})", %{
      agent: _worker
    } do
      agent = SalixAgent.TestSupport.new_agent_id()
      record = SalixAgent.TestSupport.create_control_agent!(agent, %{"role" => "router"})
      {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(record)
      group = record["group_id"]
      SalixAgent.TestSupport.create_control_group!(group, %{"router_agent_id" => agent})
      source = "im_provider:lark:lark-1:channel_joined:oc_join:evt_join"

      origin = %{
        "provider" => "lark",
        "source_actor_type" => "provider_user",
        "agent_group_id" => group,
        "source_message_id" => source,
        "provider_context" => %{
          "connect_id" => "lark-1",
          "chat_id" => "oc_join",
          "chat_type" => "group",
          "event_id" => "evt_join",
          "event_type" => "im.chat.member.bot.added_v1"
        },
        "ifc" => %{"label" => ["space|lark-1"], "integrity" => "data", "principal" => nil}
      }

      put_mode("enforce")
      put_destination(["space|lark-1"])

      Mock.script([
        {:assistant, "welcome",
         [
           %{
             id: "welcome",
             name: "call",
             args: %{
               "tool" => "im_api.lark.send_message",
               "params" => Map.merge(%{"connect_id" => "lark-1", "text" => "Hello"}, @target),
               "ifc" => %{"sources" => []}
             }
           }
         ]},
        {:final, "done"}
      ])

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
                 )
               end,
               3000
             )

      sends =
        Enum.count(provider_calls(agent), fn {_, api, _} -> api == "lark.send_message" end)

      assert sends == if(@sent, do: 1, else: 0)
    end
  end

  describe "Inspector effect authority" do
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
      assert eventually(fn -> written?(agent, report_path) end, 3000)
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
    do: %{
      id: id,
      name: "call",
      args: %{"tool" => tool, "params" => params, "ifc" => %{"sources" => ["src:q-1"]}}
    }

  describe "the streaming draft" do
    test "audit publishes a draft before the complete call reaches permission checks", %{
      agent: agent
    } do
      put_mode("audit")
      :ok = deliver_source(agent)
      script_reply(String.duplicate("A longer answer can be read while it is generated. ", 20))
      {:parked, _owned} = settle_quiet(agent)

      {:messages, messages} = Process.info(self(), :messages)
      draft = Enum.find_index(messages, &match?({:notified, ^agent, {:draft_seen, _}}, &1))
      decision = Enum.find_index(messages, &match?({:ifc_resolve, _}, &1))

      sent =
        Enum.find_index(
          messages,
          &match?({:im_provider_call, ^agent, _, "internal.send_message", _}, &1)
        )

      assert is_integer(draft), "audit must show a draft during generation"
      assert is_integer(decision)
      assert is_integer(sent)
      assert draft < decision
      assert decision < sent
    end

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
  end

  describe "one decision per call" do
    test "a reply the round plans and then runs is decided once", %{agent: agent} do
      put_mode("audit")
      :ok = deliver_source(agent)
      script_reply("the deal closes Friday")

      {:parked, _owned} = settle_quiet(agent)

      assert Enum.any?(provider_calls(agent), fn {_provider, api, _args} ->
               api == "internal.send_message"
             end)

      assert [_one] = resolves()
    end
  end

  defp resolves do
    SystemsRuntime.Proc.receive do
      {:ifc_resolve, destination} -> [destination | resolves()]
    after
      0 -> []
    end
  end

  test "private rounds retain tool corrections and still refuse the corrected send", %{
    agent: agent
  } do
    put_mode("enforce")
    put_destination(["scope|cnx1|C_ELSEWHERE"])
    :ok = deliver_source(agent)

    Mock.script([
      {:assistant, "checking the receipt",
       [%{id: "bad-tool", name: "get_runtime_message", args: %{}}]},
      {:assistant, "sending",
       [
         inspector_call("bad-params", "im_api.internal.send_message", %{
           "connect_id" => "internal"
         })
       ]},
      {:assistant, "correcting the parameters",
       [
         %{
           id: "corrected-send",
           name: "call",
           args: %{
             "ifc" => %{"sources" => ["src:q-1"]},
             "tool" => "im_api.internal.send_message",
             "params" => %{
               "connect_id" => "internal",
               "conversation_id" => "conv-elsewhere",
               "content" => [%{"type" => "text", "text" => "the answer"}]
             }
           }
         }
       ]},
      {:final, "I could not carry that over"}
    ])

    {:parked, _owned} = settle(agent)
    {:ok, session} = SalixAgent.InternalSessionStore.read(agent, @session_id)

    results =
      for message <- SalixAgent.InternalSession.get(session, :messages),
          message.role == "tool",
          into: %{},
          do: {message.tool_call_id, Jason.decode!(message.content)}

    assert results["bad-tool"]["guidance_reason"] == "envelope_misuse"
    assert results["bad-tool"]["error"] =~ "wait_for"
    assert results["bad-params"]["guidance_reason"] == "invalid_params"
    # This fixture has no membership facts for the other conversation.
    # The corrected effect must fail closed at IFC and never reach the provider.
    assert results["corrected-send"]["clause"] == "membership_unknown"

    refute Enum.any?(provider_calls(agent), fn {_provider, api, _args} ->
             api == "internal.send_message"
           end)
  end

  describe "a refused effect" do
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

    test "under audit reaches the provider seam with its requester and no evidence", %{
      agent: agent
    } do
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
        {:final, "done"}
      ])

      {:parked, _owned} = settle_quiet(agent)

      assert {_provider, _api, %{"tool_context" => context}} =
               Enum.find(provider_calls(agent), &match?({_, "internal.send_message", _}, &1))

      assert context["ifc_requester"] == @requester
      refute Map.has_key?(context, "ifc_evidence")
    end
  end

  describe "an activation holding one thread's inputs" do
    test "decides each effect for the input it declares", %{agent: agent} do
      put_mode("audit")
      put_destination(["scope|cnx1|C_ELSEWHERE"])
      first = "provider_user|cnx1|U-first"
      second = "provider_user|cnx1|U-second"
      commit_thread_inputs(agent, first, second)

      send_call = fn id, ifc ->
        %{
          id: id,
          name: "call",
          args: %{
            "tool" => "im_api.internal.send_message",
            "params" => %{
              "connect_id" => "internal",
              "conversation_id" => "conv-elsewhere",
              "content" => [%{"type" => "text", "text" => id}]
            },
            "ifc" => ifc
          }
        }
      end

      Mock.script([
        {:assistant, "first",
         [send_call.("send-first", %{"request" => "src:q-1", "sources" => ["src:q-1"]})]},
        {:assistant, "second",
         [send_call.("send-second", %{"request" => "src:q-2", "sources" => ["src:q-2"]})]},
        {:final, "done"}
      ])

      {:ok, _pid} = Fleet.ensure_started(agent, create: true)
      {:parked, _owned} = settle_quiet(agent)

      assert [{first, "im_provider:slack:cnx1:first"}, {second, "im_provider:slack:cnx1:second"}] ==
               provider_calls(agent)
               |> Enum.filter(&match?({_, "internal.send_message", _}, &1))
               |> Enum.map(fn {_provider, _api, %{"tool_context" => context}} ->
                 {context["ifc_requester"], context["trusted_origin"]["source_message_id"]}
               end)
    end
  end

  describe "an activation with several senders" do
    test "refuses an effect that names no input under enforce", %{agent: agent} do
      put_mode("enforce")
      put_destination(["scope|cnx1|C1"])
      commit_thread_inputs(agent, "provider_user|cnx1|U-first", "provider_user|cnx1|U-second")

      Mock.script([
        {:assistant, "sending",
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
               "ifc" => %{"sources" => []}
             }
           }
         ]},
        {:final, "done"}
      ])

      {:ok, _pid} = Fleet.ensure_started(agent, create: true)
      {:parked, _owned} = settle_quiet(agent)

      refute Enum.any?(provider_calls(agent), &match?({_, "internal.send_message", _}, &1))
    end
  end

  describe "a Loop that arrives beside a person" do
    test "an effect that names no input acts for the person under enforce", %{agent: agent} do
      put_mode("enforce")
      put_destination(["scope|cnx1|C1"])
      person = "provider_user|cnx1|U-person"
      source = "im_provider:slack:cnx1:person"

      {:ok, _session} =
        SalixAgent.TestSupport.SessionFixture.commit(agent, @session_id, [
          %{"type" => "session_created", "session_id" => @session_id},
          %{
            "type" => "queue_append",
            "session_id" => @session_id,
            "kind" => "user_message",
            "wake" => true,
            "dedupe_key" => source,
            "payload" => %{
              "source_message_id" => source,
              "content" => "the person's question",
              "role" => "user",
              "trusted_origin" => %{
                "provider" => "slack",
                "source_actor_type" => "provider_user",
                "source_message_id" => source,
                "provider_context" => %{
                  "connect_id" => "cnx1",
                  "channel_id" => "C1",
                  "thread_ts" => "1.0"
                },
                "ifc" => %{
                  "label" => ["scope|cnx1|C1"],
                  "integrity" => "command",
                  "principal" => person
                }
              }
            }
          },
          %{
            "type" => "queue_append",
            "session_id" => @session_id,
            "kind" => "user_message",
            "wake" => true,
            "dedupe_key" => "loop:lop1:1",
            "payload" => %{
              "source_message_id" => "loop:lop1:1",
              "content" => "the Loop's report",
              "role" => "user"
            }
          }
        ])

      send_call = fn id ->
        %{
          id: id,
          name: "call",
          args: %{
            "tool" => "im_api.internal.send_message",
            "params" => %{
              "connect_id" => "internal",
              "conversation_id" => "conv-elsewhere",
              "content" => [%{"type" => "text", "text" => id}]
            },
            "ifc" => %{"sources" => []}
          }
        }
      end

      Mock.script([
        {:assistant, "first", [send_call.("send-first")]},
        {:assistant, "second", [send_call.("send-second")]},
        {:final, "done"}
      ])

      {:ok, _pid} = Fleet.ensure_started(agent, create: true)
      {:parked, _owned} = settle_quiet(agent)

      assert [{^person, ^source}, {^person, ^source}] =
               provider_calls(agent)
               |> Enum.filter(&match?({_, "internal.send_message", _}, &1))
               |> Enum.map(fn {_provider, _api, %{"tool_context" => context}} ->
                 {context["ifc_evidence"]["requester"],
                  context["trusted_origin"]["source_message_id"]}
               end)
    end
  end

  describe "asynchronous result provenance" do
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
      assert eventually(fn -> written?(agent, "/notes/from-the-conversation.md") end, 3000)

      assert SalixAgent.AgentWorkspace.label(agent, "/notes/from-the-conversation.md") ==
               ["conversation|#{@conversation_id}"]
    end
  end

  test "direct session metadata keeps absence distinct from an explicit null declaration", %{
    agent: agent
  } do
    put_mode("enforce")
    :ok = deliver_source(agent)

    assert {:ok, help, pending, _, _} =
             SalixAgent.SessionToolExecution.execute(
               agent,
               @session_id,
               :internal,
               [@encoded_source],
               "help",
               %{"tool" => "ifc"}
             )

    help =
      case pending do
        [] ->
          help

        [pending] ->
          assert {:ok, result} = SalixAgent.DependencyJob.yield(pending.dependency_job, 5_000)
          result
      end

    assert Jason.decode!(help.content)["manual"]

    assert {:ok, rejected, [], _, _} =
             SalixAgent.SessionToolExecution.execute(
               agent,
               @session_id,
               :internal,
               [@encoded_source],
               "help",
               %{"tool" => "ifc", "ifc" => nil}
             )

    assert Jason.decode!(rejected.content)["guidance_reason"] == "invalid_params"
    assert provider_calls(agent) == []
    # Background inference may resolve public projection facts. No effect facts are needed.
    assert Enum.reject(resolves(), &(&1 == %{"kind" => "public"})) == []
  end

  test "direct session calls require a declaration and audit still delivers a valid denied call",
       %{agent: agent} do
    put_mode("audit")
    put_destination(["scope|cnx1|C_ELSEWHERE"])
    :ok = deliver_source(agent)

    args = %{
      "connect_id" => "internal",
      "conversation_id" => @conversation_id,
      "content" => [%{"type" => "text", "text" => "direct"}]
    }

    assert {:ok, rejected, [], _, _} =
             SalixAgent.SessionToolExecution.execute(
               agent,
               @session_id,
               :internal,
               [@encoded_source],
               "im_api.internal.send_message",
               args
             )

    assert Jason.decode!(rejected.content)["guidance_reason"] == "invalid_params"
    assert provider_calls(agent) == []
    assert resolves() == []

    assert {:ok, result, _pending, _, _} =
             SalixAgent.SessionToolExecution.execute(
               agent,
               @session_id,
               :internal,
               [@encoded_source],
               "im_api.internal.send_message",
               Map.put(args, "ifc", %{"sources" => ["src:q-1"]})
             )

    assert result.status in ["completed", "async_running"]

    SystemsRuntime.Proc.receive do
      {:im_provider_call, ^agent, "internal", "internal.send_message", _} -> :ok
    end

    assert [_] = resolves()
  end

  defmodule DeclarationLLM do
    def complete(messages, tools) do
      owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner})
      SystemsRuntime.Proc.send(owner, {:declaration_specs, tools})
      SystemsRuntime.Proc.send(owner, {:projection_messages, messages})
      response = SalixAgent.LLM.Mock.complete(messages, tools)

      case response do
        {:assistant, text, [%{id: "repair-fields", args: args} = call]} ->
          tool = Enum.find(tools, &(&1["name"] == "end_turn"))

          description =
            get_in(tool, ["parameters", "properties", "reply", "description"]) ||
              get_in(tool, ["input_schema", "properties", "reply", "description"]) || ""

          contract = description |> String.split("\n") |> List.last() |> Jason.decode()

          args =
            case contract do
              {:ok, %{"im_api.slack.reply_message" => %{"properties" => fields}}} ->
                if Map.has_key?(fields, "channel") do
                  update_in(args, ["reply", "params"], fn p ->
                    {v, p} = Map.pop(p, "channel_id")
                    Map.put(p, "channel", v)
                  end)
                else
                  args
                end

              _ ->
                args
            end

          {:assistant, text, [%{call | args: args}]}

        other ->
          other
      end
    end
  end

  for rounds <- [7, 8] do
    @cap_rounds rounds
    @tag :hard_convergence
    test "visible no-progress streak #{rounds} selects tools and still delivers end_turn reply",
         %{agent: agent} do
      agent = SalixAgent.TestSupport.new_agent_id()
      record = SalixAgent.TestSupport.create_control_agent!(agent, %{"role" => "router"})
      {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(record)
      put_mode("enforce")
      SystemsRuntime.put_env(:salix_agent, :llm, DeclarationLLM)
      SystemsRuntime.PersistentTerm.put({DeclarationLLM, :owner}, SystemsRuntime.Proc.self())
      on_exit(fn -> SystemsRuntime.PersistentTerm.erase({DeclarationLLM, :owner}) end)
      label = ["conversation|#{@conversation_id}"]

      origin = %{
        "provider" => "internal",
        "source_message_id" => @encoded_source,
        "conversation_id" => @conversation_id,
        "conversation_kind" => "user_chat",
        "message_id" => @source_message_id,
        "participant_id" => @participant_id,
        "source_actor_type" => "user",
        "agent_group_id" => @group_id,
        "ifc" => %{"label" => label, "integrity" => "command", "principal" => @requester}
      }

      messages =
        [
          %{
            id: 1,
            role: "user",
            content: "Please answer.",
            source_message_id: @encoded_source,
            trusted_origin: origin
          }
        ] ++
          Enum.flat_map(1..@cap_rounds, fn n ->
            [
              %{
                id: 2 * n,
                role: "assistant",
                content: "",
                ifc_view_label: label,
                tool_calls: [
                  %{
                    id: "explore-#{n}",
                    name: "call",
                    args: %{
                      "tool" => "history.search",
                      "params" => %{"query" => "q#{n}"},
                      "ifc" => %{"sources" => []}
                    }
                  }
                ]
              },
              %{
                id: 2 * n + 1,
                role: "tool",
                tool_call_id: "explore-#{n}",
                ifc_view_label: label,
                ifc: %{"label" => label},
                content: ~s({"results":[]})
              }
            ]
          end)

      state = %SalixAgent.InternalSession.State{
        agent_id: agent,
        session_id: session_id,
        messages: messages,
        next_message_id: length(messages) + 1
      }

      :ok =
        SalixAgent.TestSupport.SessionFixture.seed(agent, SalixAgent.InternalSession.open(state))

      Mock.script([
        {:assistant, "",
         [
           %{
             id: "finish",
             name: "end_turn",
             args: %{
               "outcome" => "done",
               "reply" => %{
                 "tool" => "im_api.internal.send_message",
                 "params" => %{
                   "connect_id" => "internal",
                   "conversation_id" => @conversation_id,
                   "reply_to_message_id" => @source_message_id,
                   "content" => [%{"type" => "text", "text" => "Please provide more context."}]
                 },
                 "ifc" => %{"sources" => []}
               }
             }
           }
         ]}
      ])

      {:ok, _pid} = Fleet.ensure_started(agent, create: true)
      Server.wake(agent)
      assert eventually(fn -> settled?(agent) end, 3000)
      :ok = SalixAgent.TestSupport.await_session_quiet(agent, session_id)
      assert_received {:declaration_specs, specs}
      assert_received {:projection_messages, _seen_messages}
      names = Enum.map(specs, & &1["name"])

      if @cap_rounds == 8,
        do: assert(names == ["end_turn"]),
        else: assert("call" in names and "wait_for" in names)

      assert_received {:im_provider_call, ^agent, "internal", "internal.send_message", _}
    end
  end

  for rounds <- [8] do
    @repair_rounds rounds
    @tag :hard_convergence
    test "capped reply recovers a wrong channel field from public contract without prefix changes",
         %{agent: agent} do
      agent = SalixAgent.TestSupport.new_agent_id()
      record = SalixAgent.TestSupport.create_control_agent!(agent, %{"role" => "router"})
      {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(record)
      put_mode("enforce")
      SystemsRuntime.put_env(:salix_agent, :llm, DeclarationLLM)
      SystemsRuntime.PersistentTerm.put({DeclarationLLM, :owner}, SystemsRuntime.Proc.self())
      on_exit(fn -> SystemsRuntime.PersistentTerm.erase({DeclarationLLM, :owner}) end)
      label = ["scope|slack-1|C_REPLY"]
      put_destination(label)

      origin = %{
        "provider" => "slack",
        "source_actor_type" => "provider_user",
        "source_message_id" => @encoded_source,
        "source_text" => "Please answer.",
        "provider_context" => %{
          "connect_id" => "slack-1",
          "channel_id" => "C_REPLY",
          "thread_ts" => "1.0"
        },
        "ifc" => %{
          "label" => label,
          "integrity" => "command",
          "principal" => "provider_user|slack-1|U_REPLY"
        }
      }

      messages =
        [
          %{
            id: 1,
            role: "user",
            content: "Please answer.",
            source_message_id: @encoded_source,
            trusted_origin: origin
          }
        ] ++
          Enum.flat_map(1..@repair_rounds, fn n ->
            [
              %{
                id: 2 * n,
                role: "assistant",
                content: "",
                ifc_view_label: label,
                tool_calls: [
                  %{
                    id: "explore-#{n}",
                    name: "call",
                    args: %{
                      "tool" => "history.search",
                      "params" => %{"query" => "q#{n}"},
                      "ifc" => %{"sources" => []}
                    }
                  }
                ]
              },
              %{
                id: 2 * n + 1,
                role: "tool",
                tool_call_id: "explore-#{n}",
                ifc_view_label: label,
                ifc: %{"label" => label},
                content: ~s({"results":[]})
              }
            ]
          end)

      state = %SalixAgent.InternalSession.State{
        agent_id: agent,
        session_id: session_id,
        messages: messages,
        next_message_id: length(messages) + 1
      }

      :ok =
        SalixAgent.TestSupport.SessionFixture.seed(agent, SalixAgent.InternalSession.open(state))

      reply = fn id ->
        {:assistant, "",
         [
           %{
             id: id,
             name: "end_turn",
             args: %{
               "outcome" => "done",
               "reply" => %{
                 "tool" => "im_api.slack.reply_message",
                 "params" => %{
                   "connect_id" => "slack-1",
                   "channel_id" => "C_REPLY",
                   "thread_ts" => "1.0",
                   "text" => "Please provide more context."
                 },
                 "ifc" => %{"sources" => []}
               }
             }
           }
         ]}
      end

      Mock.script([reply.("wrong-fields"), reply.("repair-fields")])

      {:ok, _pid} = Fleet.ensure_started(agent, create: true)
      Server.wake(agent)
      assert eventually(fn -> settled?(agent) end, 3000)
      :ok = SalixAgent.TestSupport.await_session_quiet(agent, session_id)
      assert_received {:declaration_specs, first_specs}
      assert_received {:projection_messages, first_messages}
      assert_received {:declaration_specs, second_specs}
      assert_received {:projection_messages, second_messages}
      assert Enum.map(first_specs, & &1["name"]) == ["end_turn"]
      assert Enum.map(second_specs, & &1["name"]) == ["end_turn"]
      prefix = fn ms -> Enum.filter(ms, &(&1[:role] in ["system", "summary"])) end
      assert_received {:im_provider_call, ^agent, "slack", "slack.reply_message", sent}
      assert prefix.(first_messages) == prefix.(second_messages)
      assert sent["params"]["channel"] == "C_REPLY"
      refute Map.has_key?(sent["params"], "channel_id")
      refute Jason.encode!(second_specs) =~ "C_REPLY"
    end
  end

  test "enforce physically removes another domain before the model while preserving session history",
       %{agent: agent} do
    put_mode("enforce")
    SystemsRuntime.put_env(:salix_agent, :llm, DeclarationLLM)
    SystemsRuntime.PersistentTerm.put({DeclarationLLM, :owner}, SystemsRuntime.Proc.self())
    on_exit(fn -> SystemsRuntime.PersistentTerm.erase({DeclarationLLM, :owner}) end)

    state = %SalixAgent.InternalSession.State{
      agent_id: agent,
      session_id: @session_id,
      next_message_id: 2,
      last_ack_message_id: 1,
      messages: [
        %{
          id: 1,
          role: "user",
          content: "FOREIGN_SECRET_MEETING",
          source_message_id: "foreign-data",
          trusted_origin: %{
            "provider" => "internal",
            "source_actor_type" => "agent",
            "source_message_id" => "foreign-data",
            "ifc" => %{"integrity" => "data", "label" => ["scope|private|bob"]}
          }
        }
      ]
    }

    :ok =
      SalixAgent.TestSupport.SessionFixture.seed(agent, SalixAgent.InternalSession.open(state))

    :ok = deliver_source(agent, "user_chat", %{"source_message_id" => @encoded_source})
    script_reply("received")
    {:parked, _} = settle_quiet(agent)
    assert_received {:projection_messages, messages}
    wire = inspect(messages, limit: :infinity, printable_limit: :infinity)
    assert wire =~ "what did legal say?"
    refute wire =~ "FOREIGN_SECRET_MEETING"
    {:ok, session} = SalixAgent.InternalSessionStore.read(agent, @session_id)

    assert inspect(SalixAgent.InternalSession.get(session, :messages),
             limit: :infinity,
             printable_limit: :infinity
           ) =~ "FOREIGN_SECRET_MEETING"

    assistants =
      Enum.filter(SalixAgent.InternalSession.get(session, :messages), &(&1[:role] == "assistant"))

    assert assistants != []
    assert Enum.all?(assistants, &is_list(&1[:ifc_view_label]))
  end

  test "async projected rounds persist global refs and restore local refs on the next request",
       %{agent: agent} do
    put_mode("enforce")
    SystemsRuntime.put_env(:salix_agent, :llm, DeclarationLLM)
    SystemsRuntime.PersistentTerm.put({DeclarationLLM, :owner}, SystemsRuntime.Proc.self())
    on_exit(fn -> SystemsRuntime.PersistentTerm.erase({DeclarationLLM, :owner}) end)

    state = %SalixAgent.InternalSession.State{
      agent_id: agent,
      session_id: @session_id,
      next_message_id: 2,
      last_ack_message_id: 1,
      messages: [
        %{
          id: 1,
          role: "user",
          content: "FOREIGN_SECRET_MEETING",
          source_message_id: "foreign-data",
          trusted_origin: %{
            "provider" => "internal",
            "source_actor_type" => "agent",
            "source_message_id" => "foreign-data",
            "ifc" => %{"integrity" => "data", "label" => ["scope|private|bob"]}
          }
        }
      ]
    }

    :ok =
      SalixAgent.TestSupport.SessionFixture.seed(agent, SalixAgent.InternalSession.open(state))

    :ok = deliver_source(agent, "user_chat", %{"source_message_id" => @encoded_source})

    Mock.script([
      {:assistant, "",
       [
         %{
           id: "local-help",
           name: "call",
           args: %{
             "tool" => "help",
             "params" => %{"tool" => "ifc"},
             "ifc" => %{"request" => "src:q-1", "sources" => []}
           }
         }
       ]},
      {:assistant, "",
       [
         inspector_call("local-reply", "im_api.internal.send_message", %{
           "connect_id" => "internal",
           "conversation_id" => @conversation_id,
           "reply_to_message_id" => @source_message_id,
           "content" => [%{"type" => "text", "text" => "received"}]
         })
       ]},
      {:final, "done"}
    ])

    {:parked, _} = settle_quiet(agent)
    assert_received {:projection_messages, messages}
    wire = inspect(messages, limit: :infinity, printable_limit: :infinity)
    assert wire =~ "what did legal say?"
    refute wire =~ "FOREIGN_SECRET_MEETING"
    {:ok, session} = SalixAgent.InternalSessionStore.read(agent, @session_id)

    assert inspect(SalixAgent.InternalSession.get(session, :messages),
             limit: :infinity,
             printable_limit: :infinity
           ) =~ "FOREIGN_SECRET_MEETING"

    assistants =
      Enum.filter(SalixAgent.InternalSession.get(session, :messages), &(&1[:role] == "assistant"))

    assert assistants != []
    first = hd(assistants)
    assert hd(first.tool_calls)["args"]["ifc"]["request"] == "src:q-2"
    assert_received {:projection_messages, next_messages}
    next_assistant = Enum.find(next_messages, &(&1[:role] == "assistant"))
    assert hd(next_assistant.tool_calls)["args"]["ifc"]["request"] == "src:q-1"
    assert provider_calls(agent) != []

    refute inspect(next_messages, limit: :infinity, printable_limit: :infinity) =~
             "src:unavailable"

    assert inspect(next_messages, limit: :infinity, printable_limit: :infinity) =~ "src:q-1"
    assert Enum.all?(assistants, &is_list(&1[:ifc_view_label]))
  end

  test "visible round keeps withheld discovery feedback and can send a safe reply", %{
    agent: agent
  } do
    put_mode("enforce")
    SystemsRuntime.put_env(:salix_agent, :llm, DeclarationLLM)
    SystemsRuntime.PersistentTerm.put({DeclarationLLM, :owner}, SystemsRuntime.Proc.self())
    on_exit(fn -> SystemsRuntime.PersistentTerm.erase({DeclarationLLM, :owner}) end)
    :ok = deliver_source(agent)

    Mock.script([
      {:assistant, "",
       [
         %{
           id: "private-discovery",
           name: "call",
           args: %{
             "tool" => "im.provider_apis_list",
             "params" => %{"provider" => "internal", "connect_id" => "internal"},
             "ifc" => %{"sources" => []}
           }
         }
       ]},
      {:assistant, "",
       [
         %{
           id: "safe-reply",
           name: "call",
           args: %{
             "tool" => "im_api.internal.send_message",
             "params" => %{
               "connect_id" => "internal",
               "conversation_id" => @conversation_id,
               "content" => [%{"type" => "text", "text" => "I cannot provide that here."}]
             },
             "ifc" => %{"sources" => []}
           }
         }
       ]},
      {:final, "done"}
    ])

    {:parked, _} = settle_quiet(agent)
    assert_received {:projection_messages, _first}
    assert_received {:projection_messages, next}

    assert Enum.any?(next, fn message ->
             message[:role] == "tool" and
               String.contains?(message[:content] || "", "withheld_by_visibility")
           end)

    assert Enum.any?(provider_calls(agent), fn {_, api, _} -> api == "internal.send_message" end)
  end

  for {mode, route} <- [{"off", :call}, {"audit", :call}, {"enforce", :end_turn}] do
    @declaration_mode mode
    @declaration_route route
    @tag :required_declaration
    test "#{mode} #{route} declares sources at the model and dispatch boundaries" do
      put_mode(@declaration_mode)
      SystemsRuntime.put_env(:salix_agent, :llm, DeclarationLLM)
      SystemsRuntime.PersistentTerm.put({DeclarationLLM, :owner}, SystemsRuntime.Proc.self())
      on_exit(fn -> SystemsRuntime.PersistentTerm.erase({DeclarationLLM, :owner}) end)
      agent = SalixAgent.TestSupport.new_agent_id()
      record = SalixAgent.TestSupport.create_control_agent!(agent, %{"role" => "router"})
      {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(record)

      envelope = %{
        "tool" => "im_api.internal.send_message",
        "params" => %{
          "connect_id" => "internal",
          "conversation_id" => @conversation_id,
          "reply_to_message_id" => @source_message_id,
          "content" => [%{"type" => "text", "text" => "received"}]
        }
      }

      make_call = fn id, args ->
        case @declaration_route do
          :call -> %{id: id, name: "call", args: args}
          :end_turn -> %{id: id, name: "end_turn", args: %{"outcome" => "done", "reply" => args}}
        end
      end

      first = make_call.("missing-declaration", envelope)
      corrected = make_call.("explicit-empty", Map.put(envelope, "ifc", %{"sources" => []}))
      Mock.script([{:assistant, "", [first]}, {:assistant, "", [corrected]}, {:final, "done"}])
      {:ok, _pid} = Fleet.ensure_started(agent, create: true)

      {:ok, :created} =
        SalixAgent.deliver(
          agent,
          %{
            content: "Please confirm receipt.",
            session_id: session_id,
            trusted_origin: %{
              "provider" => "internal",
              "conversation_id" => @conversation_id,
              "conversation_kind" => "user_chat",
              "message_id" => @source_message_id,
              "source_message_id" => @encoded_source,
              "participant_id" => @participant_id,
              "source_actor_type" => "user",
              "agent_group_id" => record["group_id"],
              "ifc" => %{
                "label" => ["conversation|#{@conversation_id}"],
                "integrity" => "command",
                "principal" => @requester
              }
            }
          },
          source_message_id: @encoded_source
        )

      settle(agent)
      :ok = SalixAgent.TestSupport.await_session_quiet(agent, session_id)
      calls = provider_calls(agent)

      if @declaration_mode != "off" do
        assert length(calls) == 1
        {:ok, session} = SalixAgent.InternalSessionStore.read(agent, session_id)

        assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn m ->
                 is_binary(m[:content]) and String.contains?(m[:content], "Provide ifc.sources")
               end)
      else
        assert calls != []
      end

      assert_received {:declaration_specs, specs}
      call_schema = Enum.find(specs, &(&1["name"] == "call"))["input_schema"]

      reply_schema =
        Enum.find(specs, &(&1["name"] == "end_turn"))["input_schema"]["properties"]["reply"]

      for schema <- [call_schema, reply_schema] do
        valid = Map.put(envelope, "ifc", %{"sources" => []})
        assert :ok = SalixAgent.Tools.validate_schema(valid, schema)

        if @declaration_mode != "off" do
          assert {:error, _} = SalixAgent.Tools.validate_schema(envelope, schema)
        else
          assert :ok = SalixAgent.Tools.validate_schema(envelope, schema)
        end
      end
    end
  end
end
