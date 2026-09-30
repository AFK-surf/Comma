defmodule SalixVerifiedKernel.SessionBoundaryTest do
  use ExUnit.Case, async: false
  alias SalixVerifiedKernel.Session

  test "snapshot writes reject an object address outside the captured session" do
    initial = Session.new("agent", "ses1_0000000000000000001")
    revision = Session.start_revision(initial, "base")
    pending = Session.write_revision(revision, [], nil, fn _, _ -> :ok end)
    wrong_key = "agents/other/internal_runtime/sessions/other/state.etf.zst"

    assert {:error, :session_key_mismatch} = Session.start_revision_fence(pending, wrong_key)

    {:verified_kernel, 1, :session_state, resident} = initial

    assert {:ok, nil, {:error, {:session_key_mismatch, []}}} =
             SalixVerifiedKernel.invoke_session_commit(resident, :start, {wrong_key, "base"})
  end

  test "a native storage read retains the observed revision through a later write" do
    agent = "agent"
    session_id = "ses1_0000000000000000001"
    initial = Session.new(agent, session_id)
    bytes = Session.persist(initial)

    digest = :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower)
    key = "agents/#{agent}/internal_runtime/sessions/#{digest}/state.etf.zst"

    assert {:ok, revision} =
             Session.read_revision(agent, session_id, fn requested, accept ->
               assert requested == key
               accept.({:ok, bytes, "read-version"})
             end)

    {loaded, "read-version", false} = Session.revision_view(revision)
    assert Session.get(loaded, :agent_id) == agent
    assert Session.get(loaded, :session_id) == session_id
    entry = %{source_message_id: "read-input", payload: %{content: "read-bound payload"}}
    report = fn _, _ -> :ok end

    {input, {:validate_write, _}} =
      Session.start_command(revision, :input, {entry, false}, nil, report)

    {staged, {:fence}} = Session.command_step(input, :write_result, :ok, report)

    assert {:error, :session_key_mismatch} =
             Session.start_revision_fence(staged, "another-session-key")

    assert {:ok, fence} = Session.start_revision_fence(staged, key)

    fence =
      Session.stamp_revision_fence(
        fence,
        {nil, [], "activity", "revision", "flush", nil, "node"},
        report
      )

    {_committing, {:cas, ^key, written, "read-version"}} = Session.encode_revision_fence(fence)
    assert {:comma_internal_session, 3, snapshot} = :erlang.binary_to_term(written)
    assert [%{"payload" => %{"content" => "read-bound payload"}}] = snapshot.input_queue
  end

  test "a storage read rejects mismatched owner and session before returning a revision" do
    session_id = "ses1_0000000000000000001"
    other_session = "ses1_0000000000000000002"

    owner_bytes = Session.new("other-agent", session_id) |> Session.persist()
    session_bytes = Session.new("agent", other_session) |> Session.persist()

    assert {:error, :session_agent_id_mismatch} =
             Session.read_revision("agent", session_id, fn _, accept ->
               accept.({:ok, owner_bytes, "etag"})
             end)

    assert {:error, :session_id_mismatch} =
             Session.read_revision("agent", session_id, fn _, accept ->
               accept.({:ok, session_bytes, "etag"})
             end)

    assert {:error, :invalid_session_id} =
             Session.read_revision("agent", "invalid", fn _, _ ->
               flunk("invalid identity reached storage")
             end)
  end

  test "input confirmation resumes only from its captured write and native CAS" do
    for base <- ["input-base", nil] do
      initial = Session.new("agent", "session")
      revision = Session.start_revision(initial, base)
      entry = %{source_message_id: "input-source", payload: %{content: "captured payload"}}
      report = fn _, _ -> :ok end

      {input, {:validate_write, events}} =
        Session.start_command(revision, :input, {entry, is_nil(base)}, nil, report)

      {staged, {:fence}} = Session.command_step(input, :write_result, :ok, report)
      staged_revision = Session.command_revision(staged)
      assert Session.revision_pending?(staged_revision)
      {working, ^base, true} = Session.revision_view(staged_revision)

      assert [%{"payload" => %{"content" => "captured payload"}}] =
               Session.get(working, :input_queue)

      {:verified_kernel, 1, :command_driver, awaiting} = staged

      for {operation, result} <- [
            fence_clean: nil,
            next: :ok,
            cas_result: {:ok, "unissued", :written}
          ] do
        assert {:ok, nil, {:raised, {:invalid_observation, []}}} =
                 SalixVerifiedKernel.invoke_session_command_driver(awaiting, operation, result)
      end

      key = hot_key()
      assert {:ok, fence} = Session.start_revision_fence(staged, key)

      fence =
        Session.stamp_revision_fence(
          fence,
          {nil, [], "activity", "revision", "flush", nil, "node"},
          report
        )

      {committing, {:cas, ^key, bytes, ^base}} =
        Session.encode_revision_fence(fence)

      assert {:error, candidate, :precondition_failed} =
               Session.resume_revision_fence_cursor(committing, {:error, :precondition_failed})

      assert Session.persist(candidate) == bytes

      {rejected, {:rejected, :precondition_failed}} =
        Session.command_step(staged, :fence_reject, {:error, :precondition_failed}, report)

      {failed, {:return, {:error, :precondition_failed}, nil}} =
        Session.command_step(rejected, :next, nil, report)

      {baseline, ^base, pending?} =
        failed |> Session.command_revision() |> Session.revision_view()

      assert pending? == is_nil(base)
      assert Session.persist(baseline) == Session.persist(initial)

      assert {:ok, confirmed} =
               Session.resume_revision_fence_cursor(committing, {:ok, "input-landed", :written})

      {notifying, {:effect, {:notify, "input_accepted", ^events}}} =
        Session.command_step(confirmed, :next, nil, report)

      {completed, {:return, {:ok, :committed}, nil}} =
        Session.command_step(notifying, :effect_result, {:error, :monitor_unavailable}, report)

      landed_revision = Session.command_revision(completed)
      {landed, "input-landed", false} = Session.revision_view(landed_revision)
      assert Session.persist(landed) == bytes

      {duplicate, {:fence}} =
        Session.start_command(landed_revision, :input, {entry, false}, nil, report)

      {duplicate, {:committed}} = Session.command_step(duplicate, :fence_clean, nil, report)

      assert {_done, {:return, {:ok, :duplicate}, nil}} =
               Session.command_step(duplicate, :next, nil, report)
    end
  end

  test "native revisions keep their baseline through writes, rollback, and CAS" do
    initial = Session.new("agent", "session")
    bytes = Session.persist(initial)
    clean = Session.start_revision(initial, "base")
    report = fn _, _ -> :ok end
    assert not Session.revision_pending?(clean)
    pending = Session.write_revision(clean, [], nil, report)
    assert Session.revision_pending?(pending)

    pending =
      Session.write_revision(pending, [%{"type" => "status", "status" => "active"}], 8, report)

    {working, "base", true} = Session.revision_view(pending)
    assert Session.get(working, :status) == :active
    assert Session.get(working, :next_message_id) == 9

    baseline = Session.revision_baseline(pending)
    {original, "base", false} = Session.revision_view(baseline)
    assert Session.persist(original) == bytes
    assert Session.revision_metadata(baseline) == {[], nil}
    assert Session.revision_pending?(pending)

    key = hot_key()
    assert {:ok, fence} = Session.start_revision_fence(pending, key)

    fence =
      Session.stamp_revision_fence(
        fence,
        {nil, [], "activity", "revision", "flush", nil, "node"},
        report
      )

    {committing, {:cas, ^key, encoded, "base"}} = Session.encode_revision_fence(fence)

    assert {:error, rejected, :precondition_failed} =
             Session.resume_revision_fence_cursor(committing, {:error, :precondition_failed})

    assert Session.persist(rejected) == encoded

    assert {:ok, committed} =
             Session.resume_revision_fence_cursor(committing, {:ok, "landed", :written})

    {landed, "landed", false} = Session.revision_view(committed)
    assert Session.persist(landed) == encoded
    assert Session.revision_metadata(committed) == {[], nil}

    written = Session.write_revision(committed, [], 10, report)
    {next, "landed", true} = Session.revision_view(written)
    assert Session.get(next, :next_message_id) == 11
    {saved, "landed", false} = written |> Session.revision_baseline() |> Session.revision_view()
    assert Session.persist(saved) == encoded
  end

  test "revision fences prepare and stamp one captured candidate before CAS confirmation" do
    initial = Session.new("agent", "session")
    fact = {1, "user_message", "fenced-source", %{"content" => "retained input"}}

    events = [
      %{
        "type" => "delivery",
        "from_queue" => true,
        "message_id" => 1,
        "source_message_id" => "fenced-source",
        "content" => "retained input",
        "accepted_input" => fact
      }
    ]

    report = fn _, _ -> :ok end
    pending = Session.start_pending_revision(initial, "captured-base")
    pending = Session.write_pending_revision(pending, events, 9, report)
    key = hot_key()
    assert {:ok, fence} = Session.start_revision_fence(pending, key)
    prepared = Session.fence_prepared_state(fence)
    assert [%{accepted_input: ^fact}] = Session.get(prepared, :messages)
    assert Session.get(prepared, :next_message_id) == 10

    {:verified_kernel, 1, :revision_fence, unfinished} = fence

    assert {:ok, nil, {:raised, {:invalid_observation, []}}} =
             SalixVerifiedKernel.invoke_session_fence(
               unfinished,
               :cas_result,
               {:ok, "unissued", :written}
             )

    fence =
      Session.stamp_revision_fence(
        fence,
        {"work-token", ["transcript_continuation"], "activity", "revision", "flush", 7,
         "owner-node"},
        report
      )

    {committing, {:cas, ^key, bytes, "captured-base"}} =
      Session.encode_revision_fence(fence)

    {:comma_internal_session, 3, snapshot} = :erlang.binary_to_term(bytes)
    assert [%{accepted_input: ^fact}] = snapshot.messages
    assert snapshot.runtime_epoch == 7
    assert snapshot.runtime_node == "owner-node"
    assert snapshot.storage_revision == "revision"
    assert snapshot.work_index_token == "work-token"

    assert {:ok, committed, "landed-etag"} =
             Session.resume_revision_fence(committing, {:ok, "landed-etag", :ambiguous_settled})

    assert Session.persist(committed) == bytes

    assert {:error, rejected, :precondition_failed} =
             Session.resume_revision_fence(committing, {:error, :precondition_failed})

    assert Session.persist(rejected) == bytes

    assert {:error, _rejected, :commit_indeterminate} =
             Session.resume_revision_fence(committing, {:error, :settlement_indeterminate})
  end

  test "pending revisions retain one baseline across staged batches and HWM updates" do
    initial = Session.new("agent", "session")
    bytes = Session.persist(initial)
    initial_pending = Session.start_pending_revision(initial, "baseline-etag")
    report = fn _, _ -> :ok end
    first = [%{"type" => "status", "status" => "active", "created_at" => 1000}]
    second = [%{"type" => "status", "status" => "idle", "created_at" => 1001}]
    pending = Session.write_pending_revision(initial_pending, first, 20, report)
    pending = Session.write_pending_revision(pending, second, 5, report)

    {baseline, "baseline-etag"} = Session.pending_baseline(pending)
    assert Session.persist(baseline) == bytes
    assert Session.pending_metadata(pending) == {first ++ second, 20}
    working = Session.pending_working(pending)
    assert Session.get(working, :status) == :idle
    assert Session.get(working, :next_message_id) == 21
    assert Session.pending_metadata(initial_pending) == {[], nil}
    assert Session.persist(Session.pending_working(initial_pending)) == bytes

    working_bytes = Session.persist(working)

    assert_raise FunctionClauseError, fn ->
      Session.write_pending_revision(pending, first ++ [:invalid], 40, report)
    end

    assert Session.persist(Session.pending_working(pending)) == working_bytes
    assert Session.pending_metadata(pending) == {first ++ second, 20}
  end

  test "an unfinished pending revision cannot replace its captured batch or expose a working snapshot" do
    initial = Session.new("agent", "session")

    {:verified_kernel, 1, :pending_revision, pending} =
      Session.start_pending_revision(initial, "baseline-etag")

    events = [%{"type" => "status", "status" => "active"}]

    assert {:ok, busy, {:next}} =
             SalixVerifiedKernel.invoke_session_pending(pending, :write, {events, nil})

    for {operation, payload} <- [working: nil, start: [], write: {[], nil}] do
      assert {:ok, nil, {:raised, {:invalid_observation, []}}} =
               SalixVerifiedKernel.invoke_session_pending(busy, operation, payload)
    end

    assert {:ok, completed, {:done}} =
             SalixVerifiedKernel.invoke_session_pending(busy, :run, Session.prelude())

    working = Session.pending_working({:verified_kernel, 1, :pending_revision, completed})
    assert Session.get(working, :status) == :active
  end

  test "revision planning captures queued work and retains its original durable baseline" do
    report = fn _, _ -> :ok end
    initial = Session.new("agent", "session")
    baseline = Session.start_revision(initial, "original-base")

    events =
      Enum.map(1..2, fn id ->
        %{
          "type" => "queue_append",
          "session_id" => "session",
          "kind" => "user_message",
          "dedupe_key" => "planned-#{id}",
          "wake" => true,
          "payload" => %{"source_message_id" => "planned-#{id}", "content" => "work #{id}"}
        }
      end)

    queued = Session.write_revision(baseline, events, 20, report)
    {before, "original-base", true} = Session.revision_view(queued)

    facts =
      Enum.map(Session.get(before, :input_queue), fn item ->
        {item["queue_id"], item["kind"], item["dedupe_key"], item["payload"]}
      end)

    for mode <- [:fast, :run] do
      {planned, :run, true} = Session.plan_revision(queued, mode, report)
      {working, "original-base", true} = Session.revision_view(planned)
      assert Session.get(working, :input_queue) == []
      assert Enum.map(Session.get(working, :messages), & &1.accepted_input) == facts
      {captured, hwm} = Session.revision_metadata(planned)
      assert Enum.take(captured, length(events)) == events
      assert hwm >= 20

      {original, "original-base", false} =
        planned |> Session.revision_baseline() |> Session.revision_view()

      assert Session.persist(original) == Session.persist(initial)
      assert Session.get(before, :input_queue) != []
      {unchanged, :idle, false} = Session.plan_revision(baseline, :until_wake, report)
      assert not Session.revision_pending?(unchanged)
    end

    {:verified_kernel, 1, :session_revision, native} = queued

    assert {:ok, busy, {:next}} =
             SalixVerifiedKernel.invoke_session_revision(native, :plan, {:run, Session.prelude()})

    for {operation, args} <- [working: nil, write: {[], nil}, plan: {:fast, []}] do
      assert {:ok, nil, {:raised, {:invalid_observation, []}}} =
               SalixVerifiedKernel.invoke_session_revision(busy, operation, args)
    end
  end

  test "a resident batch retains ordered input facts across event observations" do
    initial = Session.new("agent", "session")

    events =
      Enum.map(1..2, fn id ->
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => id,
          "source_message_id" => "source-#{id}",
          "content" => "input #{id}",
          "accepted_input" => {id, "user_message", "source-#{id}", %{"content" => "input #{id}"}}
        }
      end)

    owner = self()
    report = fn outcome, _started -> send(owner, {:batch_event, outcome}) end
    final = Session.apply_batch(initial, events, report)
    assert_receive {:batch_event, "ok"}
    assert_receive {:batch_event, "ok"}
    refute_receive {:batch_event, _}

    messages = Session.get(final, :messages)
    assert Enum.map(messages, & &1.seq) == [1, 2]
    assert Enum.map(messages, & &1.accepted_input) == Enum.map(events, & &1["accepted_input"])
    assert Session.get(initial, :messages) == []

    {:verified_kernel, 1, :session_state, resident} = initial

    assert {:ok, cursor, {:next}} =
             SalixVerifiedKernel.invoke_session_batch(resident, :start, events)

    assert {:ok, cursor, {:observe, request}} =
             SalixVerifiedKernel.invoke_session_batch(cursor, :run, [])

    raw = finish_batch_observations({:ok, cursor, {:observe, request}})
    assert {:ok, cursor, {:next}} = raw

    assert {:ok, cursor, {:observe, request}} =
             SalixVerifiedKernel.invoke_session_batch(cursor, :run, [])

    assert {:ok, resident, {:done}} =
             finish_batch_observations({:ok, cursor, {:observe, request}})

    restored = {:verified_kernel, 1, :session_state, resident}
    assert Session.get(restored, :messages) == messages
  end

  test "a failed batch does not expose partial state and telemetry cannot change its result" do
    initial = Session.new("agent", "session")
    owner = self()
    report = fn outcome, _started -> send(owner, {:batch_event, outcome}) end

    assert_raise FunctionClauseError, fn ->
      Session.apply_batch(
        initial,
        [%{"type" => "status", "status" => "active"}, :invalid],
        report
      )
    end

    assert_receive {:batch_event, "ok"}
    assert_receive {:batch_event, "error"}
    refute_receive {:batch_event, _}
    assert Session.get(initial, :status) != :active

    final =
      Session.apply_batch(initial, [%{"type" => "status", "status" => "active"}], fn _, _ ->
        raise "reporter unavailable"
      end)

    assert Session.get(final, :status) == :active
  end

  defp finish_batch_observations({:ok, resident, {:observe, request}}) do
    value =
      case request do
        :time -> 1000
        {:config, _app, _key, default} -> default
      end

    resident
    |> SalixVerifiedKernel.invoke_session_batch(:resume, {:ok, value})
    |> finish_batch_observations()
  end

  defp finish_batch_observations(result), do: result

  test "compaction failure uses current retry state and the request's coverage" do
    session = Session.new("agent", "session")
    args = {9, 4, "compaction_error", true, "unavailable", "config", "recovery summary"}
    [failure] = Session.query(session, :compaction_failure_events, args)
    assert failure["attempts"] == 1
    assert failure["next_retry_at"] - failure["failed_at"] == 30
    next = apply_events(session, [failure])
    [failure] = Session.query(next, :compaction_failure_events, args)
    assert failure["attempts"] == 2
    next = apply_events(next, [failure])
    assert [compaction, failure, recovery] = Session.query(next, :compaction_failure_events, args)
    assert compaction["compacted_seq"] == 4
    assert compaction["compacted_through"] == 9
    assert failure["recovery_summary_written"]
    assert recovery["summary_sequence"] == compaction["summary_sequence"]

    assert [reset] =
             Session.query(next, :compaction_failure_events, put_elem(args, 5, "new-config"))

    assert reset["attempts"] == 1
  end

  test "activation retry does not retry a response superseded by newer input" do
    session = trusted_session()
    metadata = %{"retryable" => true}
    assert Session.query(session, :llm_retry_metadata, {metadata, 0}) == metadata

    assert %{"retry_at_ms" => retry_at} =
             Session.query(session, :llm_retry_metadata, {metadata, 1})

    assert retry_at > System.system_time(:millisecond)

    refute Map.has_key?(
             Session.query(session, :llm_retry_metadata, {%{"retryable" => false}, 1}),
             "retry_at_ms"
           )
  end

  test "wait expiry uses the current wait identity and ignores a stale timer" do
    wait = %{"wait_id" => "current", "deadline_ms" => 1, "timeout_seconds" => 2}

    session =
      Session.new("agent", "session") |> apply_events([%{"type" => "wait_set", "wait" => wait}])

    assert nil == Session.query(session, :wait_timeout_event, {"old", "timer-delivery"})
    event = Session.query(session, :wait_timeout_event)
    assert event["dedupe_key"] == "wait-timeout:session:current"
    assert event["payload"]["wait_id"] == "current"
    assert event["payload"]["source_refs"]["deadline_ms"] == 1
    assert event["wake"]

    assert Session.query(session, :wait_timeout_event, {"current", "timer-delivery"})[
             "dedupe_key"
           ] == "timer-delivery"

    future =
      apply_events(session, [
        %{
          "type" => "wait_set",
          "wait" => %{wait | "deadline_ms" => System.system_time(:millisecond) + 60_000}
        }
      ])

    assert nil == Session.query(future, :wait_timeout_event)

    report = fn _, _ -> :ok end

    {expired, _outcome, true} =
      session |> Session.start_revision("wait-base") |> Session.plan_revision(:expire, report)

    {expired_state, "wait-base", true} = Session.revision_view(expired)
    assert Session.get(expired_state, :input_queue) == []

    assert Enum.any?(Session.get(expired_state, :messages), fn record ->
             match?({_, _, "wait-timeout:session:current", _}, record[:accepted_input])
           end)

    {retained, _outcome, false} =
      future |> Session.start_revision("future-base") |> Session.plan_revision(:expire, report)

    {retained_state, "future-base", false} = Session.revision_view(retained)
    assert Session.persist(retained_state) == Session.persist(future)
  end

  test "restart keeps external callbacks and live owners and aborts on an unknown staged outcome" do
    session =
      Session.new("agent", "session")
      |> apply_events([
        %{"type" => "async_tool_call_started", "tool_call_id" => "orphan", "tool_name" => "test"}
      ])

    assert {:perform, {"capability", record}, token} =
             Session.query(session, :restart_plan, {[], :interrupted})

    assert {:perform, {"staged_result", ^record}, token} =
             Session.query(session, :resume_restart, {token, %{"state" => "absent"}})

    assert {:return, {:error, {:staged_async_result_read_failed, "orphan", :unavailable}}} =
             Session.query(session, :resume_restart, {token, {:error, :unavailable}})

    assert {:return, {[], 1}} =
             Session.query(session, :restart_plan, {["orphan"], :interrupted})

    assert {:perform, _, external_token} =
             Session.query(session, :restart_plan, {[], :interrupted})

    assert {:return, {[], 1}} =
             Session.query(
               session,
               :resume_restart,
               {external_token, %{"state" => "pending", "record" => record}}
             )
  end

  test "restart notification preserves binary session identity" do
    session =
      Session.new("agent", <<255, 128>>)
      |> apply_events([%{"type" => "status", "status" => "active"}])

    assert {:return, {[_, event], 1}} =
             Session.query(session, :restart_plan, {[], :interrupted})

    assert event["dedupe_key"] == "runtime-recovered:llm:" <> <<255, 128>> <> ":message-1"
  end

  test "tool settlement counts guidance and parks at the configured progress budget" do
    previous = Application.get_env(:salix_agent, :runaway_unsettled_round_cap)
    Application.put_env(:salix_agent, :runaway_unsettled_round_cap, 1)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:salix_agent, :runaway_unsettled_round_cap),
        else: Application.put_env(:salix_agent, :runaway_unsettled_round_cap, previous)
    end)

    session = trusted_session() |> apply_events([%{"type" => "status", "status" => "active"}])

    unsettled = %{
      "type" => "session_event",
      "kind" => "runaway_unsettled_round",
      "event" => %{"assistant_message_id" => 2}
    }

    reset = %{"type" => "session_event", "kind" => "runaway_guard_reset", "event" => %{}}

    events =
      Session.query(
        session,
        :settle_tool_batch,
        {[], [%{status: "guidance"}], true, unsettled, reset, false}
      )

    next = apply_events(session, events)
    assert Session.get(next, :status) == :idle
    assert Session.query(next, :runaway_unsettled_rounds_exhausted?)

    events =
      Session.query(
        session,
        :settle_tool_batch,
        {[], [%{status: "completed"}], true, unsettled, reset, false}
      )

    refute Session.query(apply_events(session, events), :runaway_unsettled_rounds_exhausted?)
  end

  defp hot_key do
    digest = :crypto.hash(:sha256, "session") |> Base.encode16(case: :lower)
    "agents/agent/internal_runtime/sessions/#{digest}/state.etf.zst"
  end

  defp open(fields), do: Session.open(Map.new(fields))

  defp command(session, name, args, checkpoint \\ nil),
    do: Session.query(session, :command, {name, args, checkpoint})

  defp resume(session, continuation, result),
    do: Session.query(session, :resume_command, {continuation, result})

  defp apply_events(session, events) do
    Enum.reduce(events, session, fn event, state ->
      {:done, next} = state |> Session.step(event) |> Session.settle()
      next
    end)
  end

  defp trusted_session do
    origin = %{
      "provider" => "internal",
      "conversation_kind" => "user_chat",
      "source_actor_type" => "user",
      "agent_group_id" => "group",
      "conversation_id" => "conversation",
      "participant_id" => "participant",
      "message_id" => "message"
    }

    Session.new("agent", "session")
    |> Session.export()
    |> Map.put(:messages, [
      %{
        id: 1,
        role: "user",
        content: "reply",
        source_message_id: "source",
        trusted_origin: origin
      }
    ])
    |> Map.put(:next_message_id, 2)
    |> Session.open()
  end

  test "duplicate and new input acknowledgments both require their durable fence" do
    previous = Application.get_env(:salix_agent, :session_input_queue_limit)
    Application.put_env(:salix_agent, :session_input_queue_limit, 3)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:salix_agent, :session_input_queue_limit),
        else: Application.put_env(:salix_agent, :session_input_queue_limit, previous)
    end)

    session =
      Session.new("agent", "session")
      |> Session.export()
      |> Map.merge(%{input_queue: [%{}], input_dedupe: MapSet.new(["seen"])})
      |> Session.open()

    entry = %{
      source_message_id: "new",
      payload: %{pre_deliveries: [%{}], events: [%{"type" => "queue_append"}]}
    }

    assert {:return, {:error, :saturated}, nil} = command(session, :input, {entry, false})

    assert {:perform, :durable_fence, duplicate_token} =
             command(session, :input, {%{entry | source_message_id: "seen"}, false})

    assert {:return, {:error, :unavailable}, nil} =
             resume(session, duplicate_token, {:error, :unavailable})

    assert {:return, {:ok, :duplicate}, nil} = resume(session, duplicate_token, :ok)

    entry = %{entry | payload: %{content: "hello"}}
    assert {:perform, {:write, events, []}, token} = command(session, :input, {entry, false})
    assert {:return, {:error, :unavailable}, nil} = resume(session, token, {:error, :unavailable})
    committed = apply_events(session, events)
    assert {:perform, :durable_fence, token} = resume(committed, token, :ok)
    assert {:return, {:error, :unavailable}, nil} = resume(session, token, {:error, :unavailable})
    assert {:perform, {:notify, "input_accepted", ^events}, token} = resume(committed, token, :ok)
    assert {:return, {:ok, :committed}, nil} = resume(committed, token, :ok)

    assert {:return, {:ok, :committed}, nil} =
             resume(committed, token, {:error, :monitor_unavailable})
  end

  test "legacy recovery acknowledges its assistant and clears presentation only after commit" do
    intent = %{"assistant_message_id" => 7, "idempotency_key" => "reply-key", "scope" => %{}}

    session =
      Session.new("agent", "session")
      |> Session.export()
      |> Map.put(:visible_reply_intent, intent)
      |> Session.open()

    report = fn _, _ -> :ok end
    revision = Session.start_revision(session, "recovery-base")

    {writing, {:validate_write, _events}} =
      Session.start_command(revision, :recover, nil, nil, report)

    {staged, {:fence}} = Session.command_step(writing, :write_result, :ok, report)

    {recovered, "recovery-base", true} =
      staged |> Session.command_revision() |> Session.revision_view()

    assert Session.get(recovered, :visible_reply_intent) == nil
    assert Session.get(recovered, :last_ack_message_id) == 7
    assert Session.get(recovered, :status) == :idle

    {rejected, {:rejected, :unavailable}} =
      Session.command_step(staged, :fence_reject, {:error, :unavailable}, report)

    {failed, {:return, %{action: :retry}, nil}} =
      Session.command_step(rejected, :next, nil, report)

    {original, "recovery-base", false} =
      failed |> Session.command_revision() |> Session.revision_view()

    assert Session.get(original, :visible_reply_intent) == intent

    key = hot_key()
    assert {:ok, fence} = Session.start_revision_fence(staged, key)

    fence =
      Session.stamp_revision_fence(
        fence,
        {nil, [], "activity", "revision", "flush", nil, "node"},
        report
      )

    {committing, {:cas, ^key, bytes, "recovery-base"}} =
      Session.encode_revision_fence(fence)

    assert {:ok, confirmed} =
             Session.resume_revision_fence_cursor(committing, {:ok, "recovered", :written})

    {clearing, {:effect, {:draft_clear, %{}}}} =
      Session.command_step(confirmed, :next, nil, report)

    {done, {:return, %{action: :settled}, nil}} =
      Session.command_step(clearing, :effect_result, :ok, report)

    committed = Session.command_revision(done)
    {landed, "recovered", false} = Session.revision_view(committed)
    assert Session.persist(landed) == bytes

    assert {_done, {:return, %{action: :continue}, nil}} =
             Session.start_command(committed, :recover, nil, nil, report)
  end

  test "input commands fix lifecycle timestamps before exposing their write batch" do
    session = Session.new("agent", "session")

    entry = %{
      source_message_id: "timestamped",
      payload: %{
        content: "retained",
        created_at: 123,
        events: [%{type: "session_created", created_at: "invalid"}]
      }
    }

    assert {:perform, {:write, [embedded, created, input], []}, _} =
             command(session, :input, {entry, true})

    assert is_integer(embedded["created_at"])
    assert created["created_at"] == 123
    assert input["created_at"] == 123
    assert input["payload"]["created_at"] == 123
    assert input["payload"]["content"] == "retained"
  end

  test "workspace effects precede the session birth and a workspace failure cannot acknowledge input" do
    session = Session.new("agent", "session")
    workspace = %{"type" => "vfs_write", "path" => "file", "content" => "body"}
    side = %{"type" => "session_event", "kind" => "context", "event" => %{}}

    entry = %{
      source_message_id: "source",
      payload: %{
        content: "hello",
        events: [workspace, side],
        pre_deliveries: [%{content: "context"}]
      }
    }

    assert {:perform,
            {:workspace, "delivery-workspace:agent:session:source", _, [^workspace], %{}}, token} =
             command(session, :input, {entry, true})

    assert {:return, {:error, :unavailable}, nil} = resume(session, token, {:error, :unavailable})
    assert {:perform, {:write, [^side, created, pre, input], []}, _} = resume(session, token, :ok)
    assert created["type"] == "session_created"
    assert is_integer(created["created_at"])
    assert pre["wake"] == false
    assert input["payload"]["source_message_id"] == "source"

    destructive = %{type: "archive_advance", archived_through: 1, segments: []}
    rejected = put_in(entry, [:payload, :events], [workspace, destructive])

    assert {:return, {:error, :invalid_delivery_events}, nil} =
             command(session, :input, {rejected, true})

    for control <- [
          %{type: "session_stamp", agent_id: "another-agent"},
          %{
            type: "session_event",
            kind: "terminal_reply_delivered",
            event: %{settled_ack_hwm: 1}
          },
          %{type: "unknown_delivery_operation"}
        ] do
      rejected = put_in(entry, [:payload, :events], [workspace, control])

      assert {:return, {:error, :invalid_delivery_events}, nil} =
               command(session, :input, {rejected, true})
    end

    collision =
      put_in(entry, [:payload, :pre_deliveries], [
        %{content: "replacement", source_message_id: "source"}
      ])

    assert {:return, {:error, :invalid_delivery_events}, nil} =
             command(session, :input, {collision, true})

    runtime = %{
      type: "queue_append",
      kind: "runtime_message",
      dedupe_key: "runtime-source",
      payload: %{runtime_message_id: "source", content: "runtime"}
    }

    collision = put_in(entry, [:payload, :events], [workspace, runtime])

    assert {:return, {:error, :invalid_delivery_events}, nil} =
             command(session, :input, {collision, true})

    seeded = %{
      type: "transcript_seed",
      entries: [%{role: "user", content: "seed", source_message_id: "source"}]
    }

    collision = put_in(entry, [:payload, :events], [workspace, seeded])

    assert {:return, {:error, :invalid_delivery_events}, nil} =
             command(session, :input, {collision, true})
  end

  test "activation preserves authorization across a failed CAS and commits prompt and status together" do
    waiting =
      Session.new("agent", "session")
      |> apply_events([
        %{
          "type" => "async_tool_call_started",
          "tool_call_id" => "call",
          "tool_name" => "fs.read_file"
        },
        %{
          "type" => "wait_set",
          "wait" => %{
            "source" => "auto_wait",
            "tool_call_id" => "call",
            "deadline_ms" => System.system_time(:millisecond) + 60_000
          }
        }
      ])

    assert :fallback = Session.query(waiting, :activation_fast)

    completed =
      apply_events(waiting, [
        %{"type" => "async_tool_call_completed", "tool_call_id" => "call", "result" => %{}},
        %{
          "type" => "queue_append",
          "kind" => "runtime_message",
          "wake" => true,
          "dedupe_key" => "tool-call-result:call",
          "payload" => %{
            "type" => "tool_call_completed",
            "source_tool_call_id" => "call",
            "tool_call_id" => "call",
            "runtime_message_id" => "tool-call-result:call"
          }
        }
      ])

    assert {:activate, leading, _hwm} = Session.query(completed, :activation_fast)
    assert Session.get(apply_events(completed, leading), :wait) == nil

    provider_wait =
      Session.export(completed) |> Map.put(:wait, %{"source" => "wait_for"}) |> Session.open()

    assert :fallback = Session.query(provider_wait, :activation_fast)

    session = trusted_session()
    revision = Session.start_revision(session, "activation-base")
    report = fn _, _ -> :ok end
    args = {[], 25, "system prompt", true}

    assert {authorizing, {:effect, {:authorize, candidate}}} =
             Session.start_command(revision, :activate, args, nil, report)

    assert {entropy, {:effect, {:random, 18}}} =
             Session.command_step(authorizing, :effect_result, :ok, report)

    assert {writing, {:validate_write, events}} =
             Session.command_step(entropy, :effect_result, String.duplicate("a", 24), report)

    assert Enum.map(events, & &1["type"]) == [
             "visible_reply_activation_started",
             "session_system_prompt",
             "status"
           ]

    assert is_integer(List.last(events)["created_at"])
    assert {staged, {:fence}} = Session.command_step(writing, :write_result, :ok, report)

    {working, "activation-base", true} =
      staged |> Session.command_revision() |> Session.revision_view()

    assert Session.get(working, :next_message_id) == 26

    {rejected, {:rejected, :unavailable}} =
      Session.command_step(staged, :fence_reject, {:error, :unavailable}, report)

    assert {failed, {:return, {:error, _}, checkpoint}} =
             Session.command_step(rejected, :next, nil, report)

    assert checkpoint == candidate

    {baseline, "activation-base", false} =
      failed |> Session.command_revision() |> Session.revision_view()

    assert Session.persist(baseline) == Session.persist(session)

    assert {_retry, {:effect, {:random, 18}}} =
             Session.start_command(revision, :activate, args, checkpoint, report)

    key = hot_key()
    assert {:ok, fence} = Session.start_revision_fence(staged, key)

    fence =
      Session.stamp_revision_fence(
        fence,
        {nil, [], "activity", "revision", "flush", nil, "node"},
        report
      )

    {committing, {:cas, ^key, bytes, "activation-base"}} =
      Session.encode_revision_fence(fence)

    assert {:ok, confirmed} =
             Session.resume_revision_fence_cursor(
               committing,
               {:ok, "activation-landed", :written}
             )

    assert {completed, {:return, :ok, nil}} = Session.command_step(confirmed, :next, nil, report)
    committed_revision = Session.command_revision(completed)
    {committed, "activation-landed", false} = Session.revision_view(committed_revision)
    assert Session.persist(committed) == bytes
    identity = Session.get(committed, :visible_reply_activation_scope)["response_identity"]

    assert {authorizing, {:effect, {:authorize, ^candidate}}} =
             Session.start_command(
               committed_revision,
               :activate,
               {[], 0, nil, false},
               nil,
               report
             )

    assert {_completed, {:return, :ok, nil}} =
             Session.command_step(authorizing, :effect_result, :ok, report)

    assert Session.get(committed, :visible_reply_activation_scope)["response_identity"] ==
             identity
  end

  test "a changed source cannot use an authorization or identity from an earlier activation" do
    session = trusted_session()

    assert {:perform, {:authorize, _candidate}, token} =
             command(session, :activate, {[], 0, nil, false})

    assert {:perform, {:random, 18}, token} = resume(session, token, :ok)
    changed = Session.export(session) |> Map.put(:messages, []) |> Session.open()

    assert {:return, {:error, {:visible_reply_authorization_retry, :visible_reply_scope_changed}},
            _} =
             resume(changed, token, String.duplicate("a", 24))
  end

  test "one output plan distinguishes plain text, accepted end_turn, and repair without host phase decisions" do
    session = Session.new("agent", "session")
    assistant = %{"type" => "assistant", "message_id" => 1, "content" => "answer"}
    unsettled = %{"type" => "session_event", "kind" => "runaway_unsettled_round"}

    assert {%{"status" => "accepted", "outcome" => "done"}, [:draft_clear]} =
             Session.query(session, :output_preparation, {:clean, "done"})

    assert {:ok, accepted, _, plan} =
             Session.query(session, :finish_output, {[], assistant, 1, :clean, true, unsettled})

    assert Enum.any?(accepted, &(&1["type"] == "ack" and &1["last_ack_message_id"] == 1))
    assert {:completed, []} = Session.query(session, :output_committed, {plan, false})

    assert {:ok, text, _, plan} =
             Session.query(session, :finish_output, {[], assistant, 1, :clean, false, unsettled})

    refute Enum.any?(text, &(&1["type"] == "ack"))
    assert unsettled in text
    assert {:round_boundary, []} = Session.query(session, :output_committed, {plan, false})

    phase = {:repair_required, 0}

    assert {%{"status" => "not_settled", "reason" => "repair_required"}, []} =
             Session.query(session, :output_preparation, {phase, "done"})

    assert {:ok, repair, _, plan} =
             Session.query(session, :finish_output, {[], assistant, 1, phase, true, unsettled})

    refute Enum.any?(repair, &(&1["type"] == "ack"))
    assert Enum.any?(repair, &(&1["type"] == "visible_reply_repair" and &1["attempts"] == 1))
    assert {:round_boundary, []} = Session.query(session, :output_committed, {plan, false})
  end

  test "compaction admits fresh input beyond its ceiling but rejects changed covered content and coordinates" do
    session = open(storage_format: 3, summary_sequence: 2, compacted_through: 4)
    view = [%{id: 5, content: "covered"}]
    basis = Session.query(session, :compaction_snapshot, {view, 5})

    assert :ok =
             Session.query(
               session,
               :check_compaction_snapshot,
               {basis, view ++ [%{id: 6, content: "fresh"}], 5}
             )

    assert {:stale_compaction_view, ^view, [%{id: 5, content: "changed"}]} =
             Session.query(
               session,
               :check_compaction_snapshot,
               {basis, [%{id: 5, content: "changed"}], 5}
             )

    changed = open(storage_format: 3, summary_sequence: 3, compacted_through: 4)

    assert {:error, {:stale_compaction_snapshot, %{actual_summary_sequence: 3}}} =
             Session.query(changed, :check_compaction_snapshot, {basis, view, 5})

    legacy = open(storage_format: 1, summary_sequence: 2, compacted_through: 4)
    legacy_basis = Session.query(legacy, :compaction_snapshot, {view, 5})

    assert {:error,
            {:stale_compaction_snapshot, %{expected_storage_format: 1, actual_storage_format: 3}}} =
             Session.query(session, :check_compaction_snapshot, {legacy_basis, view, 5})
  end

  test "archive adoption ignores only retired guard diagnostics and preserves message facts" do
    session = Session.new("agent", "session")

    encode = fn {:deterministic_etf, value} ->
      :erlang.term_to_binary(value, [:deterministic, {:minor_version, 1}])
    end

    guard = %{seq: 1, kind: "fact", data: %{"kind" => "runaway_guard_reset", "event" => %{}}}
    old = put_in(guard.data["event"]["activation_key"], "retired")
    assert :ok = Session.query(session, :archive_match_prefix, {[old], [guard]}, encode)
    changed = put_in(old.data["event"]["reason"], "different")

    assert {:error, :segment_divergence} =
             Session.query(session, :archive_match_prefix, {[changed], [guard]}, encode)

    message = %{seq: 2, kind: "message", data: %{"activation_key" => "input metadata"}}
    stripped = %{message | data: %{}}

    assert {:error, :segment_divergence} =
             Session.query(session, :archive_match_prefix, {[stripped], [message]}, encode)

    assert {:error, :archive_ahead} =
             Session.query(session, :archive_match_prefix, {[old, message], [guard]}, encode)
  end

  test "archive publication resumes landed prefixes and never advances after a failed create" do
    session =
      open(
        agent_id: "agent",
        session_id: "session",
        archived_through: 0,
        compacted_seq: 3,
        segment_catalog: [],
        events: [],
        async_results: [],
        messages: Enum.map(1..3, &%{seq: &1, content: "input #{&1}"})
      )

    store = start_supervised!({Agent, fn -> %{objects: %{}, fail: true} end})

    io = fn
      {:read_segment, "agent", "session", first} ->
        Agent.get(store, fn state ->
          case Map.fetch(state.objects, first) do
            {:ok, records} -> {:ok, records}
            :error -> {:error, :not_found}
          end
        end)

      {:create_segment, "agent", "session", first, bytes} ->
        records = :erlang.binary_to_term(bytes)

        Agent.get_and_update(store, fn state ->
          if state.fail and first == 2 do
            {{:error, :unavailable}, state}
          else
            {:created, %{state | objects: Map.put(state.objects, first, records)}}
          end
        end)

      {:deterministic_etf, value} ->
        :erlang.term_to_binary(value, [:deterministic, {:minor_version, 1}])
    end

    assert {:error, {:segment_write_failed, :unavailable}} =
             Session.archive_publication(session, 1, io)

    assert Agent.get(store, &Map.keys(&1.objects)) == [1]
    assert Session.get(session, :archived_through) == 0
    assert length(Session.get(session, :messages)) == 3

    Agent.update(store, &%{&1 | fail: false})
    assert {:advance, event} = Session.archive_publication(session, 1, io)
    assert event["archived_through"] == 3
    assert Enum.map(event["segments"], &Enum.take(&1, 3)) == [[1, 1, 1], [2, 2, 1], [3, 3, 1]]
    assert Agent.get(store, &Enum.sort(Map.keys(&1.objects))) == [1, 2, 3]
    assert Session.get(session, :archived_through) == 0
  end

  test "archive projection orders all hot collections and refuses a sequence gap" do
    fields = [
      archived_through: 4,
      compacted_seq: 7,
      messages: [%{seq: 7, role: "user", content: %{nested: [%{value: "text"}]}}],
      events: [%{"seq" => 5, "kind" => "status"}],
      async_results: [%{"seq" => 6, "kind" => "tool_result", "output" => "done"}]
    ]

    assert {:ok, records, 7} = Session.query(open(fields), :archive_window)

    assert Enum.map(records, &{&1.seq, &1.kind}) == [
             {5, "fact"},
             {6, "tool_result"},
             {7, "message"}
           ]

    assert List.last(records).data == %{
             "role" => "user",
             "content" => %{"nested" => [%{"value" => "text"}]}
           }

    assert {:error, {:window_seq_gap, 6, 7}} =
             Session.query(open(Keyword.put(fields, :async_results, [])), :archive_window)
  end
end
