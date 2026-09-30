defmodule SalixIM.TriageTest do
  @moduledoc """
  End-to-end engine chain for native Triage: admission, debounce, generation
  seal, run fence, worker, terminal, ledger, and replay.

  Every receipt main's Slack callback route can write is endpoint-provenanced,
  so every sealed generation is an identity (`comma.triage-input-snapshot.v2`)
  run. `SalixIM.Triage.Pipeline` admits only the production BridgeForTeams
  context port for those, so with no L3 context configured the frozen-context
  step fails closed and the run settles authoritatively as
  `failed / identity_diagnostic_internal_error`. That is the correct dark
  behaviour for this slice, and it still drives the whole engine heart, so the
  cases below assert seal timing, generation transitions, fence ownership, and
  durable terminals rather than evaluator decisions.

  L3: the cases that need a real evaluated decision — a live evaluator port, a
  slow worker, or the BridgeForTeams context port — are listed at the bottom of
  this moduledoc and land with the evaluator/BFT seam:
    * "propagates the accepted observability context into the evaluation worker"
      (evaluator-observed context; the telemetry half is ported below)
    * "timeout is the sole authoritative terminal and a late result is linked
      but inert"
    * "durable deadline keeps timeout authoritative when its first terminal
      write fails"
    * "a normal legacy worker result remains linked when timeout wins before
      its CAS retry" (also needs the legacy non-provenanced receipt shape,
      which main's ingress can no longer produce)
    * "paged receipt enumeration never occupies the sole Runtime mailbox"
      (Runtime no longer pages receipts; `SalixIM.Triage.ReceiptRecovery` owns
      that lane in its own process)
    * "a delayed recovered generation cannot replace a newer local generation"
      (needs the source branch's in-Runtime recovery commit barrier)
    * "a typed receipt without connect generation is rejected before durable
      write" (main's equivalent lives in `slack_triage_receipt_test.exs`)
    * the whole of the source branch's `triage_m2_test.exs`: it drives the
      rolling-compatible v1 snapshot path with a synthetic context port, and
      main's ingress can only write provenanced receipts, so every generation
      it seals is a v2 identity run
  """

  use ExUnit.Case, async: false

  import SalixIM.TriageEngineFixtures

  alias SalixIM.Triage
  alias SalixIM.Triage.{Bucketing, Runtime}
  alias SalixStore.{CasRecord, Keys, S3, ULID}

  defmodule ForbiddenEvaluator do
    @moduledoc false
    @behaviour SalixIM.Ports.TriageEvaluator

    @impl true
    def evaluate(_input, opts) do
      if pid = opts[:test_pid], do: send(pid, :evaluator_called)
      {:error, :must_not_run}
    end
  end

  setup do
    previous_triage_backend = Application.get_env(:salix_store, :triage_record_backend)
    Application.put_env(:salix_store, :triage_record_backend, SalixStore.S3)
    S3.Fake.reset()
    S3.Fake.clear_blackhole()

    on_exit(fn ->
      S3.Fake.clear_blackhole()

      if previous_triage_backend do
        Application.put_env(:salix_store, :triage_record_backend, previous_triage_backend)
      else
        Application.delete_env(:salix_store, :triage_record_backend)
      end
    end)

    authority = authority!()
    namespace = "triage-test-#{System.unique_integer([:positive])}"

    server =
      start_runtime(namespace,
        debounce_ms: 15,
        max_wait_ms: 60,
        evaluation_timeout_ms: 100
      )

    %{server: server, authority: authority, namespace: namespace}
  end

  # The agent-to-agent round budget is configuration this build only READS.
  # Review mode has zero egress, so no round can be spent here and there is no
  # action-execution seam to enforce it at — the live-mode PR is what consumes
  # it. What must hold now is that the knob exists, defaults to something safe,
  # and refuses a nonsense value at start rather than at the first loop.
  test "the agent round budget is validated and defaulted before live mode can spend it" do
    default = start_runtime("triage-agent-budget-#{System.unique_integer([:positive])}")
    assert Runtime.agent_round_budget(default) == 2

    configured =
      start_runtime("triage-agent-budget-#{System.unique_integer([:positive])}",
        agent_round_budget: 0
      )

    assert Runtime.agent_round_budget(configured) == 0

    Process.flag(:trap_exit, true)

    assert {:error, {:invalid_triage_runtime_options, _stack}} =
             start_supervised(
               {Runtime,
                [
                  name: nil,
                  mode: :review,
                  namespace: "triage-agent-budget-invalid",
                  evaluator_port: {ForbiddenEvaluator, []},
                  agent_round_budget: -1
                ]},
               id: make_ref()
             )
  end

  test "batches a thread into one authoritative run and replays it offline", ctx do
    %{server: server, authority: authority, namespace: namespace} = ctx

    {first, second} =
      while_runtimes_suspended([server], fn ->
        first = admit!(server, authority, "Ev-1", text: "Atlas 的登录问题似乎需要确认处理人")

        second =
          thread_receipt!(authority, "Ev-2", ts(2), text: "我记得会里讨论过")
          |> then(&accept!(server, authority, &1))

        assert accept!(server, authority, first, :duplicate)
        {first, second}
      end)

    assert get_in(first, ["triage_event", "bucket"]) == %{
             "workspace_id" => authority["workspace_id"],
             "channel_id" => authority["approved_channel_id"],
             "thread_ts" => root_ts()
           }

    assert [%{"authoritative" => true, "status" => "failed"} = run] =
             eventually(fn -> Triage.ledger_records(server) end)

    # The ledger projection redacts raw receipt refs into stable per-run
    # ordinals, so membership is asserted as the ordered projection.
    assert run["input_receipt_refs"] == ["receipt://run/r001", "receipt://run/r002"]

    assert run["decision"] == %{
             "action" => "silence",
             "reason" => "identity_diagnostic_internal_error"
           }

    assert is_binary(run["input_snapshot_sha256"])
    assert {:ok, ^run} = Triage.replay(server, run["run_id"])

    # The sealed generation is durable evidence, and the receipt that reached
    # it never re-enters an open generation.
    assert {:ok, bucket} = Bucketing.load(namespace, scope(authority))
    assert bucket["open_receipts"] == []

    assert [%{"receipts" => sealed_receipts}] = bucket["sealed_generations"]

    assert Enum.map(sealed_receipts, & &1["receipt_ref"]) ==
             Enum.map([first, second], & &1["receipt_ref"])
  end

  test "accept telemetry runs under the captured caller trace", ctx do
    %{server: server, authority: authority} = ctx
    handler = attach_phase_handler("accept", self())
    on_exit(fn -> :telemetry.detach(handler) end)

    receipt = receipt!(authority, "Ev-accept-context", text: "trace the callback admission")

    parent_span_context =
      SystemsObservability.Context.with_surface(:bft, fn ->
        SystemsObservability.Trace.with_span(
          :bft_salix,
          %{component: :salix_im, operation: :salix_boundary, surface: :bft},
          fn ->
            parent_span_context = OpenTelemetry.Tracer.current_span_ctx()
            accept!(server, authority, receipt)
            parent_span_context
          end
        )
      end)

    assert_receive {:triage_phase_context, accept_span_context, "bft"}, 500
    assert OpenTelemetry.Span.is_valid(parent_span_context)
    assert OpenTelemetry.Span.is_valid(accept_span_context)

    assert OpenTelemetry.Span.trace_id(accept_span_context) ==
             OpenTelemetry.Span.trace_id(parent_span_context)
  end

  test "carries the accepted observability surface into the evaluation worker", ctx do
    %{server: server, authority: authority} = ctx
    handler = attach_phase_handler("evaluation", self())
    on_exit(fn -> :telemetry.detach(handler) end)

    receipt = receipt!(authority, "Ev-observability", text: "observe this callback")

    SystemsObservability.Context.with_surface(:bft, fn ->
      accept!(server, authority, receipt)
    end)

    assert_receive {:triage_phase_context, _span_context, "bft"}, 500
  end

  test "emits one finite telemetry phase chain for an accepted run", ctx do
    %{server: server, authority: authority} = ctx
    handler = "triage-phase-chain-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:salix, :triage, :phase, :stop],
        fn _event, measurements, metadata, test_pid ->
          send(test_pid, {:triage_phase, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    admit!(server, authority, "Ev-telemetry", text: "U_TELEMETRY_SECRET")

    assert [%{"run_id" => run_id}] = eventually(fn -> Triage.ledger_records(server) end)
    assert {:ok, _replay} = Triage.replay(server, run_id)

    telemetry = collect_triage_phases([])
    phases = MapSet.new(Enum.map(telemetry, & &1.phase))
    required = MapSet.new(~w(accept seal fence evaluation terminal replay))
    assert MapSet.subset?(required, phases)
    assert MapSet.subset?(phases, MapSet.put(required, "recovery"))

    assert Enum.all?(telemetry, fn metadata ->
             metadata.outcome in ~w(ok error timeout unavailable conflict rejected skipped other) and
               metadata.source_mode in ~w(callback historical system other) and
               metadata.surface in ~w(bft system other)
           end)

    refute inspect(telemetry) =~ "U_TELEMETRY_SECRET"
  end

  test "terminal telemetry reports projection storage unavailability", ctx do
    %{server: server, authority: authority, namespace: namespace} = ctx
    handler = "triage-terminal-unavailable-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:salix, :triage, :phase, :stop],
        fn _event, _measurements, metadata, test_pid ->
          if metadata.phase == "terminal", do: send(test_pid, {:triage_terminal, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      S3.Fake.blackhole(
        {:fail, 503, :put,
         {:prefix, SalixStore.TriageKeys.ctl_im_triage_ledger_runs_prefix(namespace)}}
      )

    admit!(server, authority, "Ev-terminal-unavailable", text: "persist this terminal")

    assert_receive {:triage_terminal, %{outcome: "unavailable"}}, 1_000

    assert eventually(fn ->
             map_size(:sys.get_state(server).terminal_projection_schedules) > 0
           end)
  end

  test "the global receipt ring re-admits a receipt left by a crash", ctx do
    %{server: server, authority: authority, namespace: namespace} = ctx

    receipt = receipt!(authority, "Ev-kill-window", text: "receipt landed before projection")

    assert {:ok, true} =
             SalixIM.ProviderReceipts.record_slack(authority["connect_id"], "Ev-ordinary")

    recovery =
      start_supervised!(
        {SalixIM.Triage.ReceiptRecovery,
         name: nil,
         runtime: server,
         page_limit: 5,
         interval_ms: 1,
         full_ring_idle_ms: 5,
         held_poll_ms: 5,
         lease_key: "ctl/test/triage-engine-ring/#{System.unique_integer([:positive])}",
         lease_ttl_ms: 5_000},
        id: make_ref()
      )

    # The ring feeds the receipt through the same `accept_current/3` path the
    # provider uses, so it lands in the durable bucket and seals on its own.
    assert eventually(fn ->
             match?(
               {:ok, %{"sealed_generations" => [%{"receipts" => [^receipt]}]}},
               Bucketing.load(namespace, scope(authority))
             )
           end)

    # The ordinary legacy receipt is never projected into a Triage bucket.
    assert [run] = eventually(fn -> Triage.ledger_records(server) end)
    assert run["input_receipt_refs"] == ["receipt://run/r001"]
    assert Process.alive?(recovery)
  end

  test "durable receipt projection never occupies the sole Runtime mailbox", ctx do
    %{server: server, authority: authority, namespace: namespace} = ctx

    receipt =
      receipt!(authority, "Ev-projection-stalled", text: "typed projection storage stalls")

    marker_key =
      SalixStore.TriageKeys.ctl_im_triage_projection_marker(namespace, receipt["receipt_ref"])

    :ok = S3.Fake.blackhole({:delay, 400, :put, marker_key})

    admission = Task.async(fn -> Runtime.accept_current(server, authority, receipt) end)
    Process.sleep(20)

    started_at = System.monotonic_time(:millisecond)
    assert %{namespace: ^namespace} = :sys.get_state(server, 100)
    assert System.monotonic_time(:millisecond) - started_at < 100

    assert {:ok, :accepted} = Task.await(admission, 1_500)
  end

  test "a fresh runtime rearms a bucket left by a stopped peer", ctx do
    %{authority: authority} = ctx
    namespace = "triage-projection-kill-#{System.unique_integer([:positive])}"

    original =
      start_runtime(namespace, restart: :temporary, debounce_ms: 5_000, max_wait_ms: 10_000)

    receipt =
      admit!(original, authority, "Ev-projected-kill", text: "marker landed, seal did not")

    :ok = GenServer.stop(original)

    recovered = start_runtime(namespace, debounce_ms: 20, max_wait_ms: 60)

    # The same durable receipt re-enters the engine as a duplicate admission and
    # still arms the debounce window that the stopped peer never fired.
    assert accept!(recovered, authority, receipt, :duplicate)

    assert [run] = eventually(fn -> Triage.ledger_records(recovered) end)
    assert run["input_receipt_refs"] == ["receipt://run/r001"]
  end

  test "trailing debounce rechecks the stale flush scheduled by the first message" do
    authority = authority!()
    namespace = "triage-debounce-#{System.unique_integer([:positive])}"
    server = start_seal_watch_runtime(namespace, debounce_ms: 60_000, max_wait_ms: 120_000)
    scope = scope(authority)
    created_at = System.system_time(:millisecond)

    accept!(
      server,
      authority,
      thread_receipt!(authority, "Ev-debounce-1", ts(1),
        text: "first",
        created_at: created_at
      )
    )

    first_state = :sys.get_state(server)

    assert %{id: first_schedule_id, token: token, generation: generation} =
             first_state.flush_schedules[scope]

    accept!(
      server,
      authority,
      thread_receipt!(authority, "Ev-debounce-2", ts(2),
        text: "second",
        created_at: created_at + 1
      )
    )

    second_state = :sys.get_state(server)

    assert %{id: ^first_schedule_id, token: ^token, generation: ^generation} =
             second_state.flush_schedules[scope]

    assert Enum.map(second_state.buckets[scope].receipts, & &1["event_id"]) == [
             "Ev-debounce-1",
             "Ev-debounce-2"
           ]

    # Deliver the first message's still-authoritative timer capability directly.
    # The Runtime must re-read the later bucket deadline and mint a fresh timer,
    # without entering the seal boundary. This is the production branch the old
    # sleep/refute_receive window intended to cover, now independent of scheduler
    # latency.
    send(server, {:flush, scope, token, generation, first_schedule_id})
    rearmed_state = :sys.get_state(server)

    assert %{id: rearmed_schedule_id, token: ^token, generation: ^generation} =
             rearmed_state.flush_schedules[scope]

    refute rearmed_schedule_id == first_schedule_id
    refute_received {:before_seal, _scope, _generation, _pid, _at}

    assert {:ok,
            %{
              "open_receipts" => open_receipts,
              "sealed_generations" => []
            }} = Bucketing.load(namespace, scope)

    assert Enum.map(open_receipts, & &1["event_id"]) == ["Ev-debounce-1", "Ev-debounce-2"]
  end

  test "max wait seals an overdue generation despite fresh ambient chatter" do
    authority = authority!()
    namespace = "triage-max-wait-#{System.unique_integer([:positive])}"
    policy = %{debounce_ms: 60_000, max_wait_ms: 120_000}
    server = start_seal_watch_runtime(namespace, Map.to_list(policy))
    scope = scope(authority)

    generation =
      while_runtimes_suspended([server], fn ->
        now = System.system_time(:millisecond)

        for {index, created_at} <- [{1, now - policy.max_wait_ms - 1}, {2, now}, {3, now}] do
          accept!(
            server,
            authority,
            thread_receipt!(authority, "Ev-max-#{index}", ts(index),
              text: "ambient update #{index}",
              created_at: created_at
            )
          )
        end

        assert {:ok, bucket} = Bucketing.load(namespace, scope)

        assert Enum.map(bucket["open_receipts"], & &1["event_id"]) ==
                 ["Ev-max-1", "Ev-max-2", "Ev-max-3"]

        observed_at = System.system_time(:millisecond)
        assert bucket["open_first_at"] + policy.max_wait_ms <= observed_at
        assert bucket["open_last_at"] + policy.debounce_ms > observed_at
        bucket["open_generation"]
      end)

    # All receipts are durably admitted before the Runtime resumes. Max wait
    # is already due while trailing debounce is still far ahead; that trailing
    # deadline alone cannot justify sealing within this observation window.
    # This checks deadline selection, not a 130ms host-scheduling guarantee.
    assert_receive {:before_seal, ^scope, ^generation, ^server, _fired_at}, 1_000

    sealed =
      eventually(fn ->
        case Bucketing.load_sealed_generation(namespace, scope, generation) do
          {:ok, sealed} -> sealed
          _not_sealed -> false
        end
      end)

    assert Enum.map(sealed["receipts"], & &1["event_id"]) ==
             ["Ev-max-1", "Ev-max-2", "Ev-max-3"]
  end

  test "bot mentions and direct questions use the fast path" do
    authority = authority!()
    namespace = "triage-fast-path-#{System.unique_integer([:positive])}"
    server = start_seal_watch_runtime(namespace, debounce_ms: 500, max_wait_ms: 1_000)

    mention = receipt!(authority, "Ev-fast", text: "<@#{authority["bot_user_id"]}> answer")
    assert mention["triage_event"]["fast_path"]

    fast_started = System.monotonic_time(:millisecond)
    accept!(server, authority, mention)
    assert_receive {:before_seal, _scope, _generation, _pid, fast_fired}, 80
    assert fast_fired - fast_started < 80

    question =
      receipt!(authority, "Ev-question",
        text: "who owns this?",
        thread_ts: ts(9),
        message_ts: ts(9)
      )

    assert question["triage_event"]["fast_path"]

    question_started = System.monotonic_time(:millisecond)
    accept!(server, authority, question)
    assert_receive {:before_seal, _scope, _generation, _pid, question_fired}, 80
    assert question_fired - question_started < 80
  end

  test "a receipt accepted after a seal enters the next durable generation" do
    authority = authority!()
    namespace = "triage-next-generation-#{System.unique_integer([:positive])}"
    server = start_seal_watch_runtime(namespace, debounce_ms: 0, max_wait_ms: 1)

    accept!(server, authority, thread_receipt!(authority, "Ev-gen-1", ts(1), text: "first"))
    assert_receive {:before_seal, _scope, first_generation, _pid, _at}, 200

    accept!(server, authority, thread_receipt!(authority, "Ev-gen-2", ts(2), text: "second"))
    assert_receive {:before_seal, _scope, second_generation, _pid, _at}, 200

    refute second_generation == first_generation

    bucket =
      eventually(fn ->
        case Bucketing.load(namespace, scope(authority)) do
          {:ok, %{"sealed_generations" => [_first, _second]} = bucket} -> bucket
          _incomplete -> false
        end
      end)

    assert Enum.map(bucket["sealed_generations"], & &1["generation"]) ==
             [first_generation, second_generation]

    assert Enum.map(bucket["sealed_generations"], fn sealed ->
             Enum.map(sealed["receipts"], & &1["event_id"])
           end) == [["Ev-gen-1"], ["Ev-gen-2"]]
  end

  test "a durable generation newer than stale local state still admits its receipt" do
    authority = authority!()
    namespace = "triage-recovery-newer-durable-#{System.unique_integer([:positive])}"

    stale = start_runtime(namespace, debounce_ms: 5_000, max_wait_ms: 10_000)
    sealing = start_seal_watch_runtime(namespace, debounce_ms: 0, max_wait_ms: 1)

    first = thread_receipt!(authority, "Ev-newer-A", ts(1), text: "first generation")
    accept!(stale, authority, first)
    accept!(sealing, authority, first, :duplicate)
    assert_receive {:before_seal, _scope, sealed_generation, _pid, _at}, 300

    # `stale` still holds the sealed generation locally. The next receipt lands
    # in the durable successor generation, and the stale local view is rebuilt
    # from it instead of being treated as a stale recovery.
    second = thread_receipt!(authority, "Ev-newer-B", ts(2), text: "second generation")
    accept!(stale, authority, second)

    local = :sys.get_state(stale).buckets[scope(authority)]
    refute local.generation == sealed_generation
    assert Enum.map(local.receipts, & &1["event_id"]) == ["Ev-newer-B"]
  end

  test "an overdue open fence converges to one authoritative timeout terminal" do
    authority = authority!()
    namespace = "triage-overdue-fence-#{System.unique_integer([:positive])}"
    scope = scope(authority)
    generation = ULID.generate()
    receipt = thread_receipt!(authority, "Ev-overdue", ts(1), text: "left open by a crash")

    seed_sealed_generation!(namespace, scope, generation, [receipt])
    fence_key = seed_open_fence!(namespace, scope, generation, receipt)

    runtime = start_runtime(namespace, recovery_idle_ms: 50)

    assert [%{"authoritative" => true, "status" => "failed"} = run] =
             eventually(fn -> Triage.ledger_records(runtime) end)

    assert run["decision"] == %{
             "action" => "silence",
             "reason" => "identity_diagnostic_interrupted_before_transport"
           }

    assert {:ok, %{"terminal" => %{"status" => "failed"}}} = CasRecord.get(fence_key)
    assert {:ok, ^run} = Triage.replay(runtime, run["run_id"])
  end

  test "ledger listing and replay read canonical durable records in a fresh runtime", ctx do
    %{server: server, authority: authority, namespace: namespace} = ctx

    admit!(server, authority, "Ev-durable", text: "persist this run")
    assert [run] = eventually(fn -> Triage.ledger_records(server) end)

    fresh = start_runtime(namespace)
    assert Triage.ledger_records(fresh) == [run]
    assert {:ok, ^run} = Triage.replay(fresh, run["run_id"])
  end

  test "two runtimes admitting the same receipt produce one fenced run" do
    authority = authority!()
    namespace = "triage-race-#{System.unique_integer([:positive])}"
    opts = [debounce_ms: 30, max_wait_ms: 60, evaluation_timeout_ms: 200]

    left = start_runtime(namespace, opts)
    right = start_runtime(namespace, opts)

    receipt = receipt!(authority, "Ev-race", text: "race the fence")
    accept!(left, authority, receipt)
    accept!(right, authority, receipt, :duplicate)

    assert [%{"authoritative" => true}] = eventually(fn -> Triage.ledger_records(left) end)
    Process.sleep(120)
    assert length(Triage.ledger_records(left)) == 1
  end

  test "overlapping local views seal one durable membership without duplicate receipts" do
    authority = authority!()
    namespace = "triage-overlap-#{System.unique_integer([:positive])}"
    opts = [debounce_ms: 50, max_wait_ms: 100, evaluation_timeout_ms: 300]

    left = start_runtime(namespace, opts)
    right = start_runtime(namespace, opts)

    a = thread_receipt!(authority, "Ev-overlap-A", ts(1), text: "A")
    b = thread_receipt!(authority, "Ev-overlap-B", ts(2), text: "B")

    while_runtimes_suspended([left, right], fn ->
      accept!(left, authority, a)
      accept!(right, authority, a, :duplicate)
      accept!(right, authority, b)
    end)

    assert [run] = eventually(fn -> Triage.ledger_records(left) end)

    assert run["input_receipt_refs"] == ["receipt://run/r001", "receipt://run/r002"]
    assert length(Enum.uniq(run["input_receipt_refs"])) == 2

    assert {:ok, %{"sealed_generations" => [sealed]}} =
             Bucketing.load(namespace, scope(authority))

    assert Enum.map(sealed["receipts"], & &1["receipt_ref"]) ==
             [a["receipt_ref"], b["receipt_ref"]]

    Process.sleep(120)
    assert length(Triage.ledger_records(left)) == 1
  end

  test "durable predecessor terminal serializes generations across runtimes" do
    authority = authority!()
    namespace = "triage-predecessor-#{System.unique_integer([:positive])}"
    scope = scope(authority)
    predecessor = ULID.generate()

    first = thread_receipt!(authority, "Ev-predecessor-A", ts(1), text: "A")
    seed_sealed_generation!(namespace, scope, predecessor, [first])
    predecessor_key = seed_open_fence!(namespace, scope, predecessor, first, deadline_ms: 60_000)

    # A successor generation must not fence while its predecessor has no
    # authoritative terminal.
    server = start_seal_watch_runtime(namespace, debounce_ms: 0, max_wait_ms: 1)
    second = thread_receipt!(authority, "Ev-predecessor-C", ts(2), text: "C")
    accept!(server, authority, second)

    assert_receive {:before_seal, ^scope, successor, _pid, _at}, 300
    Process.sleep(120)

    successor_key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, successor)
    assert {:error, :not_found} = CasRecord.get(successor_key)
    assert Triage.ledger_records(server) == []

    # Settling the predecessor releases the successor.
    assert {:ok, _terminal} =
             CasRecord.update(
               predecessor_key,
               &Map.put(&1, "terminal", %{
                 "terminal_id" => ULID.generate(),
                 "status" => "skipped_timeout",
                 "decision" => %{"action" => "silence"},
                 "evaluator" => %{},
                 "settled_at" => System.system_time(:millisecond)
               }),
               create: false
             )

    assert eventually(fn -> match?({:ok, _fence}, CasRecord.get(successor_key)) end)
  end

  test "cross-runtime append extends the durable trailing deadline for one generation" do
    authority = authority!()
    namespace = "triage-durable-due-#{System.unique_integer([:positive])}"
    opts = [debounce_ms: 120, max_wait_ms: 500]

    left = start_seal_watch_runtime(namespace, opts)
    right = start_seal_watch_runtime(namespace, opts)

    accept!(left, authority, thread_receipt!(authority, "Ev-durable-due-A", ts(1), text: "A"))
    Process.sleep(80)

    b_started = System.monotonic_time(:millisecond)
    accept!(right, authority, thread_receipt!(authority, "Ev-durable-due-B", ts(2), text: "B"))

    # `left` only knows A locally, so its trailing wake fires early; the durable
    # seal CAS reads B's later deadline and aborts that attempt, and only the
    # next attempt — at the extended durable deadline — may seal. Either
    # Runtime may win that attempt, so observe both instead of requiring left
    # to remain the winner after the cross-runtime append.
    assert_receive {:before_seal, _scope, generation, _pid, _early}, 200
    assert_receive {:before_seal, _scope, ^generation, _pid, fired}, 400
    assert fired - b_started >= 100

    assert eventually(fn ->
             sealed_event_ids(namespace, scope(authority)) ==
               ["Ev-durable-due-A", "Ev-durable-due-B"]
           end)
  end

  test "a receipt appended between due read and seal CAS extends the durable deadline" do
    authority = authority!()
    namespace = "triage-due-seal-race-#{System.unique_integer([:positive])}"
    test_pid = self()
    gate = start_supervised!({Agent, fn -> false end}, id: make_ref())

    before_seal = fn scope, generation ->
      first? = Agent.get_and_update(gate, fn blocked? -> {not blocked?, true} end)

      if first? do
        send(test_pid, {:before_seal, scope, generation, self(), 0})

        receive do
          {:release_seal, ^scope, ^generation} -> :ok
        after
          1_000 -> raise "seal barrier was not released"
        end
      end
    end

    opts = [debounce_ms: 120, max_wait_ms: 500]
    left = start_runtime(namespace, Keyword.put(opts, :before_seal_hook, before_seal))
    right = start_runtime(namespace, opts)

    accept!(left, authority, thread_receipt!(authority, "Ev-due-seal-A", ts(1), text: "A"))
    assert_receive {:before_seal, scope, generation, blocked_runtime, _at}, 400

    b_started = System.monotonic_time(:millisecond)
    accept!(right, authority, thread_receipt!(authority, "Ev-due-seal-B", ts(2), text: "B"))
    send(blocked_runtime, {:release_seal, scope, generation})

    assert eventually(fn ->
             sealed_event_ids(namespace, scope) == ["Ev-due-seal-A", "Ev-due-seal-B"] || false
           end)

    assert System.monotonic_time(:millisecond) - b_started >= 100
  end

  test "callback aliases for one Slack source message project once", ctx do
    %{server: server, authority: authority, namespace: namespace} = ctx

    first = thread_receipt!(authority, "Ev-alias-1", ts(5), text: "same source")
    alias_copy = thread_receipt!(authority, "Ev-alias-2", ts(5), text: "same source")

    assert first["source_message_ref"] == alias_copy["source_message_ref"]
    accept!(server, authority, first)
    accept!(server, authority, alias_copy, :duplicate)

    assert [run] = eventually(fn -> Triage.ledger_records(server) end)
    assert run["input_receipt_refs"] == ["receipt://run/r001"]

    assert {:ok, %{"sealed_generations" => [sealed]}} =
             Bucketing.load(namespace, scope(authority))

    assert Enum.map(sealed["receipts"], & &1["receipt_ref"]) == [first["receipt_ref"]]
    assert Enum.map(sealed["receipts"], &get_in(&1, ["triage_event", "message_ts"])) == [ts(5)]
  end

  test "ledger list surfaces durable storage errors instead of an empty ledger", ctx do
    %{server: server, namespace: namespace} = ctx
    prefix = SalixStore.TriageKeys.ctl_im_triage_ledger_runs_prefix(namespace)
    S3.Fake.set_fault({:fail, 503, :list, prefix})
    assert {:error, _reason} = Triage.ledger_records(server)
  end

  test "a stale wake cannot seal the next durable generation early" do
    authority = authority!()
    namespace = "triage-stale-generation-#{System.unique_integer([:positive])}"
    opts = [debounce_ms: 120, max_wait_ms: 500]

    left = start_seal_watch_runtime(namespace, opts)
    stale = start_runtime(namespace, opts)

    a = thread_receipt!(authority, "Ev-stale-A", ts(1), text: "A")
    accept!(left, authority, a)
    accept!(stale, authority, a, :duplicate)

    :ok = :sys.suspend(stale)

    on_exit(fn ->
      if Process.alive?(stale) do
        try do
          :sys.resume(stale)
        catch
          _kind, _reason -> :ok
        end
      end
    end)

    assert_receive {:before_seal, _scope, _generation, _pid, _at}, 400
    assert eventually(fn -> sealed_event_ids(namespace, scope(authority)) == ["Ev-stale-A"] end)

    c = thread_receipt!(authority, "Ev-stale-C", ts(2), text: "C")
    c_started = System.monotonic_time(:millisecond)
    accept!(left, authority, c)
    :ok = :sys.resume(stale)

    refute_receive {:before_seal, _scope, _generation, _pid, _at}, 80
    assert_receive {:before_seal, _scope, _generation, _pid, c_fired}, 200
    assert c_fired - c_started >= 100

    assert eventually(fn ->
             match?(
               {:ok, %{"sealed_generations" => [_first, _second]}},
               Bucketing.load(namespace, scope(authority))
             )
           end)
  end

  test "every sealed generation converges after a transient fence failure" do
    authority = authority!()
    namespace = "triage-seal-converge-#{System.unique_integer([:positive])}"
    scope = scope(authority)

    server =
      start_seal_watch_runtime(namespace,
        debounce_ms: 0,
        max_wait_ms: 1,
        recovery_idle_ms: 50
      )

    a = thread_receipt!(authority, "Ev-seal-A", ts(1), text: "A")

    # Block only the first generation's fence so its seal lands durably while
    # its run never fences. The recovery bucket lane must converge it later.
    :ok =
      S3.Fake.blackhole(
        {:fail, 503, :put, SalixStore.TriageKeys.ctl_im_triage_bucket_seals_prefix(namespace)}
      )

    accept!(server, authority, a)
    assert_receive {:before_seal, ^scope, generation_a, _pid, _at}, 400

    assert eventually(fn ->
             match?({:ok, %{"sealed_generations" => [_ | _]}}, Bucketing.load(namespace, scope))
           end)

    :ok = S3.Fake.clear_blackhole()
    c = thread_receipt!(authority, "Ev-seal-C", ts(2), text: "C")
    accept!(server, authority, c)

    runs =
      eventually(fn ->
        case Triage.ledger_records(server) do
          [_first, _second] = records -> records
          _incomplete -> []
        end
      end)

    assert length(runs) == 2

    assert {:ok, %{"generation" => ^generation_a}} =
             Bucketing.load_sealed_generation(namespace, scope, generation_a)
  end

  test "a terminal fence left before ledger projection folds into the canonical run" do
    namespace = "triage-terminal-fold-#{System.unique_integer([:positive])}"
    scope = "generation-1:T1:C1:100.001"
    run_id = seed_terminal_fence!(namespace, scope, "fold-generation")

    runtime = start_runtime(namespace, recovery_idle_ms: 50)

    assert [%{"run_id" => ^run_id, "authoritative" => true} = run] =
             eventually(fn -> Triage.ledger_records(runtime) end)

    assert {:ok, ^run} = Triage.replay(runtime, run_id)
  end

  test "ambiguous create acknowledgements settle by exact durable readback" do
    authority = authority!()
    namespace = "triage-ambiguous-#{System.unique_integer([:positive])}"
    scope = scope(authority)

    receipt_key = Keys.ctl_im_slack_event_receipt(authority["connect_id"], "Ev-ambiguous-receipt")
    S3.Fake.set_fault({:ambiguous_after, :put, receipt_key})
    receipt = receipt!(authority, "Ev-ambiguous-receipt", text: "receipt ambiguity")

    server = start_seal_watch_runtime(namespace, debounce_ms: 40, max_wait_ms: 100)

    projection_key =
      SalixStore.TriageKeys.ctl_im_triage_projection_marker(namespace, receipt["receipt_ref"])

    S3.Fake.set_fault({:ambiguous_after, :put, projection_key})
    accept!(server, authority, receipt)

    assert_receive {:before_seal, ^scope, generation, _pid, _at}, 400

    S3.Fake.set_fault(
      {:ambiguous_after, :put,
       SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)}
    )

    assert [%{"authoritative" => true}] = eventually(fn -> Triage.ledger_records(server) end)
  end

  test "admission never waits on the engine mailbox and still arms the receipt", ctx do
    %{server: server, authority: authority} = ctx
    receipt = receipt!(authority, "Ev-async-admission", text: "admit without waiting")

    # A suspended GenServer handles system messages only, which is exactly what
    # the engine looks like from ingress while it is several seconds deep in one
    # evaluation inside handle_info.
    :sys.suspend(server)

    admission = Task.async(fn -> Runtime.accept_current(server, authority, receipt) end)
    assert {:ok, :accepted} = Task.await(admission, 2_000)

    :sys.resume(server)

    # The arming cast is not lost: the receipt still reaches a durable run.
    assert [%{"authoritative" => true}] = eventually(fn -> Triage.ledger_records(server) end)
  end

  test "a deterministic seal refusal parks the scope instead of retrying forever", ctx do
    %{authority: authority, namespace: namespace} = ctx
    parked_namespace = namespace <> "-parked"
    scope_key = scope(authority)
    bucket_key = SalixStore.TriageKeys.ctl_im_triage_bucket(parked_namespace, scope_key)
    test_pid = self()

    # Corrupt the durable bucket immediately before every seal CAS, so the seal
    # refuses deterministically with `:invalid_triage_bucket` — the shape that
    # no amount of retrying can turn into a sealed generation.
    hook = fn _scope, generation ->
      send(test_pid, {:seal_attempt, generation})

      {:ok, _corrupted} =
        CasRecord.update(
          bucket_key,
          fn _current -> %{"schema" => "comma.not-a-triage-bucket"} end,
          create: false
        )

      :ok
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        server =
          start_runtime(parked_namespace,
            debounce_ms: 0,
            max_wait_ms: 0,
            before_seal_hook: hook
          )

        receipt = receipt!(authority, "Ev-seal-refusal", text: "park this scope")
        accept!(server, authority, receipt)

        assert_receive {:seal_attempt, generation}, 2_000

        # The refusal is terminal for this generation: no further seal attempt
        # may be scheduled, so the process is never starved by a hot retry loop.
        assert eventually(fn ->
                 state = :sys.get_state(server)

                 state.flush_schedules == %{} and
                   match?(
                     %{generation: ^generation, reason: :invalid_triage_bucket},
                     state.parked_seals[scope_key]
                   )
               end)

        refute_receive {:seal_attempt, _generation}, 500

        state = :sys.get_state(server)
        assert state.flush_schedules == %{}

        assert %{generation: ^generation, reason: :invalid_triage_bucket} =
                 state.parked_seals[scope_key]
      end)

    assert log =~ "triage seal refused"
  end

  # Three unrelated outcomes used to collapse into one silent `state`: the
  # engine being off, a sealed generation this build can never project, and a
  # predecessor gate that has not answered yet. The deterministic middle case is
  # parked and said out loud instead of looking like a bucket that is only slow.
  test "a sealed generation with no projectable input is parked, not silently dropped", ctx do
    %{authority: authority, namespace: namespace} = ctx
    parked_namespace = namespace <> "-unprojectable"
    scope_key = scope(authority)
    generation = ULID.generate()

    # A sealed generation whose receipt list is empty: `Pipeline.build_input/1`
    # refuses it deterministically, and no retry can change that.
    bucket = %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => scope_key,
      "sealed_generations" => [
        %{
          "generation" => generation,
          "receipts" => [],
          "sealed_at" => System.system_time(:millisecond)
        }
      ]
    }

    assert {:ok, _created} =
             CasRecord.create(
               SalixStore.TriageKeys.ctl_im_triage_bucket(parked_namespace, scope_key),
               bucket
             )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        server = start_runtime(parked_namespace, recovery_idle_ms: 20)

        assert eventually(fn ->
                 :sys.get_state(server).parked_inputs[scope_key] == generation
               end)
      end)

    assert log =~ "triage sealed generation cannot be projected"
  end

  # Every storage failure used to inject a fresh `:converge_triage_recovery`
  # into the mailbox, and that message re-schedules itself forever — so N
  # failures left N permanent recovery chains racing each other.
  test "repeated fence-storage failures leave exactly one recovery chain", ctx do
    %{authority: authority, namespace: namespace} = ctx
    chain_namespace = namespace <> "-chain"

    :ok =
      S3.Fake.blackhole(
        {:fail, 503, :put,
         {:prefix, SalixStore.TriageKeys.ctl_im_triage_bucket_seals_prefix(chain_namespace)}}
      )

    server = start_runtime(chain_namespace, debounce_ms: 0, max_wait_ms: 0, recovery_idle_ms: 20)

    receipt = receipt!(authority, "Ev-recovery-chain", text: "fail the fence write")
    accept!(server, authority, receipt)

    # Let the fence create fail repeatedly through both the flush path and the
    # recovery lane.
    Process.sleep(300)

    # Suspended, the process arms no new timers, so every timer currently armed
    # delivers into the mailbox and nothing consumes it. One chain means exactly
    # one message.
    :sys.suspend(server)
    Process.sleep(250)
    {:messages, messages} = Process.info(server, :messages)
    state = :sys.get_state(server)
    :sys.resume(server)

    # The chain may now be waiting on its one background reader when suspended.
    # It owns either a page/application or a timer, never both or parallel pages.
    ticks = Enum.count(messages, &match?({:converge_triage_recovery, _}, &1))
    assert ticks <= 1
    assert is_nil(state.recovery_work) != is_nil(state.recovery_schedule)
  end

  # An identity run's fence handle is its ONLY capability, and the only place it
  # can travel is a port's options. A bare module atom has none, so it used to
  # be passed through unchanged and the adapter ran with no handle at all —
  # every fence-gated step then refused and the run read as an adapter bug
  # rather than the composition error it was.
  test "a port that cannot carry the identity fence handle refuses the run", ctx do
    %{authority: authority, namespace: namespace} = ctx

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        server =
          start_runtime(namespace <> "-uncarryable",
            debounce_ms: 0,
            max_wait_ms: 0,
            evaluator_port: ForbiddenEvaluator
          )

        receipt = receipt!(authority, "Ev-uncarryable-port", text: "no capability can travel")
        accept!(server, authority, receipt)

        # The refusal happens before any worker starts, so the forbidden
        # evaluator is never reached at all.
        refute_receive :evaluator_called, 300
      end)

    assert log =~ "cannot carry an identity fence handle"
  end

  # A message this process cannot route is not authority. Crashing on it would
  # restart the runtime and drop every armed timer and live fence with it.
  test "an unroutable message is ignored instead of restarting the runtime", ctx do
    %{namespace: namespace} = ctx
    server = start_runtime(namespace <> "-stray", mode: :off, evaluator_port: nil)
    before = :sys.get_state(server)

    send(server, {:definitely_not_a_triage_message, make_ref()})
    send(server, :also_not_one)

    assert :sys.get_state(server) == before
    assert Process.alive?(server)
  end

  ## Helpers

  defp start_runtime(namespace, overrides \\ []) do
    defaults = [
      name: nil,
      mode: :review,
      namespace: namespace,
      recovery_idle_ms: 200,
      evaluator_port: {ForbiddenEvaluator, []}
    ]

    start_supervised!(
      {Runtime, Keyword.merge(defaults, overrides)},
      id: make_ref()
    )
  end

  # The seal hook is the engine's only synchronous observation point once the
  # evaluator seam is dark: it fires inside the Runtime immediately before the
  # generation seal CAS.
  defp start_seal_watch_runtime(namespace, overrides) do
    test_pid = self()

    hook = fn scope, generation ->
      send(
        test_pid,
        {:before_seal, scope, generation, self(), System.monotonic_time(:millisecond)}
      )
    end

    start_runtime(namespace, Keyword.put(overrides, :before_seal_hook, hook))
  end

  defp while_runtimes_suspended(runtimes, fun) do
    # Admission writes durable membership outside the Runtime mailbox. Queue the
    # complete test batch before either Runtime can seal it, so this fixture
    # proves membership rather than depending on the host scheduler beating a
    # short production-style debounce window.
    Enum.each(runtimes, &:sys.suspend/1)

    try do
      fun.()
    after
      Enum.each(runtimes, &:sys.resume/1)
    end
  end

  defp attach_phase_handler(phase, test_pid) do
    handler = "triage-#{phase}-context-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:salix, :triage, :phase, :stop],
        fn _event, _measurements, metadata, pid ->
          if metadata.phase == phase do
            send(
              pid,
              {:triage_phase_context, OpenTelemetry.Tracer.current_span_ctx(),
               SystemsObservability.Context.current_surface()}
            )
          end
        end,
        test_pid
      )

    handler
  end

  defp collect_triage_phases(acc) do
    receive do
      {:triage_phase, %{duration: duration}, metadata} when is_integer(duration) ->
        collect_triage_phases([metadata | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp sealed_event_ids(namespace, scope) do
    case Bucketing.load(namespace, scope) do
      {:ok, %{"sealed_generations" => [_ | _] = sealed}} ->
        sealed
        |> List.last()
        |> Map.fetch!("receipts")
        |> Enum.map(& &1["event_id"])

      _not_sealed ->
        []
    end
  end

  defp seed_sealed_generation!(namespace, scope, generation, receipts) do
    bucket = %{
      "schema" => "comma.triage-durable-bucket.v1",
      "bucket_scope" => scope,
      "open_generation" => ULID.generate(),
      "open_first_at" => nil,
      "open_last_at" => nil,
      "open_fast_path" => false,
      "open_receipts" => [],
      "sealed_generations" => [
        %{
          "generation" => generation,
          "receipts" => receipts,
          "sealed_at" => System.system_time(:millisecond)
        }
      ]
    }

    assert {:ok, ^bucket} =
             CasRecord.create(
               SalixStore.TriageKeys.ctl_im_triage_bucket(namespace, scope),
               bucket
             )

    bucket
  end

  defp seed_open_fence!(namespace, scope, generation, receipt, opts \\ []) do
    now = System.system_time(:millisecond)
    deadline_at = now + Keyword.get(opts, :deadline_ms, -1_000)
    event = receipt["triage_event"]

    input = %{
      "schema" => "comma.triage-input-snapshot.v2",
      "generation" => generation,
      "events" => [event],
      "receipt_refs" => [receipt["receipt_ref"]],
      "source_authority" => %{
        "connect_id" => receipt["connect_id"],
        "connect_generation" => event["connect_generation"],
        "workspace_id" => event["bucket"]["workspace_id"],
        "channel_id" => event["bucket"]["channel_id"],
        "thread_ts" => event["bucket"]["thread_ts"]
      },
      "source_mode" => "callback"
    }

    assert {:ok, {:won, created}} =
             SalixIM.Triage.RunFence.create(
               namespace,
               scope,
               ULID.generate(),
               input,
               now - 2_000,
               deadline_at
             )

    created.key
  end

  defp seed_terminal_fence!(namespace, scope, generation) do
    run_id = ULID.generate()
    now = System.system_time(:millisecond)

    fence = %{
      "schema" => "comma.triage-bucket-fence.v1",
      "bucket_scope" => scope,
      "generation" => generation,
      "run_id" => run_id,
      "created_at" => now,
      "deadline_at" => now,
      "input_snapshot" => %{
        "schema" => "comma.triage-input-snapshot.v1",
        "generation" => generation,
        "events" => [],
        "receipt_refs" => ["s3://receipt/#{generation}"]
      },
      "terminal" => %{
        "terminal_id" => ULID.generate(),
        "status" => "evaluated",
        "decision" => %{"action" => "silence"},
        "evaluator" => %{"evaluator" => "seeded-v1"},
        "settled_at" => now
      }
    }

    key = SalixStore.TriageKeys.ctl_im_triage_bucket_seal(namespace, scope, generation)
    assert {:ok, ^fence} = CasRecord.create(key, fence)
    run_id
  end

  defp scope(authority) do
    Enum.join(
      [
        authority["connect_generation"],
        authority["workspace_id"],
        authority["approved_channel_id"],
        root_ts()
      ],
      ":"
    )
  end

  defp root_ts, do: "1787019000.000000"
  defp ts(n), do: "1787019000." <> String.pad_leading(Integer.to_string(n), 6, "0")
end
