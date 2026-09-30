defmodule SalixAgent.ExplicitTurnOutcomeTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{InternalSessionStore, LLM}
  alias SalixStore.S3

  @session_id "ses1_0000000000000000960"

  defmodule ScriptLLM do
    @moduledoc false
    @behaviour LLM
    @owner_key {__MODULE__, :owner}

    def set_owner(owner), do: :persistent_term.put(@owner_key, owner)
    def clear_owner, do: :persistent_term.erase(@owner_key)

    @impl true
    def complete(messages, tools), do: request(messages, tools)

    defp request(messages, tools) do
      send(
        :persistent_term.get(@owner_key),
        {:explicit_turn_llm_request, self(), messages, tools}
      )

      receive do
        {:explicit_turn_llm_response, response} -> response
      after
        5_000 -> raise "timed out waiting for an explicit-turn test response"
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")

    previous_store = Application.get_env(:salix_store, :s3_backend)
    previous_llm = Application.get_env(:salix_agent, :llm)
    previous_external_runtime = Application.get_env(:salix_agent, :external_runtime_driver)
    previous_idle_ms = Application.get_env(:salix_agent, :session_actor_idle_ms)
    previous_runaway_cap = Application.get_env(:salix_agent, :runaway_unsettled_round_cap)
    previous_round_cap = Application.get_env(:salix_agent, :input_round_cap)

    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    ScriptLLM.set_owner(self())
    Application.put_env(:salix_agent, :llm, ScriptLLM)
    Application.put_env(:salix_agent, :external_runtime_driver, SalixAgent.ExternalRuntime.None)
    Application.put_env(:salix_agent, :session_actor_idle_ms, 5_000)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      ScriptLLM.clear_owner()
      put_or_delete_env(:salix_store, :s3_backend, previous_store)
      put_or_delete_env(:salix_agent, :llm, previous_llm)
      put_or_delete_env(:salix_agent, :external_runtime_driver, previous_external_runtime)
      put_or_delete_env(:salix_agent, :session_actor_idle_ms, previous_idle_ms)
      put_or_delete_env(:salix_agent, :runaway_unsettled_round_cap, previous_runaway_cap)
      put_or_delete_env(:salix_agent, :input_round_cap, previous_round_cap)
    end)

    {:ok, agent_id: agent_id}
  end

  test "no-tool prose stays unacknowledged, then standalone end_turn settles", %{
    agent_id: agent_id
  } do
    deliver!(agent_id, "turn-outcome:no-tool", "investigate the runtime")

    respond!(no_tool("I will investigate the runtime next."))
    {llm_pid, messages, tools} = await_request!()

    request_text =
      Enum.map_join(messages, "\n", &to_string(&1[:content] || &1["content"] || ""))

    assert request_text =~ "Plain text does not end the turn"
    assert Enum.any?(tools, &(&1["name"] == "end_turn"))

    pending = read_session!(agent_id)

    assert %{content: "I will investigate the runtime next.", id: attempt_id} =
             List.last(SalixAgent.InternalSession.get(pending, :messages))

    assert SalixAgent.InternalSession.last_ack_message_id(pending) < attempt_id

    terminal_response = responses_end_turn("finish-after-reminder")

    send(llm_pid, {:explicit_turn_llm_response, terminal_response})

    settled = await_settled!(agent_id)

    refute Enum.any?(SalixAgent.InternalSession.get(settled, :events), fn event ->
             (event[:type] || event["type"]) in ["completion_decision", "turn_outcome"]
           end)

    terminal_meta = List.last(SalixAgent.InternalSession.get(settled, :messages)).provider_meta

    assert [
             %{"type" => "reasoning"},
             %{"type" => "function_call", "call_id" => "finish-after-reminder"},
             %{
               "type" => "function_call_output",
               "call_id" => "finish-after-reminder",
               "output" => output
             }
           ] = terminal_meta["responses_items"]

    assert Jason.decode!(output) == %{"outcome" => "done", "status" => "accepted"}

    refute Enum.any?(
             SalixAgent.InternalSession.get(settled, :messages),
             &(&1.role == "tool" and &1.tool_call_id == "finish-after-reminder")
           )

    deliver!(agent_id, "turn-outcome:follow-up", "handle the next request")

    {next_llm_pid, next_messages, _tools} = await_request!()
    replay_items = SalixLlm.ConvertOpenAI.to_responses(next_messages)

    assert call_index =
             Enum.find_index(replay_items, fn item ->
               item["type"] == "function_call" and item["call_id"] == "finish-after-reminder"
             end)

    assert %{"type" => "function_call_output", "call_id" => "finish-after-reminder"} =
             Enum.at(replay_items, call_index + 1)

    assert Enum.count(replay_items, fn item ->
             item["type"] == "function_call_output" and
               item["call_id"] == "finish-after-reminder"
           end) == 1

    send(next_llm_pid, {:explicit_turn_llm_response, end_turn("finish-follow-up")})
    await_settled!(agent_id)
  end

  test "a guarded bot notification releases queued requests in order without another wake", %{
    agent_id: agent_id
  } do
    Application.put_env(:salix_agent, :runaway_unsettled_round_cap, 3)
    deliver_source!(agent_id, "bot-notice", "background notice", "provider_system")
    {first_pid, _, _} = await_request!()

    deliver_source!(agent_id, "next-human", "FIRST_QUEUED_REQUEST", "provider_user")
    deliver_source!(agent_id, "later-human", "SECOND_QUEUED_REQUEST", "provider_user")
    send(first_pid, {:explicit_turn_llm_response, no_tool("<end_turn outcome=\"done\" />")})
    respond!(no_tool("<end_turn outcome=\"done\" />"))
    respond!(no_tool("<end_turn outcome=\"done\" />"))

    # Observe an actual provider request, not a log, wake receipt or queue count.
    {next_pid, messages, _} = await_request!()
    text = inspect(messages, limit: :infinity)
    assert text =~ "FIRST_QUEUED_REQUEST"
    refute text =~ "SECOND_QUEUED_REQUEST"
    refute_receive {:explicit_turn_llm_request, _, _, _}, 100
    send(next_pid, {:explicit_turn_llm_response, end_turn("finish-first-queued")})

    {later_pid, messages, _} = await_request!()
    assert inspect(messages, limit: :infinity) =~ "SECOND_QUEUED_REQUEST"
    send(later_pid, {:explicit_turn_llm_response, end_turn("finish-second-queued")})
    await_settled!(agent_id)
  end

  for recovery <- [:operator, :sweep, :record_only, :foreign_sweep, :cancelled_prefetch] do
    test "#{recovery} recovers a stored guard and processes the first queued input", %{
      agent_id: agent_id
    } do
      Application.put_env(:salix_agent, :runaway_unsettled_round_cap, 3)
      seed_guarded_queue!(agent_id, unquote(recovery) == :foreign_sweep)

      case unquote(recovery) do
        recovery when recovery in [:operator, :cancelled_prefetch] ->
          if recovery == :cancelled_prefetch do
            # A failed speculative fence cancels its provider process, but the
            # fixture notification it already sent remains in this mailbox.
            owner = self()

            {cancelled, ref} =
              spawn_monitor(fn ->
                send(owner, {:explicit_turn_llm_request, self(), [], []})

                receive do
                  :never -> :ok
                end
              end)

            assert_receive {:explicit_turn_llm_request, ^cancelled, [], []}
            Process.exit(cancelled, :kill)
            assert_receive {:DOWN, ^ref, :process, ^cancelled, :killed}
            send(self(), {:explicit_turn_llm_request, cancelled, [], []})
          end

          assert {:ok, %{"sessions" => [result]}} =
                   SalixAgent.force_recover(agent_id, session_id: @session_id)

          assert result["recovery"]["state"] == "command_recorded"
          refute result["recovery"]["processing_observed"]

        sweep when sweep in [:sweep, :foreign_sweep] ->
          SalixAgent.SessionWorkRecovery.sweep()

        :record_only ->
          assert {:ok, %{"sessions" => [result]}} =
                   SalixAgent.force_recover(agent_id, session_id: @session_id, wake: false)

          assert result["recovery"]["state"] == "command_recorded"
          SalixAgent.SessionWorkRecovery.sweep()
      end

      {first_pid, messages, _, started} = await_recovery_request!(agent_id)
      assert SalixAgent.InternalSession.last_ack_message_id(started) == 2

      if unquote(recovery) == :foreign_sweep do
        assert Enum.any?(SalixAgent.InternalSession.get(started, :events), fn event ->
                 event["kind"] == "runtime_runaway_retired" and
                   event["event"]["outcome"] == "blocked"
               end)
      end

      text = inspect(messages, limit: :infinity)
      assert text =~ "FIRST_QUEUED_REQUEST"
      refute text =~ "SECOND_QUEUED_REQUEST"
      refute text =~ "force-recovered by an operator"
      refute_receive {:explicit_turn_llm_request, _, _, _}, 100
      send(first_pid, {:explicit_turn_llm_response, end_turn("recover-first")})

      {second_pid, messages, _} = await_request!()
      assert inspect(messages, limit: :infinity) =~ "SECOND_QUEUED_REQUEST"
      send(second_pid, {:explicit_turn_llm_response, end_turn("recover-second")})

      observed =
        if unquote(recovery) == :foreign_sweep do
          # Both queued requests have actually entered the provider above.
          # The foreign call can still contribute recovery work; this test
          # does not require that independent lifecycle to be finished.
          read_session!(agent_id)
        else
          await_settled!(agent_id)
        end

      assert Enum.any?(
               SalixAgent.InternalSession.get(observed, :events),
               &(&1["kind"] == "runtime_runaway_retired")
             )
    end
  end

  test "two no-tool rounds fail the current turn and admit a queued request", %{
    agent_id: agent_id
  } do
    Application.delete_env(:salix_agent, :runaway_unsettled_round_cap)
    deliver!(agent_id, "turn-outcome:runaway", "do not spin forever")
    respond!(no_tool("loop one"))
    {llm_pid, _messages, _tools} = await_request!()
    deliver!(agent_id, "turn-outcome:queued", "process this after the failed turn")
    send(llm_pid, {:explicit_turn_llm_response, no_tool("loop two")})

    {next_pid, messages, _tools} = await_request!()
    assert inspect(messages) =~ "process this after the failed turn"
    state = read_session!(agent_id)

    assert Enum.any?(SalixAgent.InternalSession.get(state, :events), fn event ->
             event["kind"] == "runtime_runaway_retired" and
               event["event"]["outcome"] == "blocked" and
               event["event"]["consecutive_unsettled_rounds"] == 2
           end)

    send(next_pid, {:explicit_turn_llm_response, end_turn("finish-queued")})
    await_settled!(agent_id)
    refute_receive {:explicit_turn_llm_request, _pid, _messages, _tools}, 200
  end

  test "the round budget releases input whose every round calls a tool", %{agent_id: agent_id} do
    Application.put_env(:salix_agent, :input_round_cap, 3)

    deliver!(agent_id, "turn-outcome:budget", "keep looking until something changes")

    respond!(business_tool("budget-1"))
    respond!(business_tool("budget-2"))
    respond!(business_tool("budget-3"))

    # The already accepted tool's completion is still work after the failed
    # activation is released. It must reach the model rather than be dropped.
    respond!(end_turn("finish-accepted-tool-result"))
    parked = await_settled!(agent_id)

    assert SalixAgent.InternalSession.rounds_since_fresh_input(parked) == 0
    assert SalixAgent.InternalSession.consecutive_unsettled_rounds(parked) == 0
    refute SalixAgent.InternalSession.has_unprocessed_stable_work?(parked)
    refute_receive {:explicit_turn_llm_request, _pid, _messages, _tools}, 200

    deliver!(agent_id, "turn-outcome:budget-fresh", "new input resumes the parked session")
    respond!(end_turn("budget-finish"))
    settled = await_settled!(agent_id)
    assert SalixAgent.InternalSession.rounds_since_fresh_input(settled) == 0
  end

  test "tool rounds persist keyless guard facts and reset the counter", %{agent_id: agent_id} do
    Application.put_env(:salix_agent, :runaway_unsettled_round_cap, 3)
    deliver!(agent_id, "turn-outcome:counter-only", "make progress without copying source ids")

    respond!(no_tool("first reflection"))
    respond!(no_tool("second reflection"))
    respond!(business_tool("counter-progress"))
    {llm_pid, _messages, _tools} = await_request!()

    progressed = read_session!(agent_id)
    assert SalixAgent.InternalSession.consecutive_unsettled_rounds(progressed) == 0

    assert SalixAgent.InternalSession.get(progressed, :runaway_unsettled_streak) == %{
             "count" => 0
           }

    guard_facts =
      Enum.filter(
        SalixAgent.InternalSession.get(progressed, :events),
        &(&1["kind"] in ["runaway_guard_reset", "runaway_unsettled_round"])
      )

    assert length(guard_facts) == 3
    assert Enum.any?(guard_facts, &(&1["kind"] == "runaway_guard_reset"))

    for fact <- guard_facts do
      refute Map.has_key?(fact["event"], "activation_key")
      refute Map.has_key?(fact["event"], "source_message_ids")
    end

    send(llm_pid, {:explicit_turn_llm_response, no_tool("third reflection")})
    respond!(no_tool("fourth reflection"))
    respond!(no_tool("fifth reflection"))
    parked = await_settled!(agent_id)
    assert SalixAgent.InternalSession.consecutive_unsettled_rounds(parked) == 0

    deliver!(agent_id, "turn-outcome:counter-fresh", "new input resumes the parked session")
    respond!(end_turn("counter-finish"))
    settled = await_settled!(agent_id)
    assert SalixAgent.InternalSession.consecutive_unsettled_rounds(settled) == 0
  end

  test "end_turn during repair is replayed as not settled", %{agent_id: agent_id} do
    deliver!(agent_id, "turn-outcome:repair", "recover without leaking private guidance")

    respond!(
      {:assistant, "malformed envelope",
       [%{id: "missing-tool", name: "call", args: %{"params" => %{}}}]}
    )

    projection_wake!(agent_id)
    respond!(responses_end_turn("finish-during-repair"))
    {llm_pid, messages, _tools} = await_request!()
    session = read_session!(agent_id)

    assert SalixAgent.InternalSession.visible_reply_repair_required?(session)

    assert SalixAgent.InternalSession.last_ack_message_id(session) <
             List.last(SalixAgent.InternalSession.get(session, :messages)).id

    refute Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.role == "tool" and &1.tool_call_id == "finish-during-repair")
           )

    replay_items = SalixLlm.ConvertOpenAI.to_responses(messages)

    assert call_index =
             Enum.find_index(replay_items, fn item ->
               item["type"] == "function_call" and item["call_id"] == "finish-during-repair"
             end)

    assert %{
             "type" => "function_call_output",
             "call_id" => "finish-during-repair",
             "output" => output
           } =
             Enum.at(replay_items, call_index + 1)

    assert Jason.decode!(output) == %{
             "reason" => "repair_required",
             "status" => "not_settled"
           }

    assert Enum.count(replay_items, fn item ->
             item["type"] == "function_call_output" and
               item["call_id"] == "finish-during-repair"
           end) == 1

    send(llm_pid, {:explicit_turn_llm_response, end_turn("finish-repair-cleanup")})
    await_settled!(agent_id)
  end

  test "repair requests explain recovery and allow direct wait_for", %{
    agent_id: agent_id
  } do
    deliver!(agent_id, "turn-outcome:repair-wait", "recover without exposing private guidance")

    respond!(
      {:assistant, "malformed envelope",
       [%{id: "missing-tool-before-wait", name: "call", args: %{"params" => %{}}}]}
    )

    projection_wake!(agent_id)
    {repair_llm_pid, repair_messages, _tools} = await_request!()
    assert_repair_contract!(repair_messages)

    send(
      repair_llm_pid,
      {:explicit_turn_llm_response,
       {:assistant, "",
        [
          %{
            id: "wait-during-repair",
            name: "wait_for",
            args: %{"reason" => "waiting for the repair", "timeout_seconds" => 60}
          }
        ]}}
    )

    session = await_wait_record!(agent_id)
    refute SalixAgent.InternalSession.visible_reply_repair_required?(session)

    assert %{status: "completed", content: output, diagnostic_visibility: "none"} =
             Enum.find(
               SalixAgent.InternalSession.get(session, :messages),
               &(&1[:tool_call_id] == "wait-during-repair")
             )

    assert Jason.decode!(output)["status"] == "waiting"
    refute output =~ "guidance_reason"
    refute_receive {:explicit_turn_llm_request, _pid, _messages, _tools}, 100
  end

  test "an old session uses current configured instructions during repair",
       %{
         agent_id: agent_id
       } do
    old_prompt = "Call business tools through the single outer LLM tool named call."
    current_instructions = "Current repair instructions."

    {:ok, _agent} =
      SalixAgent.Control.configure(agent_id, %{"system_prompt" => current_instructions})

    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent_id, @session_id, [
        %{"type" => "session_created", "session_id" => @session_id},
        %{
          "type" => "session_system_prompt",
          "session_id" => @session_id,
          "system_prompt" => old_prompt
        }
      ])

    deliver!(agent_id, "turn-outcome:repair-legacy", "recover on an old prompt")

    respond!(
      {:assistant, "malformed envelope",
       [%{id: "missing-tool-legacy", name: "call", args: %{"params" => %{}}}]}
    )

    projection_wake!(agent_id)
    {repair_llm_pid, repair_messages, _tools} = await_request!()
    current_prompt = hd(repair_messages).content
    assert current_prompt =~ current_instructions
    assert_repair_contract!(repair_messages)

    assert SalixAgent.InternalSession.get(read_session!(agent_id), :system_prompt) ==
             current_prompt

    send(repair_llm_pid, {:explicit_turn_llm_response, end_turn("finish-legacy-during-repair")})
    {cleanup_llm_pid, _messages, _tools} = await_request!()
    send(cleanup_llm_pid, {:explicit_turn_llm_response, end_turn("finish-legacy-repair-cleanup")})
    await_settled!(agent_id)
  end

  test "effective tool progress permits many rounds below the consecutive empty-round cap", %{
    agent_id: agent_id
  } do
    responses =
      Enum.flat_map(1..10, fn n ->
        # Alternate real results so this exercises runaway reset, not the
        # separate five-identical-results guard.
        tool = if rem(n, 2) == 0, do: "fs.read_file", else: "env.exec"
        [no_tool("reflection #{n}"), business_tool("help-progress-#{n}", tool)]
      end) ++ [end_turn("finish-long-happy-path")]

    deliver!(agent_id, "turn-outcome:long-happy-path", "keep making progress until done")

    Enum.each(responses, &respond!/1)

    settled = await_settled!(agent_id)

    assert Enum.any?(
             SalixAgent.InternalSession.get(settled, :messages),
             &(&1.role == "tool" and &1.tool_call_id == "help-progress-10")
           )

    refute_receive {:explicit_turn_llm_request, _, _, _}, 100
  end

  test "non-settling reflections retire the current input without another model call", %{
    agent_id: agent_id
  } do
    deliver!(agent_id, "turn-outcome:non-settling", "finish this request")
    respond!(no_tool("reflection one"))
    respond!(no_tool("reflection two"))
    settled = await_settled!(agent_id)

    assert Enum.any?(
             SalixAgent.InternalSession.get(settled, :events),
             &(&1["kind"] == "runtime_runaway_retired")
           )

    refute_receive {:explicit_turn_llm_request, _, _, _}, 100
  end

  defp no_tool(content), do: {:assistant, content, []}

  defp business_tool(id, tool \\ "fs.read_file") do
    {:assistant, "working",
     [%{id: id, name: "call", args: %{"tool" => "help", "params" => %{"tool" => tool}}}]}
  end

  defp end_turn(id),
    do: {:assistant, "", [%{id: id, name: "end_turn", args: %{"outcome" => "done"}}]}

  defp responses_end_turn(id) do
    end_turn(id)
    |> with_provider_meta(%{
      "response_id" => "response-#{id}",
      "responses_items" => [
        %{"type" => "reasoning", "id" => "reasoning-#{id}"},
        %{
          "type" => "function_call",
          "call_id" => id,
          "name" => "end_turn",
          "arguments" => ~s({"outcome":"done"})
        }
      ]
    })
  end

  defp with_provider_meta({:assistant, content, calls}, provider_meta),
    do: {:assistant, content, calls, provider_meta}

  # The repair rule no longer rides at the request tail as a full reminder:
  # the request ends with one short `turn:` line carrying `repair=on`, and the
  # rule text lives in the stored prompt's "Turn reminders" catalog.
  defp assert_repair_contract!(messages) do
    marker =
      Enum.find(messages, fn message ->
        content = to_string(message[:content] || message["content"] || "")

        (message[:role] || message["role"]) in [:summary, "summary"] and
          String.starts_with?(content, "turn: ")
      end)

    assert marker
    assert marker.content =~ "repair=on"
    refute marker.content =~ "decide=on"
    assert byte_size(marker.content) < 120

    # Only the stored prompt (the request head) carries the rule text now.
    refute Enum.any?(tl(messages), fn message ->
             content = to_string(message[:content] || message["content"] || "")
             String.contains?(content, "A private tool diagnostic requires repair")
           end)

    catalog = SalixAgent.InternalSession.request_projection({:turn_reminder_catalog})
    assert catalog =~ "- repair=on: A private tool diagnostic requires repair"
    assert catalog =~ "calls execute normally and return their real results or receipts"
    assert catalog =~ "A successful terminal tool result completes repair"
    assert catalog =~ "Plain text, blank output, and end_turn cannot settle it"
    refute catalog =~ "'tool' is required"
  end

  # After a failed round (e.g. a malformed LLM envelope classified for
  # repair), the next activation is owned by the session work projection —
  # the rpc path's deferred-wake fallback. salix_cluster is disabled in
  # tests, so drive that one wake explicitly, the way the recovery sweep
  # would. (The staged-era Server absorb loop used to chain this round as a
  # side effect; that path retired in A2 §3.2 step 4.)
  defp projection_wake!(agent_id) do
    {:ok, pid} = SalixAgent.Placement.ensure_started(agent_id, create: true)
    SalixAgent.Server.wake(pid)
  end

  defp await_request! do
    assert_receive {:explicit_turn_llm_request, pid, messages, tools}, 2_000
    {pid, messages, tools}
  end

  # A provider notification can precede its activation CAS. Joining the owner
  # observes that fence: a rejected speculative call has been cancelled and
  # cannot consume a response. Ignore only dead calls, never another live
  # provider request; the recovery test still forbids a second live request
  # until it answers the first and checks the exact queued-input ordering.
  defp await_recovery_request!(agent_id, attempts \\ 10)

  defp await_recovery_request!(_agent_id, 0),
    do: flunk("recovery never retained a provider request")

  defp await_recovery_request!(agent_id, attempts) do
    {pid, messages, tools} = await_request!()
    session = read_session!(agent_id)

    if Process.alive?(pid) do
      {pid, messages, tools, session}
    else
      await_recovery_request!(agent_id, attempts - 1)
    end
  end

  defp respond!(response) do
    {pid, _messages, _tools} = await_request!()
    send(pid, {:explicit_turn_llm_response, response})
  end

  defp deliver!(agent_id, source_message_id, content) do
    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: content,
                 session_id: @session_id,
                 role: "user",
                 created_at: System.system_time(:second)
               },
               source_message_id: source_message_id
             )
  end

  defp deliver_source!(agent_id, source, content, actor) do
    origin = %{
      "provider" => "slack",
      "source_actor_type" => actor,
      "source_message_id" => source,
      "provider_context" => %{
        "connect_id" => "fixture-slack",
        "channel_id" => "fixture-channel",
        "thread_ts" => source
      }
    }

    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: content,
                 session_id: @session_id,
                 role: "user",
                 trusted_origin: origin,
                 created_at: System.system_time(:second)
               },
               source_message_id: source
             )
  end

  defp seed_guarded_queue!(agent_id, foreign?) do
    events =
      [
        %{"type" => "session_created", "session_id" => @session_id},
        %{
          "type" => "delivery",
          "session_id" => @session_id,
          "message_id" => 1,
          "from_queue" => true,
          "source_message_id" => "stopped-bot",
          "role" => "user",
          "content" => "old bot notice"
        },
        %{
          "type" => "assistant",
          "session_id" => @session_id,
          "message_id" => 2,
          "content" => "<end_turn />",
          "tool_calls" => []
        }
      ] ++
        List.duplicate(
          %{
            "type" => "session_event",
            "session_id" => @session_id,
            "kind" => "runaway_unsettled_round",
            "event" => %{}
          },
          3
        ) ++
        Enum.map([{1, "FIRST_QUEUED_REQUEST"}, {2, "SECOND_QUEUED_REQUEST"}], fn {id, content} ->
          source = "queued-#{id}"

          %{
            "type" => "queue_append",
            "session_id" => @session_id,
            "kind" => "user_message",
            "queue_id" => id,
            "wake" => true,
            "dedupe_key" => source,
            "payload" => %{
              "source_message_id" => source,
              "role" => "user",
              "content" => content,
              "trusted_origin" => %{
                "provider" => "slack",
                "source_actor_type" => "provider_user",
                "source_message_id" => source,
                "provider_context" => %{
                  "connect_id" => "fixture-slack",
                  "channel_id" => "fixture-channel",
                  "thread_ts" => source
                }
              }
            }
          }
        end)

    events =
      if foreign? do
        foreign = %{
          "type" => "async_tool_call_started",
          "tool_call_id" => "foreign-work",
          "tool_name" => "env.exec",
          "status" => "running",
          "trusted_origin" => %{"source_message_id" => "foreign"},
          "trusted_origin_source_message_ids" => ["foreign"]
        }

        Enum.map(events, fn event ->
          if event["type"] == "delivery" do
            Map.put(event, "trusted_origin", %{
              "provider" => "telegram",
              "source_actor_type" => "provider_user",
              "source_message_id" => "stopped-bot",
              "provider_context" => %{"connect_id" => "fixture", "chat_id" => "42"}
            })
          else
            event
          end
        end) ++ [foreign]
      else
        events
      end

    assert {:ok, _session} = InternalSessionStore.prepare_commit(agent_id, @session_id, events)
  end

  # A provider request can be observed before the owner's fence lands; join
  # the owner so the read sees the settled transcript.
  defp read_session!(agent_id) do
    :ok = SalixAgent.TestSupport.join_session_owner(agent_id, @session_id)
    {:ok, session} = InternalSessionStore.read(agent_id, @session_id)
    session
  end

  defp await_settled!(agent_id, attempts \\ 500)

  defp await_settled!(_agent_id, 0), do: flunk("session did not settle")

  defp await_settled!(agent_id, attempts) do
    session = read_session!(agent_id)

    if SalixAgent.InternalSession.last_ack_message_id(session) ==
         List.last(SalixAgent.InternalSession.get(session, :messages)).id do
      session
    else
      Process.sleep(10)
      await_settled!(agent_id, attempts - 1)
    end
  end

  defp await_wait_record!(agent_id, attempts \\ 200)

  defp await_wait_record!(_agent_id, 0), do: flunk("session did not persist wait_for")

  defp await_wait_record!(agent_id, attempts) do
    session = read_session!(agent_id)

    if get_in(SalixAgent.InternalSession.wait(session) || %{}, ["source"]) == "wait_for" do
      session
    else
      Process.sleep(10)
      await_wait_record!(agent_id, attempts - 1)
    end
  end

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)
end
