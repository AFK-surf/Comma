defmodule SalixIM.TriageTest do
  require SystemsRuntime.Proc

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

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  import SalixIM.TriageEngineFixtures

  alias SalixIM.Triage
  alias SalixIM.Triage.{Bucketing, Runtime}
  alias SalixStore.{CasRecord, Keys, S3, ULID}

  defmodule ForbiddenEvaluator do
    @moduledoc false
    @behaviour SalixIM.Ports.TriageEvaluator

    @impl true
    def evaluate(_input, opts) do
      if pid = opts[:test_pid], do: SystemsRuntime.Proc.send(pid, :evaluator_called)
      {:error, :must_not_run}
    end
  end

  setup do
    previous_triage_backend = SystemsRuntime.get_env(:salix_store, :triage_record_backend)
    SystemsRuntime.put_env(:salix_store, :triage_record_backend, SalixStore.S3)
    S3.Fake.reset()
    S3.Fake.clear_blackhole()

    on_exit(fn ->
      S3.Fake.clear_blackhole()

      if previous_triage_backend do
        SystemsRuntime.put_env(:salix_store, :triage_record_backend, previous_triage_backend)
      else
        SystemsRuntime.delete_env(:salix_store, :triage_record_backend)
      end
    end)

    authority = authority!()
    namespace = "triage-test-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    server =
      start_runtime(namespace,
        debounce_ms: 15,
        max_wait_ms: 60,
        evaluation_timeout_ms: 100
      )

    %{server: server, authority: authority, namespace: namespace}
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
         lease_key:
           "ctl/test/triage-engine-ring/#{SystemsRuntime.Proc.unique_integer([:positive])}",
         lease_ttl_ms: 5_000},
        id: SystemsRuntime.Proc.make_ref()
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
    assert SystemsRuntime.Proc.alive?(recovery)
  end

  test "a fresh runtime rearms a bucket left by a stopped peer", ctx do
    %{authority: authority} = ctx
    namespace = "triage-projection-kill-#{SystemsRuntime.Proc.unique_integer([:positive])}"

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

  test "a receipt accepted after a seal enters the next durable generation" do
    authority = authority!()
    namespace = "triage-next-generation-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    server = start_seal_watch_runtime(namespace, debounce_ms: 0, max_wait_ms: 1)

    accept!(server, authority, thread_receipt!(authority, "Ev-gen-1", ts(1), text: "first"))
    settle_receive({:before_seal, _scope, first_generation, _pid, _at})
    accept!(server, authority, thread_receipt!(authority, "Ev-gen-2", ts(2), text: "second"))
    settle_receive({:before_seal, _scope, second_generation, _pid, _at})
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

  test "an overdue open fence converges to one authoritative timeout terminal" do
    authority = authority!()
    namespace = "triage-overdue-fence-#{SystemsRuntime.Proc.unique_integer([:positive])}"
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

  test "a draining runtime seals without a run fence and the recovery lane evaluates it later" do
    authority = authority!()
    namespace = "triage-draining-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    scope = scope(authority)

    draining =
      start_seal_watch_runtime(namespace,
        debounce_ms: 0,
        max_wait_ms: 1,
        restart: :temporary,
        draining?: fn -> true end
      )

    {generation, log} =
      ExUnit.CaptureLog.with_log(fn ->
        accept!(draining, authority, thread_receipt!(authority, "Ev-drain", ts(1), text: "drain"))
        settle_receive({:before_seal, ^scope, generation, _pid, _at})
        # The seal and the fence decision run in one Runtime message.
        _ = :sys.get_state(draining, :infinity)
        generation
      end)

    assert {:ok, %{"sealed_generations" => [%{"generation" => ^generation}]}} =
             Bucketing.load(namespace, scope)

    assert SalixIM.Triage.RunFence.generation_status(namespace, scope, generation) == :missing
    assert Triage.ledger_records(draining) == []
    assert :sys.get_state(draining, :infinity).active == %{}
    assert log =~ "triage evaluation deferred: node draining"

    :ok = GenServer.stop(draining)

    # A serving node's bucket recovery lane finds the fence-less sealed
    # generation and runs it; with the dark context port it settles as failed.
    serving = start_runtime(namespace, recovery_idle_ms: 50)

    assert [%{"authoritative" => true, "status" => "failed"} = run] =
             eventually(fn -> Triage.ledger_records(serving) end)

    assert run["input_receipt_refs"] == ["receipt://run/r001"]
    assert SalixIM.Triage.RunFence.generation_status(namespace, scope, generation) == :present
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
    namespace = "triage-race-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    opts = [debounce_ms: 30, max_wait_ms: 60, evaluation_timeout_ms: 200]

    left = start_runtime(namespace, opts)
    right = start_runtime(namespace, opts)

    receipt = receipt!(authority, "Ev-race", text: "race the fence")
    accept!(left, authority, receipt)
    accept!(right, authority, receipt, :duplicate)

    assert [%{"authoritative" => true}] = eventually(fn -> Triage.ledger_records(left) end)
    SystemsClock.sleep(120)
    assert length(Triage.ledger_records(left)) == 1
  end

  test "overlapping local views seal one durable membership without duplicate receipts" do
    authority = authority!()
    namespace = "triage-overlap-#{SystemsRuntime.Proc.unique_integer([:positive])}"
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

    SystemsClock.sleep(120)
    assert length(Triage.ledger_records(left)) == 1
  end

  test "durable predecessor terminal serializes generations across runtimes" do
    authority = authority!()
    namespace = "triage-predecessor-#{SystemsRuntime.Proc.unique_integer([:positive])}"
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

    settle_receive({:before_seal, ^scope, successor, _pid, _at})
    SystemsClock.sleep(120)

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
                 "settled_at" => SystemsClock.system_time(:millisecond)
               }),
               create: false
             )

    assert eventually(fn -> match?({:ok, _fence}, CasRecord.get(successor_key)) end)
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
      id: SystemsRuntime.Proc.make_ref()
    )
  end

  # The seal hook is the engine's only synchronous observation point once the
  # evaluator seam is dark: it fires inside the Runtime immediately before the
  # generation seal CAS.
  defp start_seal_watch_runtime(namespace, overrides) do
    test_pid = SystemsRuntime.Proc.self()

    hook = fn scope, generation ->
      SystemsRuntime.Proc.send(
        test_pid,
        {:before_seal, scope, generation, SystemsRuntime.Proc.self(),
         SystemsClock.monotonic_time(:millisecond)}
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
          "sealed_at" => SystemsClock.system_time(:millisecond)
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
    now = SystemsClock.system_time(:millisecond)
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
