defmodule SalixAgent.LLMFailureStreakTest do
  @moduledoc """
  Regression for the wake-driven LLM retry loop (staging 2026-07-14): a round
  that fails with a permanent provider error leaves the transcript ending in
  tool results, so `needs_transcript_continuation?` re-armed the session on
  every wake and the same malformed request was replayed forever (124
  `llm_failed` terminals from ~4 user messages; `Control.cancel/1` slowed but
  never stopped it). The activation circuit breaker counts consecutive
  `llm_call_failed` events at one transcript position and parks the session at
  the cap; new session input advances the position and resumes normally.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{InternalSessionActor, InternalSessionFleet, InternalSessionStore}
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State

  @session_id "ses1_0000000000000000950"

  defmodule PermanentErrorLLM do
    @moduledoc "Always fails like an Anthropic 400 and counts the calls."
    @behaviour SalixAgent.LLM
    use Elixir.Agent

    def start_link(_), do: Elixir.Agent.start_link(fn -> 0 end, name: __MODULE__)
    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
    def calls, do: Elixir.Agent.get(__MODULE__, & &1)

    @impl true
    def complete(_messages, _tools), do: fail()

    @impl true
    def complete_stream(_messages, _tools, _on_delta), do: fail()

    defp fail do
      Elixir.Agent.update(__MODULE__, &(&1 + 1))
      SalixAgent.LLM.Error.http("anthropic", 400, ~s({"error":{"message":"invalid request"}}))
    end
  end

  defmodule CrashingLLM do
    @moduledoc """
    Kills the LLM task outright (uncatchable, so the in-round retry wrapper
    never sees it) — the actor observes a bare :DOWN and the session driver
    records the lost call, which does not ack stable input.
    """
    @behaviour SalixAgent.LLM
    use Elixir.Agent

    def start_link(_), do: Elixir.Agent.start_link(fn -> 0 end, name: __MODULE__)
    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
    def calls, do: Elixir.Agent.get(__MODULE__, & &1)

    @impl true
    def complete(_messages, _tools), do: crash()

    @impl true
    def complete_stream(_messages, _tools, _on_delta), do: crash()

    defp crash do
      Elixir.Agent.update(__MODULE__, &(&1 + 1))
      Process.exit(self(), :kill)
    end
  end

  defmodule RecoveringLLM do
    @behaviour SalixAgent.LLM
    use Elixir.Agent
    def start_link(_), do: Elixir.Agent.start_link(fn -> {0, false} end, name: __MODULE__)
    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
    def recover, do: Elixir.Agent.update(__MODULE__, fn {n, _} -> {n, true} end)
    def calls, do: Elixir.Agent.get(__MODULE__, &elem(&1, 0))
    @impl true
    def complete(messages, _tools), do: respond(messages)
    @impl true
    def complete_stream(messages, _tools, _on_delta), do: respond(messages)

    defp respond(messages) do
      if Enum.any?(messages, &(Map.get(&1, :content) == "async retry incident")) do
        healthy =
          Elixir.Agent.get_and_update(__MODULE__, fn {n, healthy} ->
            {healthy, {n + 1, healthy}}
          end)

        if healthy do
          {:assistant, "", [%{id: "retry_done", name: "end_turn", args: %{"outcome" => "done"}}],
           %{
             "responses_items" => [
               %{
                 "type" => "function_call",
                 "call_id" => "retry_done",
                 "name" => "end_turn",
                 "arguments" => ~s({"outcome":"done"})
               }
             ]
           }}
        else
          SalixAgent.LLM.Error.transport("openai_responses", %RuntimeError{message: "worker_down"})
        end
      else
        {:final, "auxiliary result"}
      end
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(PermanentErrorLLM)
    Application.put_env(:salix_agent, :llm, PermanentErrorLLM)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_backend)

      if prev_llm,
        do: Application.put_env(:salix_agent, :llm, prev_llm),
        else: Application.delete_env(:salix_agent, :llm)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(agent)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

    SalixAgent.TestSupport.create_control_agent!(agent, %{
      tenant_id: tenant_id,
      group_id: group_id,
      role: "worker"
    })

    # Incident transcript shape: a delivered user message, an assistant
    # tool-use turn, and the (failed) tool result at the tail.
    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent, @session_id, [
        %{"type" => "session_created", "session_id" => @session_id},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => @session_id,
          "message_id" => 1,
          "content" => "inspect the workspace"
        },
        %{
          "type" => "assistant",
          "session_id" => @session_id,
          "message_id" => 2,
          "content" => "",
          "tool_calls" => [%{"id" => "tc_1", "name" => "call", "args" => %{"tool" => "fs.list"}}]
        },
        %{
          "type" => "tool_result",
          "session_id" => @session_id,
          "message_id" => 3,
          "tool_call_id" => "tc_1",
          "content" => "error: workspace not provisioned"
        },
        %{"type" => "ack", "session_id" => @session_id, "last_ack_message_id" => 1}
      ])

    {:ok, agent: agent}
  end

  @tag timeout: 60_000
  test "provider recovery completes the original async-result turn without another message", %{
    agent: agent
  } do
    start_supervised!(RecoveringLLM)
    Application.put_env(:salix_agent, :llm, RecoveringLLM)
    previous = Application.get_env(:salix_agent, :llm_activation_retry_base_ms)
    Application.put_env(:salix_agent, :llm_activation_retry_base_ms, 2_000)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :llm_activation_retry_base_ms, previous),
        else: Application.delete_env(:salix_agent, :llm_activation_retry_base_ms)
    end)

    # Use the real queue materialization, model-call loop and session store.
    # Only the provider outage is injected. No retry-specific state is seeded.
    {:ok, _} =
      InternalSessionStore.prepare_commit(agent, @session_id, [
        %{
          "type" => "queue_append",
          "session_id" => @session_id,
          "kind" => "runtime_message",
          "dedupe_key" => "incident-async-result",
          "payload" => %{
            "content" => "async retry incident",
            "kind" => "tool_call_completed",
            "runtime_message_id" => "incident-async-result"
          }
        }
      ])

    {:ok, pid} = InternalSessionFleet.ensure_started(agent, @session_id)
    assert eventually(fn -> failure_count(agent, @session_id) == 1 end, 400)
    before_recovery = read_session!(agent)
    assert List.last(InternalSession.get(before_recovery, :messages)).role == "runtime"
    assert RecoveringLLM.calls() == 6

    RecoveringLLM.recover()
    :ok = GenServer.stop(pid, :normal)
    {:ok, _} = InternalSessionFleet.ensure_started(agent, @session_id)

    completed? =
      eventually(
        fn ->
          Enum.any?(InternalSession.get(read_session!(agent), :messages), fn message ->
            Enum.any?(get_in(message, [:provider_meta, "responses_items"]) || [], fn item ->
              item["type"] == "function_call_output" and item["call_id"] == "retry_done" and
                Jason.decode!(item["output"]) == %{"status" => "accepted", "outcome" => "done"}
            end)
          end)
        end,
        100
      )

    assert completed?,
           "provider is healthy but original turn did not finish; model calls=#{RecoveringLLM.calls()}"

    assert RecoveringLLM.calls() == 7
    assert failure_count(agent, @session_id) == 1
  end

  @tag timeout: 60_000
  test "async result failure survives actor restart and resumes without new input", %{
    agent: agent
  } do
    start_supervised!(RecoveringLLM)
    Application.put_env(:salix_agent, :llm, RecoveringLLM)
    previous = Application.get_env(:salix_agent, :llm_activation_retry_base_ms)
    Application.put_env(:salix_agent, :llm_activation_retry_base_ms, 2_000)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :llm_activation_retry_base_ms, previous),
        else: Application.delete_env(:salix_agent, :llm_activation_retry_base_ms)
    end)

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent, @session_id, [
        %{
          "type" => "runtime_message",
          "from_queue" => true,
          "session_id" => @session_id,
          "message_id" => 4,
          "runtime_message_id" => "async-result-retry",
          "kind" => "tool_call_completed",
          "content" => "async retry incident"
        }
      ])

    {:ok, pid} = InternalSessionFleet.ensure_started(agent, @session_id)
    assert eventually(fn -> failure_count(agent, @session_id) == 1 end, 400)
    failed = read_session!(agent)
    assert List.last(InternalSession.get(failed, :messages)).role == "runtime"
    # A retryable failure keeps its source unacknowledged for the retry.
    assert InternalSession.last_ack_message_id(failed) < 4
    assert InternalSession.work_reasons(failed) == ["llm_retry"]
    assert InternalSession.get(failed, :activity_status) == :waiting
    assert InternalSession.activity_status(failed) == :waiting
    assert InternalSession.monitored_activity_signature(failed) == :active
    assert is_integer(InternalSession.llm_retry_at_ms(failed))
    assert is_binary(InternalSession.work_index_token(failed))
    assert SalixAgent.SessionWorkIndex.discoverable_reasons?(["llm_retry"])
    refute SalixAgent.SessionWorkIndex.immediate_recovery_reasons?(["llm_retry"])

    assert SalixAgent.SessionWorkIndex.recover_after_ms(
             ["llm_retry"],
             InternalSession.recovery_wait(failed)
           ) == InternalSession.llm_retry_at_ms(failed)

    due = InternalSession.llm_retry_at_ms(failed)
    {:ok, before_due} = SalixAgent.SessionWorkIndex.list_due_discovery(due - 1)

    refute Enum.any?(
             before_due.records,
             &(&1["token"] == InternalSession.work_index_token(failed))
           )

    {:ok, at_due} = SalixAgent.SessionWorkIndex.list_due_discovery(due)
    assert Enum.any?(at_due.records, &(&1["token"] == InternalSession.work_index_token(failed)))

    # The worker is available again, but no new user/runtime message arrives.
    # Only the durable retry deadline can restart this exact transcript.
    :ok = GenServer.stop(pid, :normal)
    RecoveringLLM.recover()
    {:ok, _pid} = InternalSessionFleet.ensure_started(agent, @session_id)
    Process.sleep(100)
    assert RecoveringLLM.calls() == 6
    assert eventually(fn -> InternalSession.next_message_id(read_session!(agent)) > 5 end, 200)
    assert eventually(fn -> InternalSession.work_reasons(read_session!(agent)) == [] end)
    assert failure_count(agent, @session_id) == 1
    assert RecoveringLLM.calls() == 7
    assert is_nil(InternalSession.llm_retry_at_ms(read_session!(agent)))
  end

  @tag timeout: 60_000
  test "durable retries exhaust at the same transcript and new input restores progress", %{
    agent: agent
  } do
    start_supervised!(RecoveringLLM)
    Application.put_env(:salix_agent, :llm, RecoveringLLM)

    failures =
      for _ <- 1..2 do
        terminal_failure(true)
        |> put_in(["event", "retry_at_ms"], System.system_time(:millisecond) - 1)
        |> put_in(["event", "transcript_hwm"], 4)
      end

    {:ok, seeded} =
      InternalSessionStore.prepare_commit(agent, @session_id, [
        %{
          "type" => "runtime_message",
          "from_queue" => true,
          "session_id" => @session_id,
          "message_id" => 4,
          "runtime_message_id" => "bounded-async-result",
          "kind" => "tool_call_completed",
          "content" => "async retry incident"
        },
        %{"type" => "ack", "session_id" => @session_id, "last_ack_message_id" => 4}
        | failures
      ])

    assert is_integer(InternalSession.llm_retry_at_ms(seeded))
    # Hot-state recovery cannot depend on retaining the historical event list.
    if InternalSession.storage_format(seeded) >= 2 do
      assert InternalSession.llm_retry_at_ms(
               InternalSession.open(%{InternalSession.export(seeded) | events: []})
             ) ==
               InternalSession.llm_retry_at_ms(seeded)
    end

    {:ok, _pid} = InternalSessionFleet.ensure_started(agent, @session_id)

    assert eventually(
             fn -> InternalSession.llm_failures_exhausted?(read_session!(agent)) end,
             400
           )

    assert InternalSession.activity_status(read_session!(agent)) == :failed
    assert InternalSession.work_reasons(read_session!(agent)) == []
    calls = RecoveringLLM.calls()
    :ok = InternalSessionActor.wake(agent, @session_id)
    Process.sleep(100)
    assert RecoveringLLM.calls() == calls
    assert calls == 6

    RecoveringLLM.recover()

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent, @session_id, [
        %{
          "type" => "queue_append",
          "session_id" => @session_id,
          "kind" => "user_message",
          "dedupe_key" => "retry-after-exhaustion",
          "payload" => %{"content" => "continue now"}
        }
      ])

    :ok = InternalSessionActor.wake(agent, @session_id)
    assert eventually(fn -> InternalSession.next_message_id(read_session!(agent)) > 6 end)
    assert eventually(fn -> InternalSession.work_reasons(read_session!(agent)) == [] end)
    assert RecoveringLLM.calls() == calls + 1
  end

  test "new input supersedes a future retry deadline", %{agent: agent} do
    start_supervised!(RecoveringLLM)
    RecoveringLLM.recover()
    Application.put_env(:salix_agent, :llm, RecoveringLLM)
    due = System.system_time(:millisecond) + 30_000

    failure =
      terminal_failure(true)
      |> put_in(["event", "retry_at_ms"], due)
      |> put_in(["event", "transcript_hwm"], 4)

    {:ok, _} =
      InternalSessionStore.prepare_commit(agent, @session_id, [
        %{
          "type" => "runtime_message",
          "from_queue" => true,
          "session_id" => @session_id,
          "message_id" => 4,
          "runtime_message_id" => "preempt-async-result",
          "kind" => "tool_call_completed",
          "content" => "async retry incident"
        },
        %{"type" => "ack", "session_id" => @session_id, "last_ack_message_id" => 4},
        failure,
        %{
          "type" => "queue_append",
          "session_id" => @session_id,
          "kind" => "user_message",
          "dedupe_key" => "preempt-retry",
          "payload" => %{"content" => "continue now"}
        }
      ])

    {:ok, _pid} = InternalSessionFleet.ensure_started(agent, @session_id)
    assert eventually(fn -> InternalSession.next_message_id(read_session!(agent)) > 6 end)
    assert eventually(fn -> InternalSession.work_reasons(read_session!(agent)) == [] end)
    assert System.system_time(:millisecond) < due
    assert RecoveringLLM.calls() == 1
    assert is_nil(InternalSession.llm_retry_at_ms(read_session!(agent)))
  end

  test "wake-driven permanent failures park at the activation cap and resume on new input", %{
    agent: agent
  } do
    cap = State.llm_failure_activation_cap()
    assert cap > 0

    {:ok, _pid} = InternalSessionFleet.ensure_started(agent, @session_id)

    # The actor's own process loop drives the retries; without the breaker it
    # never stops (the staging incident shape). Round counting goes through the
    # recorded llm_call_failed events — the raw provider call count can include
    # unrelated LLM consumers (trajectory eval judge, titles).
    assert eventually(fn -> failure_count(agent, @session_id) == cap end)
    assert eventually(fn -> InternalSession.status(read_session!(agent)) == :idle end)

    # Parked: no further rounds without new input.
    Process.sleep(300)
    assert failure_count(agent, @session_id) == cap

    session = read_session!(agent)
    assert InternalSession.consecutive_llm_failures(session) == cap
    assert InternalSession.llm_failures_exhausted?(session)
    refute InternalSession.needs_transcript_continuation?(session)
    refute InternalSession.has_unprocessed_stable_work?(session)
    assert InternalSession.work_reasons(session) == []
    assert InternalSession.derived_state(session) == :paused

    # New session input advances the transcript position; the streak no longer
    # matches and exactly one fresh attempt runs (its failure acks the input,
    # so a user-tail transcript does not re-arm the loop).
    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent, @session_id, [
        %{
          "type" => "queue_append",
          "session_id" => @session_id,
          "kind" => "user_message",
          "dedupe_key" => "retry-input-1",
          "payload" => %{"content" => "try again"}
        }
      ])

    :ok = InternalSessionActor.wake(agent, @session_id)

    assert eventually(fn -> failure_count(agent, @session_id) == cap + 1 end)
    assert eventually(fn -> InternalSession.status(read_session!(agent)) == :idle end)

    Process.sleep(300)
    assert failure_count(agent, @session_id) == cap + 1

    session = read_session!(agent)
    assert InternalSession.consecutive_llm_failures(session) == 1
    refute InternalSession.llm_failures_exhausted?(session)
  end

  test "LLM task crashes settle the failed input at the cap without another retry", %{
    agent: agent
  } do
    cap = State.llm_failure_activation_cap()
    crash_session = "ses1_0000000000000000951"

    start_supervised!(CrashingLLM)
    Application.put_env(:salix_agent, :llm, CrashingLLM)

    # User-tail transcript, input not acked — the lost-call path of the
    # session driver records the failure without acking, so without the
    # breaker gate on stable input every wake retries forever.
    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent, crash_session, [
        %{"type" => "session_created", "session_id" => crash_session},
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => crash_session,
          "message_id" => 1,
          "content" => "inspect the workspace"
        }
      ])

    {:ok, _pid} = InternalSessionFleet.ensure_started(agent, crash_session)

    # The lost-call path does not re-queue :process itself; keep waking like the
    # server work-index scan does on staging. Without the stable-input gate
    # this drives rounds forever; with it the count stops exactly at the cap.
    assert eventually(fn ->
             _ = InternalSessionActor.wake(agent, crash_session)
             failure_count(agent, crash_session) >= cap
           end)

    Process.sleep(300)
    assert failure_count(agent, crash_session) == cap

    # Failure disposition acknowledges this input; later wakes cannot retry it.
    assert eventually(fn ->
             InternalSession.last_ack_message_id(read_session!(agent, crash_session)) == 1
           end)

    session = read_session!(agent, crash_session)
    refute SalixAgent.InternalSession.has_pending_stable_input?(session)
    refute InternalSession.llm_failures_exhausted?(session)

    assert Enum.any?(InternalSession.get(session, :events), fn event ->
             event["kind"] == "runtime_failure_disposed" and
               event["event"]["failure_reason"] == "model"
           end)

    refute InternalSession.has_unprocessed_stable_work?(session)
    assert InternalSession.work_reasons(session) == []
    assert InternalSession.derived_state(session) == :paused

    :ok = InternalSessionActor.wake(agent, crash_session)
    Process.sleep(300)
    assert failure_count(agent, crash_session) == cap

    # New input advances the transcript position and resumes retries.
    {:ok, _session} =
      InternalSessionStore.prepare_commit(agent, crash_session, [
        %{
          "type" => "queue_append",
          "session_id" => crash_session,
          "kind" => "user_message",
          "dedupe_key" => "crash-retry-input-1",
          "payload" => %{"content" => "try again"}
        }
      ])

    :ok = InternalSessionActor.wake(agent, crash_session)

    assert eventually(fn -> failure_count(agent, crash_session) == cap + 1 end)

    session = read_session!(agent, crash_session)
    assert InternalSession.consecutive_llm_failures(session) == 1
    refute InternalSession.llm_failures_exhausted?(session)
  end

  # Regression: a 403 dies on the first attempt (the retry loop declines to
  # resend a permanent failure) and commits no assistant message, so the streak
  # sat at 1 of 3 and the session reported the same `:paused` an ordinary
  # finished turn reports. Chat had nothing to distinguish "the model was
  # unreachable" from "the agent had nothing to say", and re-sending reset the
  # streak, so the cap was never reached and the surface stayed quiet forever.
  test "one non-retryable failure reports a model connection error", %{agent: agent} do
    {:ok, session} =
      InternalSessionStore.prepare_commit(agent, @session_id, [terminal_failure(false)])

    assert InternalSession.consecutive_llm_failures(session) == 1
    assert InternalSession.llm_failure_terminal?(session)
    assert InternalSession.activity_status(session) == :failed
    assert InternalSession.activity_issue(session) == "model_connection_failed"

    assert InternalSession.monitored_activity_signature(session) ==
             {:error, "model_connection_failed"}

    # Display authority only: the activation circuit breaker still counts to
    # its own cap, so parking behaviour is untouched by the error report.
    refute InternalSession.llm_failures_exhausted?(session)

    # The whole projection, not just the predicate: this is what the Participant
    # owner reads and republishes, so the reason code has to survive session_json
    # into Session Activity rather than defaulting to `runtime_failed` (which
    # WorkflowActor treats as directly blocking instead of message-recoverable).
    {:ok, activity} =
      SalixAgent.InternalAgentRuntime.get_session_activity(agent, @session_id)

    assert activity["state"] == "error"
    assert activity["issue"] == "model_connection_failed"
    assert activity["status"] == "error: the model could not be reached"
  end

  test "a retryable failure keeps the session quiet until the cap", %{agent: agent} do
    {:ok, session} =
      InternalSessionStore.prepare_commit(agent, @session_id, [terminal_failure(true)])

    assert InternalSession.consecutive_llm_failures(session) == 1
    refute InternalSession.llm_failure_terminal?(session)
    assert InternalSession.activity_status(session) == :paused
    assert InternalSession.monitored_activity_signature(session) == :stopped
  end

  test "new input clears the model connection error", %{agent: agent} do
    {:ok, session} =
      InternalSessionStore.prepare_commit(agent, @session_id, [terminal_failure(false)])

    assert InternalSession.activity_status(session) == :failed

    {:ok, session} =
      InternalSessionStore.prepare_commit(agent, @session_id, [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => @session_id,
          "message_id" => 4,
          "content" => "人呢"
        }
      ])

    # The stored hwm no longer matches the transcript position, so the terminal
    # flag lapses with the streak and the next round starts clean.
    refute InternalSession.llm_failure_terminal?(session)
    assert InternalSession.activity_issue(session) == nil
  end

  test "cap of 0 disables the circuit breaker", %{agent: agent} do
    {:ok, session} =
      InternalSessionStore.prepare_commit(
        agent,
        @session_id,
        synthetic_failures(State.llm_failure_activation_cap())
      )

    assert InternalSession.llm_failures_exhausted?(session)
    refute InternalSession.needs_transcript_continuation?(session)

    prev_cap = Application.get_env(:salix_agent, :llm_failure_activation_cap)
    Application.put_env(:salix_agent, :llm_failure_activation_cap, 0)

    on_exit(fn ->
      if prev_cap,
        do: Application.put_env(:salix_agent, :llm_failure_activation_cap, prev_cap),
        else: Application.delete_env(:salix_agent, :llm_failure_activation_cap)
    end)

    refute InternalSession.llm_failures_exhausted?(session)
    assert InternalSession.needs_transcript_continuation?(session)
  end

  test "failure events without a position marker never trip the breaker", %{agent: agent} do
    legacy =
      Enum.map(1..State.llm_failure_activation_cap(), fn n ->
        %{
          "type" => "session_event",
          "session_id" => @session_id,
          "event_id" => "llm-call-failed:#{@session_id}:legacy-#{n}",
          "kind" => "llm_call_failed",
          "source" => "internal_runtime",
          "event" => %{"reason" => "llm_task_failed"},
          "created_at" => System.system_time(:second)
        }
      end)

    {:ok, session} = InternalSessionStore.prepare_commit(agent, @session_id, legacy)

    assert InternalSession.consecutive_llm_failures(session) == 0
    refute InternalSession.llm_failures_exhausted?(session)
    assert InternalSession.needs_transcript_continuation?(session)
  end

  # A provider failure the retry loop refuses to resend (Error.http/3 stamps
  # `retryable` on every classified failure; 403/400-class ones are false).
  defp terminal_failure(retryable?) do
    %{
      "type" => "session_event",
      "session_id" => @session_id,
      "event_id" => "llm-call-failed:#{@session_id}:terminal-#{retryable?}",
      "kind" => "llm_call_failed",
      "source" => "internal_runtime",
      "event" => %{
        "category" =>
          if(retryable?, do: "retryable_provider_error", else: "permanent_provider_error"),
        "retryable" => retryable?,
        "status" => 403,
        "transcript_hwm" => 3
      },
      "created_at" => System.system_time(:second)
    }
  end

  # llm_call_failed events as Round's llm_error_boundary records them, at the
  # current transcript position (seeded transcript hwm is message id 3).
  defp synthetic_failures(count) do
    Enum.map(1..count, fn n ->
      %{
        "type" => "session_event",
        "session_id" => @session_id,
        "event_id" => "llm-call-failed:#{@session_id}:synthetic-#{n}",
        "kind" => "llm_call_failed",
        "source" => "internal_runtime",
        "event" => %{"category" => "permanent_provider_error", "transcript_hwm" => 3},
        "created_at" => System.system_time(:second)
      }
    end)
  end

  defp read_session!(agent, session_id \\ @session_id) do
    {:ok, session} = InternalSessionStore.read(agent, session_id)
    session
  end

  defp failure_count(agent, session_id) do
    agent
    |> read_session!(session_id)
    |> InternalSession.get(:events)
    |> Enum.count(&(&1["kind"] == "llm_call_failed"))
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, retries - 1)
    end
  end
end
