defmodule SalixStore.Convergence.WorkerTest do
  @moduledoc """
  The periodic convergence driver's cadence contract: the implementation's
  `reconcile_ms/0` must be honored on a cold BEAM (module not yet loaded)
  and across restarts (schedule against the durable marker's remaining
  deadline, never a whole new interval).
  """
  use ExUnit.Case, async: false

  alias SalixStore.{CasDirectory, Convergence, S3}
  alias SalixStore.Convergence.Worker

  alias SalixStore.{
    ConvergenceWorkerBlockingImpl,
    ConvergenceWorkerColdImpl,
    ConvergenceWorkerFastImpl
  }

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    Convergence.reset_converged_cache(ConvergenceWorkerBlockingImpl)
    Convergence.reset_converged_cache(ConvergenceWorkerColdImpl)
    Convergence.reset_converged_cache(ConvergenceWorkerFastImpl)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
    :ok
  end

  defp attach_telemetry! do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:salix, :store, :convergence],
      fn _event, measurements, metadata, _config ->
        send(parent, {:convergence, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  # Simulate a fresh BEAM: the consumer's .beam is on the code path
  # (test/support compiles to _build) but the module is not loaded.
  defp unload!(mod) do
    :code.delete(mod)
    :code.purge(mod)
    refute :erlang.function_exported(mod, :reconcile_ms, 0)
    on_exit(fn -> _ = Code.ensure_loaded(mod) end)
  end

  test "a cold (unloaded) consumer's reconcile_ms is honored, not the default" do
    unload!(ConvergenceWorkerColdImpl)

    # The resolution itself must load the module first — function_exported?
    # alone would silently pin the 1-hour default.
    assert Convergence.impl_reconcile_ms(ConvergenceWorkerColdImpl) == 40

    # And a Worker booted against the cold module pins the same interval.
    unload!(ConvergenceWorkerColdImpl)

    pid =
      start_supervised!(
        {Worker,
         impl: ConvergenceWorkerColdImpl, boot_jitter_ms: 0, jitter_ms: 0, partial_delay_ms: 1}
      )

    assert :sys.get_state(pid).reconcile_ms == 40
  end

  test "a restarted worker schedules against the marker's remaining deadline, not a fresh interval" do
    ref = attach_telemetry!()

    # A completed pass stamps the durable marker...
    assert {:ok, :complete} = Convergence.ensure(ConvergenceWorkerFastImpl)
    assert_receive {:convergence, ^ref, _boot_measurements, %{outcome: "ok"}}

    # ...which is already 1800ms into its 2000ms interval when the node
    # restarts (age the marker in place).
    marker_key = ConvergenceWorkerFastImpl.marker_key()
    {:ok, %{body: body}} = S3.get(marker_key)
    marker = Jason.decode!(body)
    aged = Map.put(marker, "completed_at", marker["completed_at"] - 1_800)
    {:ok, _} = S3.put(marker_key, Jason.encode!(aged))

    # A record that landed while the node was down.
    late = %{"id" => "late"}

    {:ok, _} =
      S3.put(
        ConvergenceWorkerFastImpl.source_prefix() <> "late.json",
        Jason.encode!(late)
      )

    start_supervised!(
      {Worker,
       impl: ConvergenceWorkerFastImpl, boot_jitter_ms: 0, jitter_ms: 0, partial_delay_ms: 1}
    )

    # The boot ensure no-ops on the fresh marker; the next pass must run at
    # the marker's REMAINING ~200ms — not a whole new 2000ms interval (the
    # restart-stretch repro: repeated restarts would defer healing forever).
    # The 1000ms receive window admits scheduler noise while staying far
    # under the full interval a reset-from-now schedule would take.
    assert_receive {:convergence, ^ref, _measurements,
                    %{name: "test_worker_fast", outcome: "ok"}},
                   1_000

    assert {:ok, ^late} = CasDirectory.get("ctl/test_worker_fast_dir.json", "late")
  end

  # Drain gate requests (each record's callback blocks once) until the pass
  # completes, releasing every blocked callback immediately.
  defp release_until_ok(ref) do
    receive do
      {:blocked, pid} ->
        send(pid, :release)
        release_until_ok(ref)

      {:convergence, ^ref, _measurements, %{name: "test_worker_blocking", outcome: "ok"}} ->
        :ok
    after
      1_500 -> flunk("pass did not complete within the scheduling window")
    end
  end

  test "slow pass: uninterrupted and restarted workers schedule from the same completion anchor" do
    ref = attach_telemetry!()
    Process.register(self(), :convergence_blocking_gate)
    on_exit(fn -> _ = Process.whereis(:convergence_blocking_gate) end)

    prefix = ConvergenceWorkerBlockingImpl.source_prefix()
    {:ok, _} = S3.put(prefix <> "seed.json", Jason.encode!(%{"id" => "seed"}))

    start_supervised!(
      {Worker,
       impl: ConvergenceWorkerBlockingImpl, boot_jitter_ms: 0, jitter_ms: 0, partial_delay_ms: 1}
    )

    # The boot pass starts and BLOCKS — a pass slower than the 600ms
    # interval. Under a pre-pass anchor the marker would already be
    # "expired" at completion.
    assert_receive {:blocked, callback}, 1_000
    Process.sleep(700)
    send(callback, :release)

    assert_receive {:convergence, ^ref, _m1, %{name: "test_worker_blocking", outcome: "ok"}},
                   1_000

    # UNINTERRUPTED: fixed-delay anchors the next pass at the completion
    # that just happened — nothing may run for ~600ms (a pre-pass anchor
    # would fire immediately), then the next pass arrives on schedule.
    refute_receive {:blocked, _}, 400
    release_until_ok(ref)

    # RESTARTED at the same durable state (marker just completed): the boot
    # ensure reads the same anchor and makes the SAME decision — quiet for
    # the remaining interval, then a pass.
    :ok = stop_supervised({Worker, ConvergenceWorkerBlockingImpl})

    start_supervised!(
      {Worker,
       impl: ConvergenceWorkerBlockingImpl, boot_jitter_ms: 0, jitter_ms: 0, partial_delay_ms: 1}
    )

    refute_receive {:blocked, _}, 400
    release_until_ok(ref)
  end

  test "slow completion persistence: both paths reschedule from the persisted anchor" do
    ref = attach_telemetry!()
    Process.register(self(), :convergence_blocking_gate)

    prefix = ConvergenceWorkerBlockingImpl.source_prefix()
    {:ok, _} = S3.put(prefix <> "seed.json", Jason.encode!(%{"id" => "seed"}))

    # The completion-marker PUT itself takes longer than the 600ms interval:
    # completed_at (sampled before the write settles) is already expired by
    # the time ensure returns.
    marker_key = ConvergenceWorkerBlockingImpl.marker_key()
    SalixStore.S3.Fake.set_fault({:delay, 800, :put, marker_key})

    start_supervised!(
      {Worker,
       impl: ConvergenceWorkerBlockingImpl, boot_jitter_ms: 0, jitter_ms: 0, partial_delay_ms: 1}
    )

    assert_receive {:blocked, callback}, 1_000
    send(callback, :release)

    assert_receive {:convergence, ^ref, _m1, %{name: "test_worker_blocking", outcome: "ok"}},
                   2_000

    # UNINTERRUPTED: rescheduling from the persisted anchor means the
    # already-elapsed completion I/O counts — the next pass must start
    # promptly (a "wait a whole interval from return" schedule stays quiet
    # for 600ms; a restarted Worker at this same marker would run in ~25ms).
    assert_receive {:blocked, callback2}, 400
    send(callback2, :release)
    release_until_ok(ref)

    # RESTARTED at the same durable state (fresh completion, fast persist
    # this time): the boot ensure derives the SAME decision — quiet for the
    # remaining interval, then a pass on schedule.
    :ok = stop_supervised({Worker, ConvergenceWorkerBlockingImpl})

    start_supervised!(
      {Worker,
       impl: ConvergenceWorkerBlockingImpl, boot_jitter_ms: 0, jitter_ms: 0, partial_delay_ms: 1}
    )

    refute_receive {:blocked, _}, 400
    release_until_ok(ref)
  end
end
