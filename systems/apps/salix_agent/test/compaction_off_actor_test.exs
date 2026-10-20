defmodule SalixAgent.CompactionOffActorTest do
  use SystemsClock.Case, async: false
  require SystemsClock

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{InternalSessionActor, InternalSessionFleet}
  alias SalixAgent.InternalSessionStore

  @session "ses1_0000000000000000940"

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    SalixStore.Repo.query!("TRUNCATE session_work_candidates")

    agent_id = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent_id)

    {:ok, _} =
      InternalSessionStore.prepare_commit(
        agent_id,
        @session,
        [%{"type" => "session_created", "session_id" => @session, "name" => "Off actor"}] ++
          for id <- 1..6 do
            # Acknowledged assistant history, not deliveries: pending work
            # would leave the session `:active`, which compaction declines.
            %{
              "type" => "assistant",
              "session_id" => @session,
              "message_id" => id,
              "content" => String.duplicate("x", 200),
              "created_at" => 1_000 + id
            }
          end ++
          [%{"type" => "ack", "session_id" => @session, "last_ack_message_id" => 6}]
      )

    prev = SystemsRuntime.get_env(:salix_agent, :summarizer)
    prev_threshold = SystemsRuntime.get_env(:salix_agent, :compaction_threshold)
    prev_llm = SystemsRuntime.get_env(:salix_agent, :llm)

    on_exit(fn ->
      if prev,
        do: SystemsRuntime.put_env(:salix_agent, :summarizer, prev),
        else: SystemsRuntime.delete_env(:salix_agent, :summarizer)

      if prev_threshold,
        do: SystemsRuntime.put_env(:salix_agent, :compaction_threshold, prev_threshold),
        else: SystemsRuntime.delete_env(:salix_agent, :compaction_threshold)

      if prev_llm,
        do: SystemsRuntime.put_env(:salix_agent, :llm, prev_llm),
        else: SystemsRuntime.delete_env(:salix_agent, :llm)

      # BEFORE stopping: a delivery picked up after the park starts a REAL
      # round, and its LLM call runs in a task that `stop_all_agents/0` does
      # not reach. Left behind, it consumes the next suite's scripted
      # `LLM.Mock` entry — which is how this suite broke
      # `JsonlLogIntegrationTest` at `--seed 0`.
      :ok = SalixAgent.TestSupport.await_session_quiet(agent_id, @session)

      SalixAgent.TestSupport.stop_all_agents()
    end)

    {:ok, agent_id: agent_id}
  end

  defp context(agent_id), do: %{agent_id: agent_id, session_id: @session}

  defp actor_pid(agent_id) do
    {:ok, _} = InternalSessionFleet.ensure_started(agent_id, @session)

    [{pid, _}] =
      Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, @session))

    pid
  end

  defp passive_actor_pid(agent_id) do
    {:ok, _} =
      InternalSessionFleet.ensure_started(agent_id, @session, process_on_init: false)

    [{pid, _}] =
      Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, @session))

    pid
  end

  # A summary that blocks until this test releases it — standing in for the
  # seconds-to-tens-of-seconds a real model call takes.
  defp blocking_summarizer(test_pid) do
    SystemsRuntime.put_env(:salix_agent, :summarizer, fn _prev, _live ->
      SystemsRuntime.Proc.send(test_pid, {:summarizing, SystemsRuntime.Proc.self()})

      SystemsClock.vreceive do
        :release -> "summary of the blocked compaction"
      after
        5_000 -> "timed out"
      end
    end)
  end

  test "the mailbox keeps serving while the summary is produced", %{agent_id: agent_id} do
    pid = actor_pid(agent_id)
    blocking_summarizer(SystemsRuntime.Proc.self())

    caller =
      SystemsRuntime.Task.async(fn ->
        InternalSessionActor.compact_session(pid, :compact, context(agent_id), [])
      end)

    settle_receive({:summarizing, summarizer})
    # THE point of this change, and it has to be measured with a call that
    # actually ENTERS the actor. `get_session_summary` reads the store
    # directly and would pass even with the summary still inline — it proves
    # nothing about the mailbox. `stage_delivery` is a `GenServer.call` into
    # this actor, so it can only answer if the mailbox is being served.
    assert {:ok, _} =
             InternalSessionActor.stage_delivery(
               pid,
               %{
                 "kind" => "message",
                 "payload" => %{"role" => "user", "content" => "arrived mid-compaction"},
                 "source_message_id" => "src-mid-compaction"
               },
               5_000
             )

    assert :sys.get_state(pid, :infinity).pending_compaction != nil

    # ...and a second compaction is refused rather than queued.
    assert {:error, :session_compacting} =
             InternalSessionActor.compact_session(pid, :compact, %{agent_id: agent_id}, [])

    SystemsRuntime.Proc.send(summarizer, :release)

    assert {:ok, _context, %{"status" => "compacted"}} = settled_await(caller)

    assert {:ok, session} = read_state(agent_id, @session)
    assert session.summary =~ "blocked compaction"
    assert session.compacted_through == 6
    assert :sys.get_state(pid, :infinity).pending_compaction == nil
  end

  test "a terminal that lands through the actor during the park is not swallowed", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)

    # The call has to be RUNNING before the park, so the terminal is the only
    # thing that lands inside the window. Seeding a precondition is what
    # `prepare_commit` is for; the write under test below is not seeded.
    {:ok, _} =
      InternalSessionStore.prepare_commit(agent_id, @session, [
        %{
          "type" => "async_tool_call_started",
          "session_id" => @session,
          "tool_call_id" => "call-during",
          "tool_name" => "sleep",
          "status" => "running",
          "started_at" => 2_000
        }
      ])

    blocking_summarizer(SystemsRuntime.Proc.self())

    caller =
      SystemsRuntime.Task.async(fn ->
        InternalSessionActor.compact_session(pid, :compact, context(agent_id), [])
      end)

    settle_receive({:summarizing, summarizer})
    # THROUGH THE ACTOR, deliberately. `InternalSessionStore.prepare_commit`
    # is the documented escape hatch — it skips `ensure_session_owner`, so a
    # terminal written that way lands even with the summary still inline and
    # proves nothing about either the mailbox or the single-writer boundary.
    # `complete_async_tool_call/4` is a `GenServer.call` into this actor and
    # commits from inside it, so it can only succeed while the mailbox is
    # being served mid-park. #786 made this record the only durable copy of a
    # result, which is why it must not wait for the compaction.
    assert {:ok, _response} =
             InternalSessionActor.complete_async_tool_call(
               pid,
               "call-during",
               %{"answer" => 7},
               %{},
               5_000
             )

    SystemsRuntime.Proc.send(summarizer, :release)
    assert {:ok, _context, _result} = settled_await(caller)

    assert {:ok, session} = read_state(agent_id, @session)
    late = Enum.find(session.async_results, &(&1["tool_call_id"] == "call-during"))
    assert late, "the terminal committed during the park must survive"

    # The summary never saw it, so the watermark must stay below it (#803).
    # Measured: compacted_seq 6, terminal seq 7 — the comparison is not
    # degenerate.
    assert session.compacted_seq < late["seq"]
  end

  test "a delivery that arrives during the park is processed after it", %{agent_id: agent_id} do
    pid = actor_pid(agent_id)
    blocking_summarizer(SystemsRuntime.Proc.self())

    caller =
      SystemsRuntime.Task.async(fn ->
        InternalSessionActor.compact_session(pid, :compact, context(agent_id), [])
      end)

    settle_receive({:summarizing, summarizer})

    assert {:ok, _} =
             InternalSessionActor.stage_delivery(
               pid,
               %{
                 "kind" => "message",
                 "payload" => %{"role" => "user", "content" => "queued during park"},
                 "source_message_id" => "src-queued-during-park"
               },
               5_000
             )

    # The wake itself. Staging does not self-wake; in production the work
    # index drives `:process`. While parked, `maybe_process_session` drops
    # it — so unless the park remembers and re-arms it, this delivery has no
    # other wake coming and sits in the queue indefinitely.
    #
    # SCOPE: this drives `compact_session`, whose continuation is
    # `:reply` — the finished compaction only replies, so the re-sent
    # `:process` reaches an idle actor and the wake is genuinely DISCHARGED.
    # The auto path (continuation `:run_round`) is different and NOT covered
    # here: the finished compaction has already started the round, so the
    # re-sent `:process` lands on
    # `maybe_process_session(%{pending_llm: %{}})`, which records nothing —
    # the wake is handed to the LLM owner rather than served. That asymmetry
    # between the two `maybe_process_session/1` clauses is pre-existing (it
    # applies to any delivery staged during any round); the model records it
    # as `VisibleReplyObligation_ParkedWakeHandedOff` rather than pretending
    # this test covers it.
    SystemsRuntime.Proc.send(pid, :process)
    _ = :sys.get_state(pid, :infinity)

    SystemsRuntime.Proc.send(summarizer, :release)
    assert {:ok, _context, _} = settled_await(caller)

    assert eventually(fn ->
             case read_state(agent_id, @session) do
               {:ok, session} -> (session.input_queue || []) == []
               _ -> false
             end
           end),
           "the delivery queued during the park was never picked up"
  end

  test "a compact control resumes a durable tool continuation without another wake", %{
    agent_id: agent_id
  } do
    pid = passive_actor_pid(agent_id)
    seed_tool_continuation!(agent_id)

    SystemsRuntime.put_env(:salix_agent, :summarizer, fn _previous, _live ->
      "summary before unfinished tool continuation"
    end)

    SystemsRuntime.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SalixAgent.LLM.Mock.script([{:final, "resumed after compact control"}])

    source = "src-control-resume-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    assert {:ok, :committed} = stage_compact_control(agent_id, source)

    assert eventually(fn -> compact_result?(agent_id, source, "compacted") end),
           "the compact control never settled"

    assert eventually(fn -> response_count(agent_id, "resumed after compact control") == 1 end),
           "the compacted tool continuation was left paused without another wake"

    assert :ok = SalixAgent.TestSupport.await_session_quiet(agent_id, @session)
    _ = :sys.get_state(pid, :infinity)
    assert response_count(agent_id, "resumed after compact control") == 1
    assert response_count(agent_id, "done") == 0
    assert SystemsRuntime.Proc.alive?(pid)
  end

  defp stage_compact_control(agent_id, source_id) do
    InternalSessionFleet.stage_control(agent_id, @session, %{
      "kind" => "session_compact",
      "payload" => %{"kind" => "session_compact", "session_id" => @session},
      "source_message_id" => source_id
    })
  end

  defp seed_tool_continuation!(agent_id) do
    {:ok, session} =
      InternalSessionStore.prepare_commit(agent_id, @session, [
        %{
          "type" => "delivery",
          "from_queue" => true,
          "session_id" => @session,
          "message_id" => 7,
          "content" => "inspect the workspace before compact"
        },
        %{
          "type" => "assistant",
          "session_id" => @session,
          "message_id" => 8,
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call-control-compact",
              "name" => "call",
              "args" => %{"tool" => "fs.list", "params" => %{"path" => "/"}}
            }
          ]
        },
        %{
          "type" => "tool_result",
          "session_id" => @session,
          "message_id" => 9,
          "tool_call_id" => "call-control-compact",
          "content" => ~s({"entries":["notes.md"]})
        },
        %{"type" => "ack", "session_id" => @session, "last_ack_message_id" => 7}
      ])

    assert SalixAgent.InternalSession.needs_transcript_continuation?(session)
    assert SalixAgent.InternalSession.derived_state(session) == :queued
  end

  defp compact_result?(agent_id, source, status) do
    case read_state(agent_id, @session) do
      {:ok, session} -> get_in(session.compact_results || %{}, [source, "status"]) == status
      _ -> false
    end
  end

  defp response_count(agent_id, content) do
    case read_state(agent_id, @session) do
      {:ok, session} ->
        Enum.count(session.messages || [], fn message ->
          to_string(message[:content] || message["content"] || "") == content
        end)

      _ ->
        0
    end
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  # The store hands back an opaque handle; these fixtures assert over the
  # exported state and re-open it whenever a handle is required.
  defp read_state(agent_id, session_id) do
    with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, SalixAgent.InternalSession.export(session)}
    end
  end
end
