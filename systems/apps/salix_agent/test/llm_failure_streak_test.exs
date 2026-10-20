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
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

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

  defmodule GatewayCreditsLLM do
    @moduledoc "Fails like the AI Gateway after the platform's prepaid credits run out."
    @behaviour SalixAgent.LLM

    @impl true
    def complete(_messages, _tools), do: fail()

    @impl true
    def complete_stream(_messages, _tools, _on_delta), do: fail()

    defp fail do
      SalixAgent.LLM.Error.http("anthropic", 402, %{
        "name" => "AiGatewayError",
        "internalCode" => 2021,
        "message" => "Insufficient wholesale credits."
      })
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
      SystemsRuntime.Proc.exit(SystemsRuntime.Proc.self(), :kill)
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

    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(PermanentErrorLLM)
    SystemsRuntime.put_env(:salix_agent, :llm, PermanentErrorLLM)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)

      if prev_llm,
        do: SystemsRuntime.put_env(:salix_agent, :llm, prev_llm),
        else: SystemsRuntime.delete_env(:salix_agent, :llm)
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
  test "async result failure survives actor restart and resumes without new input", %{
    agent: agent
  } do
    # The round's provider retries back off 7.75s in total, and the durable
    # retry deadline follows; settling runs both at once on the clock.
    start_supervised!(RecoveringLLM)
    SystemsRuntime.put_env(:salix_agent, :llm, RecoveringLLM)
    previous = SystemsRuntime.get_env(:salix_agent, :llm_activation_retry_base_ms)
    SystemsRuntime.put_env(:salix_agent, :llm_activation_retry_base_ms, 2_000)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :llm_activation_retry_base_ms, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :llm_activation_retry_base_ms)
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
    assert eventually(fn -> failure_count(agent, @session_id) == 1 end, 600)
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
    settle()
    assert RecoveringLLM.calls() == 6
    assert eventually(fn -> InternalSession.next_message_id(read_session!(agent)) > 5 end, 600)
    assert eventually(fn -> InternalSession.work_reasons(read_session!(agent)) == [] end)
    assert failure_count(agent, @session_id) == 1
    assert RecoveringLLM.calls() == 7
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
    settle_after(300)
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

    settle_after(300)
    assert failure_count(agent, @session_id) == cap + 1

    session = read_session!(agent)
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
    assert activity["status"] == "error: the model request failed"
  end

  # Regression (staging 2026-10-02): once the AI Gateway's prepaid credits ran
  # out, every platform-funded call got HTTP 402. The Worker reported
  # `model_connection_failed` ("try sending again"), and a transcript that ends
  # in a tool result replayed the refused request up to the activation cap.
  # No retry and no member action could succeed.
  test "an exhausted platform provider account stops the input as an unavailable model", %{
    agent: agent
  } do
    SystemsRuntime.put_env(:salix_agent, :llm, GatewayCreditsLLM)

    {:ok, _pid} = InternalSessionFleet.ensure_started(agent, @session_id)

    assert eventually(fn -> failure_count(agent, @session_id) == 1 end)
    assert eventually(fn -> InternalSession.status(read_session!(agent)) == :idle end)

    # The stop holds: a later wake does not replay the refused transcript.
    :ok = InternalSessionActor.wake(agent, @session_id)
    settle_after(300)
    assert failure_count(agent, @session_id) == 1

    session = read_session!(agent)
    assert InternalSession.activity_issue(session) == "model_unavailable"
    refute InternalSession.has_unprocessed_stable_work?(session)

    {:ok, activity} =
      SalixAgent.InternalAgentRuntime.get_session_activity(agent, @session_id)

    assert activity["state"] == "error"
    assert activity["issue"] == "model_unavailable"
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
          "created_at" => SystemsClock.system_time(:second)
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
      "created_at" => SystemsClock.system_time(:second)
    }
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

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)
end
