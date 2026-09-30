defmodule SalixAgent.CompactionOffActorTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{InternalSessionActor, InternalSessionFleet}
  alias SalixAgent.InternalSessionStore

  @session "ses1_0000000000000000940"

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake),
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

    prev = Application.get_env(:salix_agent, :summarizer)
    prev_threshold = Application.get_env(:salix_agent, :compaction_threshold)
    prev_llm = Application.get_env(:salix_agent, :llm)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_agent, :summarizer, prev),
        else: Application.delete_env(:salix_agent, :summarizer)

      if prev_threshold,
        do: Application.put_env(:salix_agent, :compaction_threshold, prev_threshold),
        else: Application.delete_env(:salix_agent, :compaction_threshold)

      if prev_llm,
        do: Application.put_env(:salix_agent, :llm, prev_llm),
        else: Application.delete_env(:salix_agent, :llm)

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
    Application.put_env(:salix_agent, :summarizer, fn _prev, _live ->
      send(test_pid, {:summarizing, self()})

      receive do
        :release -> "summary of the blocked compaction"
      after
        5_000 -> "timed out"
      end
    end)
  end

  @tag timeout: 170_000
  test "manual compact waits beyond the former 130 second result limit", %{agent_id: agent_id} do
    previous = Application.get_env(:salix_agent, :dependency_job_timeout_ms)
    Application.put_env(:salix_agent, :dependency_job_timeout_ms, %{compaction: 150_000})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :dependency_job_timeout_ms, previous),
        else: Application.delete_env(:salix_agent, :dependency_job_timeout_ms)
    end)

    Application.put_env(:salix_agent, :summarizer, fn _previous, _live ->
      Process.sleep(131_000)
      "summary after a slow provider response"
    end)

    assert {:ok, %{"status" => "compacted"}} =
             SalixAgent.InternalAgentRuntime.compact_session(agent_id, @session)

    assert {:ok, session} = read_state(agent_id, @session)
    assert session.compacted_seq > 0
  end

  test "an explicit compaction of a session that was never stored is a noop", %{
    agent_id: agent_id
  } do
    session_id = "ses1_0000000000000000941"
    context = %{agent_id: agent_id, session_id: session_id}

    assert {:ok, _context, %{"status" => "noop"}} =
             SalixAgent.Compaction.compact(context, session_id)

    assert {:error, :not_found} = InternalSessionStore.read_revision(agent_id, session_id)
  end

  test "the mailbox keeps serving while the summary is produced", %{agent_id: agent_id} do
    pid = actor_pid(agent_id)
    blocking_summarizer(self())

    caller =
      Task.async(fn ->
        InternalSessionActor.compact_session(pid, :compact, context(agent_id), [])
      end)

    assert_receive {:summarizing, summarizer}, 5_000

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

    assert :sys.get_state(pid).pending_compaction != nil

    # ...and a second compaction is refused rather than queued.
    assert {:error, :session_compacting} =
             InternalSessionActor.compact_session(pid, :compact, %{agent_id: agent_id}, [])

    send(summarizer, :release)

    assert {:ok, _context, %{"status" => "compacted"}} = Task.await(caller, 10_000)

    assert {:ok, session} = read_state(agent_id, @session)
    assert session.summary =~ "blocked compaction"
    assert session.compacted_through == 6
    assert :sys.get_state(pid).pending_compaction == nil
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

    blocking_summarizer(self())

    caller =
      Task.async(fn ->
        InternalSessionActor.compact_session(pid, :compact, context(agent_id), [])
      end)

    assert_receive {:summarizing, summarizer}, 5_000

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

    send(summarizer, :release)
    assert {:ok, _context, _result} = Task.await(caller, 10_000)

    assert {:ok, session} = read_state(agent_id, @session)
    late = Enum.find(session.async_results, &(&1["tool_call_id"] == "call-during"))
    assert late, "the terminal committed during the park must survive"

    # The summary never saw it, so the watermark must stay below it (#803).
    # Measured: compacted_seq 6, terminal seq 7 — the comparison is not
    # degenerate.
    assert session.compacted_seq < late["seq"]
  end

  # An UNEXPECTED task exit — and this is a NEW failure boundary, not the
  # old semantics preserved. Inline, an exit here killed the session actor
  # outright. Now the task crashes under `async_nolink`, the actor survives,
  # classifies the `:DOWN` into a compaction result, answers the deferred
  # caller and carries on. A provider failure is the other thing: summarize
  # returning `{:error, reason}`, which flows through
  # `recovery_summary_needed?` exactly as before.
  test "an unexpected task exit still answers the caller and leaves the session usable", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)
    test_pid = self()

    Application.put_env(:salix_agent, :summarizer, fn _prev, _live ->
      send(test_pid, {:summarizing, self()})
      exit(:boom)
    end)

    caller =
      Task.async(fn ->
        InternalSessionActor.compact_session(pid, :compact, context(agent_id), [])
      end)

    assert_receive {:summarizing, _}, 5_000

    # The caller still gets an answer — a deferred reply is still a reply —
    # and the actor is usable afterwards.
    assert {:ok, _context, %{"status" => status}} = Task.await(caller, 10_000)
    assert status in ["failed_soft", "failed_hard"]

    assert eventually(fn -> :sys.get_state(pid).pending_compaction == nil end)

    # Actor-routed again, for the same reason: a store read would pass even
    # if the crash had taken the actor with it.
    assert {:ok, _} =
             InternalSessionActor.stage_delivery(
               pid,
               %{
                 "kind" => "message",
                 "payload" => %{"role" => "user", "content" => "after the crash"},
                 "source_message_id" => "src-after-crash"
               },
               5_000
             )
  end

  # The crash test above drives `compact_session`, whose continuation is
  # `:reply` — an entry point the model deliberately excludes as a pipeline
  # stage. This one drives the continuation the model DOES cover: the
  # session driver's `:run_round` compaction before a round, reachable only
  # through an activation that runs a round.
  #
  # It also pins the branch the first cut of the model got wrong. A `:DOWN`
  # does not simply "stay in compaction and retry": it becomes the failed
  # compaction's result commit, and when THAT write lands, the driver runs the
  # round — exactly as after a successful compaction. Only a failed write
  # keeps the retry and starts no round.
  test "a task exit on the pipeline path still runs the round it was clearing for", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)
    test_pid = self()

    # The raw-byte threshold seam, so the seeded window is over the trigger and
    # the compaction before the round actually parks instead of finishing.
    Application.put_env(:salix_agent, :compaction_threshold, 1)

    # An identifiable reply, so "the round ran" is checked by its output
    # rather than inferred. `script/1` starts the Mock; the suite's `on_exit`
    # waits for this actor to go quiet before stopping it, so the round it
    # runs here cannot outlive the suite and eat the next one's script.
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SalixAgent.LLM.Mock.script([{:final, "pipeline round ran"}])

    # Blocks BEFORE exiting, so the park can be observed rather than raced —
    # otherwise `pending_compaction == nil` below would pass even if the
    # actor had never parked at all.
    Application.put_env(:salix_agent, :summarizer, fn _prev, _live ->
      send(test_pid, {:summarizing, self()})

      receive do
        :die -> exit(:boom)
      after
        5_000 -> exit(:boom)
      end
    end)

    # A queued delivery is what makes the activation run a round; without it
    # the actor never reaches the compaction before the round at all.
    assert {:ok, _} =
             InternalSessionActor.stage_delivery(
               pid,
               %{
                 "kind" => "message",
                 "payload" => %{"role" => "user", "content" => "drives the pipeline park"},
                 "source_message_id" => "src-pipeline-park"
               },
               5_000
             )

    send(pid, :process)
    assert_receive {:summarizing, summarizer}, 5_000

    # THE path assertion. This is the continuation the model covers; the other
    # crash test's is `{:reply, from}`, which the model excludes.
    assert %{"cont" => :run_round} = :sys.get_state(pid).pending_compaction.driver

    send(summarizer, :die)

    assert eventually(fn -> :sys.get_state(pid).pending_compaction == nil end),
           "the pipeline park never cleared after the task exit"

    assert Process.alive?(pid), "the summarize crash took the actor with it"

    # THE branch assertion, and it has to be something the ROUND produces.
    # `input_queue == []` would be vacuous here: the activation materializes
    # the queued delivery before the compaction is ever reached, so the queue
    # is already empty at park time. The scripted reply can only appear if the
    # failure result landed and the driver then ran the round.
    assert eventually(fn ->
             case read_state(agent_id, @session) do
               {:ok, session} ->
                 Enum.any?(session.messages || [], fn m ->
                   to_string(m[:content] || m["content"] || "") =~ "pipeline round ran"
                 end)

               _ ->
                 false
             end
           end),
           "the round the compaction was clearing for never ran"
  end

  test "pressure eviction cannot stop a parked summary", %{agent_id: agent_id} do
    {:ok, pid} = InternalSessionActor.start_link(agent_id: agent_id, session_id: @session)

    blocking_summarizer(self())

    caller =
      Task.async(fn ->
        InternalSessionActor.compact_session(pid, :compact, context(agent_id), [])
      end)

    assert_receive {:summarizing, summarizer}, 5_000

    with_memory_pressure(fn ->
      SalixAgent.SessionResidency.second_chance(pid)
      send(pid, :residency_evict)
      assert InternalSessionActor.busy?(pid)
      assert Process.alive?(pid), "pressure eviction stopped a pending compaction"
    end)

    send(summarizer, :release)
    assert {:ok, _context, %{"status" => "compacted"}} = Task.await(caller, 10_000)
  end

  test "two acknowledged control compactions both settle, and the first is not replaced", %{
    agent_id: agent_id
  } do
    pid = actor_pid(agent_id)
    blocking_summarizer(self())

    # Through the REAL control route, not a raw send: `stage_control` answers
    # `{:ok, :committed}` after sending ONE ephemeral message, and the public
    # API then polls for a result carrying that source id. So an acknowledged
    # request that gets declined must still SETTLE, or its caller polls to the
    # result-wait deadline.
    a = "src-control-a-#{System.unique_integer([:positive])}"
    b = "src-control-b-#{System.unique_integer([:positive])}"

    assert {:ok, :committed} = stage_compact_control(agent_id, a)
    assert_receive {:summarizing, summarizer}, 5_000
    first_ref = :sys.get_state(pid).pending_compaction.ref

    assert {:ok, :committed} = stage_compact_control(agent_id, b)
    _ = :sys.get_state(pid)

    # A is preserved: replacing it would orphan its continuation.
    assert :sys.get_state(pid).pending_compaction.ref == first_ref,
           "the in-flight compaction was replaced"

    # ...and B, which was already acknowledged, has settled rather than being
    # silently dropped.
    assert {:ok, session} = read_state(agent_id, @session)

    assert %{"status" => "noop", "reason" => "session_compacting"} =
             Map.get(session.compact_results || %{}, b),
           "control B was acknowledged but never settled; its caller polls to its deadline"

    send(summarizer, :release)

    assert eventually(fn ->
             case read_state(agent_id, @session) do
               {:ok, s} -> Map.has_key?(s.compact_results || %{}, a)
               _ -> false
             end
           end),
           "control A never settled"
  end

  test "a delivery that arrives during the park is processed after it", %{agent_id: agent_id} do
    pid = actor_pid(agent_id)
    blocking_summarizer(self())

    caller =
      Task.async(fn ->
        InternalSessionActor.compact_session(pid, :compact, context(agent_id), [])
      end)

    assert_receive {:summarizing, summarizer}, 5_000

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
    send(pid, :process)
    _ = :sys.get_state(pid)

    send(summarizer, :release)
    assert {:ok, _context, _} = Task.await(caller, 10_000)

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

    Application.put_env(:salix_agent, :summarizer, fn _previous, _live ->
      "summary before unfinished tool continuation"
    end)

    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SalixAgent.LLM.Mock.script([{:final, "resumed after compact control"}])

    source = "src-control-resume-#{System.unique_integer([:positive])}"
    assert {:ok, :committed} = stage_compact_control(agent_id, source)

    assert eventually(fn -> compact_result?(agent_id, source, "compacted") end),
           "the compact control never settled"

    assert eventually(fn -> response_count(agent_id, "resumed after compact control") == 1 end),
           "the compacted tool continuation was left paused without another wake"

    assert :ok = SalixAgent.TestSupport.await_session_quiet(agent_id, @session)
    _ = :sys.get_state(pid)
    assert response_count(agent_id, "resumed after compact control") == 1
    assert response_count(agent_id, "done") == 0
    assert Process.alive?(pid)
  end

  test "a control completion racing with a deferred wake runs the continuation once", %{
    agent_id: agent_id
  } do
    pid = passive_actor_pid(agent_id)
    seed_tool_continuation!(agent_id)
    blocking_summarizer(self())

    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SalixAgent.LLM.Mock.script([{:final, "resumed once after compact race"}])

    source = "src-control-race-#{System.unique_integer([:positive])}"
    assert {:ok, :committed} = stage_compact_control(agent_id, source)
    assert_receive {:summarizing, summarizer}, 5_000

    # A scheduler wake can race with a manual compact. The actor-owned level
    # trigger retains that wake, while successful control completion also
    # re-drives processing. Both requests must collapse onto one guarded model
    # round.
    send(pid, :process)
    assert eventually(fn -> :sys.get_state(pid).wake_pending end)

    send(summarizer, :release)

    assert eventually(fn -> response_count(agent_id, "resumed once after compact race") == 1 end),
           "the durable continuation did not resume"

    assert :ok = SalixAgent.TestSupport.await_session_quiet(agent_id, @session)
    _ = :sys.get_state(pid)
    assert response_count(agent_id, "resumed once after compact race") == 1
    assert response_count(agent_id, "done") == 0
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

  defp eventually(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _i, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end

  # The store hands back an opaque handle; these fixtures assert over the
  # exported state and re-open it whenever a handle is required.
  defp read_state(agent_id, session_id) do
    with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, session_id) do
      {:ok, SalixAgent.InternalSession.export(session)}
    end
  end

  defp with_memory_pressure(fun) do
    controller = Process.whereis(SalixAgent.SessionResidency)
    :sys.suspend(controller)
    previous = :ets.lookup(SalixAgent.SessionResidency, :pressure)

    try do
      :ets.insert(SalixAgent.SessionResidency, {:pressure, :high})
      fun.()
    after
      :ets.delete(SalixAgent.SessionResidency, :pressure)
      :ets.insert(SalixAgent.SessionResidency, previous)
      :sys.resume(controller)
    end
  end
end
