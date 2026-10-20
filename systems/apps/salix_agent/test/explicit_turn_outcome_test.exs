defmodule SalixAgent.ExplicitTurnOutcomeTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  alias SalixAgent.{InternalSessionStore, LLM}
  alias SalixStore.S3

  @session_id "ses1_0000000000000000960"

  defmodule ScriptLLM do
    @moduledoc false
    @behaviour LLM
    @owner_key {__MODULE__, :owner}

    def set_owner(owner), do: SystemsRuntime.PersistentTerm.put(@owner_key, owner)
    def clear_owner, do: SystemsRuntime.PersistentTerm.erase(@owner_key)

    @impl true
    def complete(messages, tools), do: request(messages, tools)

    defp request(messages, tools) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get(@owner_key),
        {:explicit_turn_llm_request, SystemsRuntime.Proc.self(), messages, tools}
      )

      SystemsRuntime.Proc.receive do
        {:explicit_turn_llm_response, response} -> response
      after
        5_000 -> raise "timed out waiting for an explicit-turn test response"
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")

    previous_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    previous_idle_ms = SystemsRuntime.get_env(:salix_agent, :session_actor_idle_ms)
    previous_runaway_cap = SystemsRuntime.get_env(:salix_agent, :runaway_unsettled_round_cap)
    previous_round_cap = SystemsRuntime.get_env(:salix_agent, :input_round_cap)

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    if SystemsRuntime.Proc.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    ScriptLLM.set_owner(SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_agent, :llm, ScriptLLM)
    SystemsRuntime.put_env(:salix_agent, :session_actor_idle_ms, 5_000)

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      ScriptLLM.clear_owner()
      put_or_delete_env(:salix_store, :s3_backend, previous_store)
      put_or_delete_env(:salix_agent, :llm, previous_llm)
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

    SystemsRuntime.Proc.send(llm_pid, {:explicit_turn_llm_response, terminal_response})

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

    SystemsRuntime.Proc.send(
      next_llm_pid,
      {:explicit_turn_llm_response, end_turn("finish-follow-up")}
    )

    await_settled!(agent_id)
  end

  for recovery <- [:operator, :sweep, :record_only, :foreign_sweep, :cancelled_prefetch] do
    test "#{recovery} recovers a stored guard and processes the first queued input", %{
      agent_id: agent_id
    } do
      SystemsRuntime.put_env(:salix_agent, :runaway_unsettled_round_cap, 3)
      seed_guarded_queue!(agent_id, unquote(recovery) == :foreign_sweep)

      case unquote(recovery) do
        recovery when recovery in [:operator, :cancelled_prefetch] ->
          if recovery == :cancelled_prefetch do
            # A failed speculative fence cancels its provider process, but the
            # fixture notification it already sent remains in this mailbox.
            owner = SystemsRuntime.Proc.self()

            {cancelled, ref} =
              spawn_monitor(fn ->
                SystemsRuntime.Proc.send(
                  owner,
                  {:explicit_turn_llm_request, SystemsRuntime.Proc.self(), [], []}
                )

                SystemsRuntime.Proc.receive do
                  :never -> :ok
                end
              end)

            assert_receive {:explicit_turn_llm_request, ^cancelled, [], []}
            SystemsRuntime.Proc.exit(cancelled, :kill)
            assert_receive {:DOWN, ^ref, :process, ^cancelled, :killed}

            SystemsRuntime.Proc.send(
              SystemsRuntime.Proc.self(),
              {:explicit_turn_llm_request, cancelled, [], []}
            )
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

      SystemsRuntime.Proc.send(
        first_pid,
        {:explicit_turn_llm_response, end_turn("recover-first")}
      )

      {second_pid, messages, _} = await_request!()
      assert inspect(messages, limit: :infinity) =~ "SECOND_QUEUED_REQUEST"

      SystemsRuntime.Proc.send(
        second_pid,
        {:explicit_turn_llm_response, end_turn("recover-second")}
      )

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
    SystemsRuntime.delete_env(:salix_agent, :runaway_unsettled_round_cap)
    deliver!(agent_id, "turn-outcome:runaway", "do not spin forever")
    respond!(no_tool("loop one"))
    {llm_pid, _messages, _tools} = await_request!()
    deliver!(agent_id, "turn-outcome:queued", "process this after the failed turn")
    SystemsRuntime.Proc.send(llm_pid, {:explicit_turn_llm_response, no_tool("loop two")})

    {next_pid, messages, _tools} = await_request!()
    assert inspect(messages) =~ "process this after the failed turn"
    state = read_session!(agent_id)

    assert Enum.any?(SalixAgent.InternalSession.get(state, :events), fn event ->
             event["kind"] == "runtime_runaway_retired" and
               event["event"]["outcome"] == "blocked" and
               event["event"]["consecutive_unsettled_rounds"] == 2
           end)

    SystemsRuntime.Proc.send(next_pid, {:explicit_turn_llm_response, end_turn("finish-queued")})
    await_settled!(agent_id)
    refute_receive {:explicit_turn_llm_request, _pid, _messages, _tools}, 200
  end

  test "the round budget releases input whose every round calls a tool", %{agent_id: agent_id} do
    SystemsRuntime.put_env(:salix_agent, :input_round_cap, 3)

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

    SystemsRuntime.Proc.send(
      repair_llm_pid,
      {:explicit_turn_llm_response, end_turn("finish-legacy-during-repair")}
    )

    {cleanup_llm_pid, _messages, _tools} = await_request!()

    SystemsRuntime.Proc.send(
      cleanup_llm_pid,
      {:explicit_turn_llm_response, end_turn("finish-legacy-repair-cleanup")}
    )

    await_settled!(agent_id)
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

  # The failed call's result opened repair. The request shows it to the model
  # as a private diagnostic.
  defp assert_repair_contract!(messages) do
    assert Enum.any?(messages, fn message ->
             content = to_string(message[:content] || message["content"] || "")

             (message[:role] || message["role"]) in [:tool, "tool"] and
               String.starts_with?(content, "[private diagnostic]\n")
           end)
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
    assert_receive {:explicit_turn_llm_request, pid, messages, tools}
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

    if SystemsRuntime.Proc.alive?(pid) do
      {pid, messages, tools, session}
    else
      await_recovery_request!(agent_id, attempts - 1)
    end
  end

  defp respond!(response) do
    {pid, _messages, _tools} = await_request!()
    SystemsRuntime.Proc.send(pid, {:explicit_turn_llm_response, response})
  end

  defp deliver!(agent_id, source_message_id, content) do
    assert {:ok, :created} =
             SalixAgent.deliver(
               agent_id,
               %{
                 content: content,
                 session_id: @session_id,
                 role: "user",
                 created_at: SystemsClock.system_time(:second)
               },
               source_message_id: source_message_id
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

  defp await_settled!(agent_id, attempts \\ 3000)

  defp await_settled!(_agent_id, 0), do: flunk("session did not settle")

  defp await_settled!(agent_id, attempts) do
    session = read_session!(agent_id)

    if SalixAgent.InternalSession.last_ack_message_id(session) ==
         List.last(SalixAgent.InternalSession.get(session, :messages)).id do
      session
    else
      SystemsRuntime.Proc.sleep(10)
      await_settled!(agent_id, attempts - 1)
    end
  end

  defp put_or_delete_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
