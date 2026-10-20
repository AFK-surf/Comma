defmodule SalixAgent.RoundActivityTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Fine-grained activity signals fan out via `SalixAgent.Notifier` as
  `{:activity, map}` while a round runs (see `SalixAgent.ActivityEvent`), so the
  agent-activities stream can surface live thinking / tool-execution / idle state
  in the gap between the user's message and the committed reply.

  This proves the emission points around `SalixAgent.Round`: a "thinking"
  activity at round start, a "messaging" activity at an authorized Participant
  draft or explicit reply execution, an "execution" activity per
  non-reply tool call, and an "idle" activity when the turn settles. Rich
  action/summary emission remains a side channel; the coarse phase is also
  committed as the session's durable `activity_status`.
  """
  # Each test runs in its own SystemsSim world, from the same store: the
  # database's baseline, an empty S3 fake, a new id allocator and an empty
  # plugin catalog cache. The node has read what it reads once and keeps
  # (its built-in skills, the station roster's cutover marker) before each
  # world, so no test reads them in some test orders and not in others. No
  # Loop runs: the loops host starts no spinfoam process, whose replies would
  # come at real times. The control plane's triage receipt recovery, which
  # lists the fake's receipts on its own schedule, stops.
  use SystemsSim.Case,
    reset: [
      &SalixStore.RepoTestSetup.reset!/0,
      &SalixAgent.BuiltinSkills.snapshot/0,
      &Comma.Stations.Window.open?/0
    ],
    host: [
      {SalixStore.Supervisor, SalixStore.S3.Fake},
      {SalixStore.Supervisor, SalixStore.Ids},
      {SalixWeb.Supervisor, Salix.Control.PluginCatalogCache}
    ],
    apps: [:salix_agent],
    env: [salix_agent: [spinfoam_cmd: :disabled]],
    timeout: 120_000,
    max_steps: 20_000

  require SystemsClock

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{Server, Fleet, SessionToolDispatch}
  alias SalixAgent.LLM.Mock

  @pid_key {__MODULE__, :test_pid}
  @block_phase_key {__MODULE__, :block_phase}

  defmodule InspectingMock do
    @moduledoc false
    @behaviour SalixAgent.LLM

    @impl true
    def complete(messages, tools), do: Mock.complete(messages, tools)

    @impl true
    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    @impl true
    def complete_stream(messages, tools, on_delta, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({SalixAgent.RoundActivityTest, :test_pid}),
        {
          :reply_request,
          messages,
          tools
        }
      )

      {:assistant, text, calls} = Mock.complete_stream(messages, tools, on_delta, opts)

      calls =
        Enum.map(calls, fn call ->
          Map.update!(call, :args, fn
            args when is_binary(args) -> Jason.decode!(args)
            args -> args
          end)
        end)

      {:assistant, text, calls}
    end
  end

  defmodule TestNotifier do
    @moduledoc false
    @behaviour SalixAgent.Notifier

    @impl true
    def notify(agent_id, event) do
      case SystemsRuntime.PersistentTerm.get({SalixAgent.RoundActivityTest, :test_pid}, nil) do
        nil ->
          :ok

        pid ->
          SystemsRuntime.Proc.send(pid, {:notified, agent_id, event})

          with {:session_activity_updated, session_id} <- event,
               %{} = draft <- SalixAgent.DraftSurface.get(agent_id, session_id) do
            SystemsRuntime.Proc.send(pid, {:participant_draft, agent_id, draft})
          end
      end

      block? =
        case SystemsRuntime.PersistentTerm.get({SalixAgent.RoundActivityTest, :block_phase}, nil) do
          {blocked_phase, gate} when is_binary(blocked_phase) ->
            matching_event? =
              match?({:activity, %{"phase" => ^blocked_phase}}, event) or
                participant_draft_notification?(blocked_phase, agent_id, event)

            matching_event? and SystemsRuntime.Atomics.exchange(gate, 1, 1) == 0

          _missing ->
            false
        end

      if block? do
        SystemsRuntime.Proc.send(
          SystemsRuntime.PersistentTerm.get({SalixAgent.RoundActivityTest, :test_pid}),
          {
            :activity_blocked,
            SystemsRuntime.Proc.self()
          }
        )

        SystemsRuntime.Proc.receive do
          :release_activity -> :ok
        end
      end

      :ok
    end

    defp participant_draft_notification?(
           "participant_draft",
           agent_id,
           {:session_activity_updated, session_id}
         ) do
      is_map(SalixAgent.DraftSurface.get(agent_id, session_id))
    end

    defp participant_draft_notification?(_blocked_phase, _agent_id, _event), do: false
  end

  defmodule TestVisibleReply do
    @moduledoc false
    @behaviour SalixAgent.VisibleReply

    @impl true
    def authorize(_agent_id, _scope), do: :ok
  end

  defmodule TestIMProvider do
    @moduledoc false
    @behaviour SalixAgent.Tools.ImRouter

    @owner_key {__MODULE__, :owner}

    def set_owner(owner), do: SystemsRuntime.PersistentTerm.put(@owner_key, owner)
    def clear, do: SystemsRuntime.PersistentTerm.erase(@owner_key)

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"connect_id" => "internal", "provider" => "internal"}]}

    @impl true
    def provider_manual("internal") do
      {:ok,
       %{
         "provider" => "internal",
         "apis" => [
           %{
             "name" => "internal.send_message",
             "safety" => "write",
             "description" => "Send an internal conversation message.",
             "parameters" => %{
               "conversation_id" => "Conversation id.",
               "content" => "Message content."
             },
             "required_params" => ["conversation_id", "content"]
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(agent_id, provider, api, args) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get(@owner_key),
        {:im_provider_call, agent_id, provider, api, args}
      )

      {:ok, %{"ok" => true}}
    end
  end

  defmodule BlockingIMProvider do
    @moduledoc false
    @behaviour SalixAgent.Tools.ImRouter

    @owner_key {__MODULE__, :owner}

    def set_owner(owner), do: SystemsRuntime.PersistentTerm.put(@owner_key, owner)
    def clear, do: SystemsRuntime.PersistentTerm.erase(@owner_key)

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"connect_id" => "internal", "provider" => "internal"}]}

    @impl true
    def provider_manual(provider), do: TestIMProvider.provider_manual(provider)

    @impl true
    def call_api(agent_id, provider, api, args) do
      SystemsRuntime.Proc.send(SystemsRuntime.PersistentTerm.get(@owner_key), {
        :blocked_im_provider_call,
        SystemsRuntime.Proc.self(),
        agent_id,
        provider,
        api,
        args
      })

      SystemsRuntime.Proc.receive do
        :complete_im_provider_call -> {:ok, %{"ok" => true}}
        :fail_im_provider_call -> {:error, :test_provider_failure}
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_notifier = SystemsRuntime.get_env(:salix_agent, :notifier)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)
    SystemsRuntime.put_env(:salix_agent, :notifier, TestNotifier)
    SystemsRuntime.PersistentTerm.put(@pid_key, SystemsRuntime.Proc.self())

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.PersistentTerm.erase(@pid_key)
      SystemsRuntime.PersistentTerm.erase(@block_phase_key)
      restore(:salix_store, :s3_backend, prev_s3)
      restore(:salix_agent, :notifier, prev_notifier)
      restore(:salix_agent, :llm, prev_llm)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)
    {:ok, agent: agent}
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, val), do: SystemsRuntime.put_env(app, key, val)

  defp block_next_notification(phase) do
    gate = SystemsRuntime.Atomics.new(1, [])
    SystemsRuntime.PersistentTerm.put(@block_phase_key, {phase, gate})
  end

  defp wake_and_settle(agent) do
    Server.wake(agent)
    result = Server.info(agent)
    assert eventually(fn -> internal_sessions_settled?(agent) end, 3000)
    result
  end

  defp internal_sessions_settled?(agent) do
    case SalixAgent.InternalSessionStore.list(agent) do
      {:ok, sessions} ->
        Enum.all?(
          sessions,
          &(SalixAgent.InternalSession.derived_state(&1) not in [:queued, :active])
        )

      {:error, _} ->
        false
    end
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  # Collect the activity notifications for `agent` in mailbox (emission) order.
  defp collect_activities(agent) do
    SystemsClock.vreceive do
      {:notified, ^agent, {:activity, activity}} -> [activity | collect_activities(agent)]
      {:notified, ^agent, _other} -> collect_activities(agent)
    after
      50 -> []
    end
  end

  defp collect_activities_until(agent, phase, retries \\ 200, acc \\ []) do
    activities = acc ++ collect_activities(agent)

    cond do
      Enum.any?(activities, &(&1["phase"] == phase)) ->
        activities

      retries == 0 ->
        activities

      true ->
        SystemsClock.sleep(10)
        collect_activities_until(agent, phase, retries - 1, activities)
    end
  end

  test "Session assistant transcript stays private and never becomes a Participant draft", %{
    agent: a
  } do
    previous_visible_reply = SystemsRuntime.get_env(:salix_agent, :visible_reply_mod)
    SystemsRuntime.put_env(:salix_agent, :visible_reply_mod, TestVisibleReply)

    on_exit(fn ->
      restore(:salix_agent, :visible_reply_mod, previous_visible_reply)
    end)

    session_id = "ses1_0000000000000000914"
    conversation_id = "conv-session-transcript-only"
    source_message_id = "msg1_0000000000000000914"
    participant_id = "par1_0000000000000000914"
    group_id = "grp1_0000000000000000914"
    encoded_source = "groupconv:#{conversation_id}:#{source_message_id}:#{participant_id}"
    transcript = "This assistant text belongs only to the Session transcript"

    Mock.script([{:final, transcript}])
    {:ok, _pid} = Fleet.ensure_started(a, create: true)

    {:ok, :created} =
      deliver(a, encoded_source, %{
        content: "hi",
        session_id: session_id,
        trusted_origin: %{
          "provider" => "internal",
          "conversation_id" => conversation_id,
          "conversation_kind" => "user_chat",
          "message_id" => source_message_id,
          "participant_id" => participant_id,
          "source_actor_type" => "user",
          "agent_group_id" => group_id
        }
      })

    {:parked, _owned} = wake_and_settle(a)

    assert SalixAgent.DraftSurface.get(a, session_id) == nil

    assert {:ok, session} = SalixAgent.InternalSessionStore.read(a, session_id)

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.role == "assistant" and &1.content == transcript)
           )

    activities = collect_activities_until(a, "idle")
    refute Enum.any?(activities, &(&1["phase"] == "messaging"))
  end

  test "a source-bound reply streams before provider completion and sends exactly once", %{
    agent: a
  } do
    SystemsRuntime.put_env(:salix_agent, :llm, InspectingMock)
    previous_im_provider = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    previous_visible_reply = SystemsRuntime.get_env(:salix_agent, :visible_reply_mod)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, TestIMProvider)
    SystemsRuntime.put_env(:salix_agent, :visible_reply_mod, TestVisibleReply)
    TestIMProvider.set_owner(SystemsRuntime.Proc.self())

    on_exit(fn ->
      TestIMProvider.clear()
      restore(:salix_agent, :im_provider_mod, previous_im_provider)
      restore(:salix_agent, :visible_reply_mod, previous_visible_reply)
    end)

    session_id = "ses1_0000000000000000902"
    conversation_id = "conv-visible-activity"
    source_message_id = "msg1_0000000000000000902"
    participant_id = "par1_0000000000000000902"
    group_id = "grp1_0000000000000000902"
    old_prompt = "Call business tools through the single outer LLM tool named call."
    current_instructions = "Current reply instructions."

    {:ok, _agent} =
      SalixAgent.Control.configure(a, %{"system_prompt" => current_instructions})

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(a, session_id, [
        %{"type" => "session_created", "session_id" => session_id},
        %{
          "type" => "session_system_prompt",
          "session_id" => session_id,
          "system_prompt" => old_prompt
        }
      ])

    encoded_source =
      "groupconv:#{conversation_id}:#{source_message_id}:#{participant_id}"

    visible_text = String.duplicate("hello back, streamed in several chunks. ", 8)
    session_transcript = "I am preparing the actual Conversation reply"

    Mock.script([
      {:assistant, session_transcript,
       [
         %{
           id: "validated-send-draft",
           name: "call",
           args:
             ~s({"tool":"im_api.internal.send_message","params":{"connect_id":"internal","conversation_id":#{Jason.encode!(conversation_id)},"reply_to_message_id":#{Jason.encode!(source_message_id)},"content":[{"type":"text","text":#{Jason.encode!(visible_text)}}]}})
         }
       ]},
      {:final, "done"}
    ])

    {:ok, _pid} = Fleet.ensure_started(a, create: true)
    # Delivery starts the round, so the gate is set before it.
    block_next_notification("participant_draft")

    {:ok, :created} =
      deliver(a, encoded_source, %{
        content: "hi",
        session_id: session_id,
        trusted_origin: %{
          "provider" => "internal",
          "conversation_id" => conversation_id,
          "conversation_kind" => "user_chat",
          "message_id" => source_message_id,
          "participant_id" => participant_id,
          "source_actor_type" => "user",
          "agent_group_id" => group_id
        }
      })

    Server.wake(a)
    settle_receive({:activity_blocked, activity_pid})
    settle_receive({:reply_request, request_messages, request_tools})
    current_prompt = hd(request_messages).content
    assert current_prompt =~ current_instructions
    refute Enum.any?(request_tools, &(&1["name"] == "reply"))

    response_identity =
      try do
        assert %{
                 "conversation_id" => ^conversation_id,
                 "participant_id" => ^participant_id,
                 "response_key" => response_identity,
                 "revision" => revision,
                 "status" => "streaming",
                 "source_message_ids" => [^encoded_source],
                 "text" => text
               } = SalixAgent.DraftSurface.get(a, session_id)

        assert revision > 0
        assert text != ""
        assert text != visible_text
        assert String.starts_with?(visible_text, text)
        refute String.contains?(text, session_transcript)
        assert SalixAgent.VisibleReplyScope.valid_response_identity?(response_identity)
        response_identity
      after
        SystemsRuntime.PersistentTerm.erase(@block_phase_key)
        SystemsRuntime.Proc.send(activity_pid, :release_activity)
      end

    result = Server.info(a)
    settle_receive({:im_provider_call, ^a, "internal", "internal.send_message", _args})
    assert eventually(fn -> internal_sessions_settled?(a) end, 3000)
    assert eventually(fn -> SalixAgent.DraftSurface.get(a, session_id) == nil end, 3000)
    settle_receive({:reply_request, _continuation_messages, _tools})
    assert {:parked, _owned} = result
    assert SalixAgent.DraftSurface.get(a, session_id) == nil
    settle_refute_receive({:im_provider_call, ^a, "internal", "internal.send_message", _}, 50)
    assert {:ok, stored_session} = SalixAgent.InternalSessionStore.read(a, session_id)

    assert SalixAgent.InternalSession.get(stored_session, :system_prompt) ==
             current_prompt

    activities = collect_activities_until(a, "idle")

    scoped_frames =
      Enum.filter(activities, &(&1["conversation_id"] == conversation_id))

    messaging = Enum.filter(scoped_frames, &(&1["phase"] == "messaging"))
    v2_frames = Enum.filter(scoped_frames, &Map.has_key?(&1, "response_key"))

    assert [activity] = messaging
    assert activity["action"] == "Typing"
    assert activity["summary"] == "Typing"
    refute Map.has_key?(activity, "tool_name")
    assert phase_index(activities, "thinking") < phase_index(activities, "messaging")
    assert phase_index(activities, "messaging") < phase_index(activities, "idle")

    assert Enum.map(v2_frames, & &1["phase"]) == ["thinking", "messaging", "idle"]
    assert Enum.all?(v2_frames, &(&1["response_key"] == response_identity))
    assert Enum.all?(v2_frames, &(&1["source_message_ids"] == [encoded_source]))
    assert Enum.all?(v2_frames, &(&1["agent_group_id"] == group_id))
    assert Enum.all?(v2_frames, &(&1["conversation_id"] == conversation_id))
    assert Enum.all?(v2_frames, &(&1["participant_id"] == participant_id))

    assert v2_frames
           |> Enum.map(& &1["sequence"])
           |> then(fn sequences -> sequences == Enum.sort(sequences) end)
  end

  test "one terminal response shows its validated Comma reply until source settlement", %{
    agent: _agent
  } do
    previous_im_provider = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    previous_visible_reply = SystemsRuntime.get_env(:salix_agent, :visible_reply_mod)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, BlockingIMProvider)
    SystemsRuntime.put_env(:salix_agent, :visible_reply_mod, TestVisibleReply)
    SystemsRuntime.put_env(:salix_agent, :llm, InspectingMock)
    BlockingIMProvider.set_owner(SystemsRuntime.Proc.self())

    on_exit(fn ->
      BlockingIMProvider.clear()
      restore(:salix_agent, :im_provider_mod, previous_im_provider)
      restore(:salix_agent, :visible_reply_mod, previous_visible_reply)
    end)

    a = SalixAgent.TestSupport.new_agent_id()
    agent_record = SalixAgent.TestSupport.create_control_agent!(a, %{"role" => "router"})
    {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(agent_record)
    conversation_id = "conv-terminal-reply"
    source_message_id = "msg1_0000000000000000914"
    participant_id = "par1_0000000000000000914"
    group_id = "grp1_0000000000000000914"
    encoded_source = "groupconv:#{conversation_id}:#{source_message_id}:#{participant_id}"
    visible_text = String.duplicate("最终回复应该持续显示。", 20)

    Mock.script([
      {:assistant, "",
       [
         %{
           id: "terminal-comma-reply",
           name: "end_turn",
           args:
             ~s({"outcome":"done","reply":{"tool":"im_api.internal.send_message","ifc":{"sources":[]},"params":{"connect_id":"internal","conversation_id":#{Jason.encode!(conversation_id)},"content":[{"type":"text","text":#{Jason.encode!(visible_text)}}]}}})
         }
       ]}
    ])

    {:ok, _pid} = Fleet.ensure_started(a, create: true)
    block_next_notification("participant_draft")

    {:ok, :created} =
      deliver(a, encoded_source, %{
        content: "请给我一段完整回复",
        session_id: session_id,
        trusted_origin: %{
          "provider" => "internal",
          "conversation_id" => conversation_id,
          "conversation_kind" => "user_chat",
          "message_id" => source_message_id,
          "source_message_id" => encoded_source,
          "participant_id" => participant_id,
          "source_actor_type" => "user",
          "agent_group_id" => group_id
        }
      })

    settle_receive({:activity_blocked, activity_pid})

    try do
      assert %{"status" => "streaming", "text" => text} =
               SalixAgent.DraftSurface.get(a, session_id)

      assert text == visible_text

      settle_refute_receive(
        {:blocked_im_provider_call, _, ^a, "internal", "internal.send_message", _},
        50
      )
    after
      SystemsRuntime.PersistentTerm.erase(@block_phase_key)
      SystemsRuntime.Proc.send(activity_pid, :release_activity)
    end

    settle_receive(
      {:blocked_im_provider_call, provider_pid, ^a, "internal", "internal.send_message", args}
    )

    try do
      assert args["params"]["content"] == [%{"type" => "text", "text" => visible_text}]

      assert %{"status" => "streaming", "text" => ^visible_text} =
               SalixAgent.DraftSurface.get(a, session_id)
    after
      SystemsRuntime.Proc.send(provider_pid, :complete_im_provider_call)
    end

    assert eventually(fn -> internal_sessions_settled?(a) end, 3000)
    assert eventually(fn -> SalixAgent.DraftSurface.get(a, session_id) == nil end, 3000)
    assert {:ok, session} = SalixAgent.InternalSessionStore.read(a, session_id)

    assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             message.role == "assistant" and
               Enum.any?(message.tool_calls || [], fn call ->
                 call["id"] == "terminal-comma-reply" and
                   call["name"] == "end_turn" and
                   get_in(call, ["args", "reply", "ifc"]) == %{"sources" => []}
               end)
           end)

    settle_receive({:reply_request, _, _})
    settle_refute_receive({:reply_request, _, _}, 100)

    settle_refute_receive(
      {:blocked_im_provider_call, _, ^a, "internal", "internal.send_message", _},
      100
    )

    # The source is already settled; a short window catches any late thinking.
    activities = collect_activities_until(a, "idle", 20)
    messaging_index = phase_index(activities, "messaging")
    assert phase_index(activities, "thinking") < messaging_index
    refute Enum.any?(Enum.drop(activities, messaging_index + 1), &(&1["phase"] == "thinking"))

    Mock.script([{:final, "No further reply requested"}])

    {:ok, :created} =
      deliver(a, "groupconv:#{conversation_id}:msg1_0000000000000000915:#{participant_id}", %{
        content: "Do not send another reply. Was the previous send completed?",
        session_id: session_id,
        trusted_origin: %{
          "provider" => "internal",
          "conversation_id" => conversation_id,
          "conversation_kind" => "user_chat",
          "message_id" => "msg1_0000000000000000915",
          "source_message_id" =>
            "groupconv:#{conversation_id}:msg1_0000000000000000915:#{participant_id}",
          "participant_id" => participant_id,
          "source_actor_type" => "user",
          "agent_group_id" => group_id
        }
      })

    settle_receive({:reply_request, next_messages, _})
    assert eventually(fn -> internal_sessions_settled?(a) end, 3000)

    assert Enum.any?(next_messages, fn message ->
             Enum.any?(message[:tool_calls] || [], fn call ->
               call["id"] == "terminal-comma-reply" and call["name"] == "end_turn"
             end)
           end)

    # The placeholder stays as committed; the completion follows it.
    index = Enum.find_index(next_messages, &(&1[:tool_call_id] == "terminal-comma-reply"))
    assert %{"status" => "running"} = Jason.decode!(Enum.at(next_messages, index).content)

    assert Enum.any?(Enum.drop(next_messages, index + 1), fn message ->
             message[:role] == "runtime" and
               message[:source_tool_call_id] == "terminal-comma-reply"
           end)

    settle_refute_receive(
      {:blocked_im_provider_call, _, ^a, "internal", "internal.send_message", _},
      100
    )
  end

  for filter_position <- [:before_text, :after_text] do
    @filter_position filter_position
    test "a terminal reply filtered #{@filter_position} never appears in the source draft" do
      previous_visible_reply = SystemsRuntime.get_env(:salix_agent, :visible_reply_mod)
      SystemsRuntime.put_env(:salix_agent, :visible_reply_mod, TestVisibleReply)
      SystemsRuntime.put_env(:salix_agent, :llm, InspectingMock)
      on_exit(fn -> restore(:salix_agent, :visible_reply_mod, previous_visible_reply) end)

      a = SalixAgent.TestSupport.new_agent_id()
      agent = SalixAgent.TestSupport.create_control_agent!(a, %{"role" => "router"})
      {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(agent)
      conversation_id = "conv-filtered-reply"
      participant_id = "par1_0000000000000000915"
      source_message_id = "msg1_0000000000000000915"
      encoded_source = "groupconv:#{conversation_id}:#{source_message_id}:#{participant_id}"
      content = ~s("content":[{"type":"text","text":"must-not-draft"}])
      filter = ~s("delivery_filter":{"participant_ids":[]})

      fields =
        if @filter_position == :before_text,
          do: filter <> "," <> content,
          else: content <> "," <> filter

      Mock.script([
        {:assistant, "",
         [
           %{
             id: "filtered-terminal-reply",
             name: "end_turn",
             args:
               ~s({"outcome":"done","reply":{"tool":"im_api.internal.send_message","params":{"connect_id":"internal","conversation_id":#{Jason.encode!(conversation_id)},#{fields}}}})
           }
         ]},
        {:assistant, "",
         [
           %{
             id: "stop",
             name: "end_turn",
             args: %{"outcome" => "blocked", "reason" => "Cannot send to the excluded source"}
           }
         ]}
      ])

      {:ok, _pid} = Fleet.ensure_started(a, create: true)

      {:ok, :created} =
        deliver(a, encoded_source, %{
          content: "send a private result",
          session_id: session_id,
          trusted_origin: %{
            "provider" => "internal",
            "conversation_id" => conversation_id,
            "conversation_kind" => "user_chat",
            "message_id" => source_message_id,
            "source_message_id" => encoded_source,
            "participant_id" => participant_id,
            "source_actor_type" => "user",
            "agent_group_id" => "grp1_0000000000000000915"
          }
        })

      settle_receive({:reply_request, _, _})
      settle_receive({:reply_request, _, _})
      settle_refute_receive({:participant_draft, ^a, _draft})
    end
  end

  test "a tool round emits a running execution activity for the tool", %{agent: a} do
    Mock.script([
      {:assistant, "let me use tools",
       [
         %{
           id: "t1",
           name: "call",
           args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
         }
       ]},
      {:final, "all done now"}
    ])

    {:ok, _pid} = Fleet.ensure_started(a, create: true)
    block_next_notification("execution")

    {:ok, :created} =
      deliver(a, "u1", %{content: "do work", session_id: "ses1_0000000000000000901"})

    Server.wake(a)
    settle_receive({:activity_blocked, activity_pid})

    try do
      assert {:ok, session} =
               SalixAgent.InternalSessionStore.read(a, "ses1_0000000000000000901")

      # Admission commits the running record, its auto-wait and the round
      # boundary in one fence before the tool is dispatched, so the durable
      # session already waits on the tool while its execution activity runs.
      assert SalixAgent.InternalSession.status(session) == :idle
      assert %{"source" => "auto_wait"} = SalixAgent.InternalSession.wait(session)

      assert SalixAgent.InternalSession.get(session, :async_tool_calls)["t1"]["status"] ==
               "running"

      # The durable projection reports that wait; the running execution
      # frame itself is the transient Activity asserted below.
      assert SalixAgent.InternalSession.activity_status(session) == :waiting

      assert {:ok, control_agent} = SalixAgent.Control.get(a)

      # The agent activity list projects that durable wait as execution.
      assert [activity] = SalixAgent.Activity.list_agent(control_agent)
      assert activity["phase"] == "execution"
      assert activity["status"] == "waiting"
    after
      SystemsRuntime.PersistentTerm.erase(@block_phase_key)
      SystemsRuntime.Proc.send(activity_pid, :release_activity)
    end

    result = Server.info(a)
    assert eventually(fn -> internal_sessions_settled?(a) end, 3000)
    assert {:parked, _owned} = result

    activities = collect_activities_until(a, "idle")
    phases = Enum.map(activities, & &1["phase"])

    assert "thinking" in phases
    assert "execution" in phases
    assert "idle" in phases

    execution = Enum.find(activities, &(&1["phase"] == "execution"))
    assert execution["tool_name"] == "help"
    assert execution["tool_call_id"] == "t1"
    assert execution["status"] == "running"
    assert execution["display_priority"] == "work"

    # thinking precedes execution precedes the terminal idle.
    assert phase_index(activities, "thinking") < phase_index(activities, "execution")
    assert List.last(activities)["phase"] == "idle"
  end

  defp phase_index(activities, phase) do
    Enum.find_index(activities, &(&1["phase"] == phase))
  end

  test "private streamed reasoning never enters an activity payload", %{agent: a} do
    previous_visible_reply = SystemsRuntime.get_env(:salix_agent, :visible_reply_mod)
    SystemsRuntime.put_env(:salix_agent, :visible_reply_mod, TestVisibleReply)

    on_exit(fn ->
      restore(:salix_agent, :visible_reply_mod, previous_visible_reply)
    end)

    private_canary = "PRIVATE_REASONING_CANARY_54bcf7"
    session_id = "ses1_0000000000000000921"
    conversation_id = "conv-private-reasoning-v2"
    source_message_id = "msg1_0000000000000000921"
    participant_id = "par1_0000000000000000921"
    group_id = "grp1_0000000000000000921"
    encoded_source = "groupconv:#{conversation_id}:#{source_message_id}:#{participant_id}"

    Mock.script([{:reasoning, private_canary, {:final, "hi there"}}])
    {:ok, _pid} = Fleet.ensure_started(a, create: true)

    {:ok, :created} =
      deliver(a, encoded_source, %{
        content: "hi",
        session_id: session_id,
        trusted_origin: %{
          "provider" => "internal",
          "conversation_id" => conversation_id,
          "conversation_kind" => "user_chat",
          "message_id" => source_message_id,
          "participant_id" => participant_id,
          "source_actor_type" => "user",
          "agent_group_id" => group_id
        }
      })

    {:parked, _owned} = wake_and_settle(a)

    activities = collect_activities_until(a, "idle")

    assert Enum.any?(activities, fn activity ->
             activity["phase"] == "thinking" and activity["summary"] == "Thinking"
           end)

    assert Enum.all?(activities, &(&1["source_message_ids"] == [encoded_source]))
    assert Enum.all?(activities, &is_binary(&1["response_key"]))

    refute Enum.any?(activities, &(inspect(&1) =~ private_canary))
  end

  # The staged Delivery engine is retired (docs/salix/conversation-owner-actor.md
  # §3.4): fixtures commit through the public rpc ingress instead. A wakeable
  # delivery now runs its round at deliver time (the rpc itself is the wake);
  # the explicit wake/settle each test already performs awaits the outcome.
  defp deliver(agent, source_id, payload, opts \\ []) do
    SalixAgent.deliver(agent, payload, Keyword.put(opts, :source_message_id, source_id))
  end
end
