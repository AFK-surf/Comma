defmodule SalixStore.Convergence.WorkerTest do
  @moduledoc """
  The periodic convergence driver's cadence contract: the implementation's
  `reconcile_ms/0` must be honored on a cold BEAM (module not yet loaded)
  and across restarts (schedule against the durable marker's remaining
  deadline, never a whole new interval).
  """
  use SystemsClock.Case, async: false
  require SystemsClock

  use SystemsClock.Test, scope: ["Elixir.SalixStore"]
  alias SalixStore.{CasDirectory, Convergence, S3}
  alias SalixStore.Convergence.Worker

  alias SalixStore.{
    ConvergenceWorkerBlockingImpl,
    ConvergenceWorkerColdImpl,
    ConvergenceWorkerFastImpl
  }

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    Convergence.reset_converged_cache(ConvergenceWorkerBlockingImpl)
    Convergence.reset_converged_cache(ConvergenceWorkerColdImpl)
    Convergence.reset_converged_cache(ConvergenceWorkerFastImpl)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)
    :ok
  end

  defp attach_telemetry! do
    ref = SystemsRuntime.Proc.make_ref()
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.Telemetry.attach(
      {__MODULE__, ref},
      [:salix, :store, :convergence],
      fn _event, measurements, metadata, _config ->
        SystemsRuntime.Proc.send(parent, {:convergence, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> SystemsRuntime.Telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  test "a restarted worker schedules against the marker's remaining deadline, not a fresh interval" do
    ref = attach_telemetry!()

    # A completed pass stamps the durable marker...
    assert {:ok, :complete} = Convergence.ensure(ConvergenceWorkerFastImpl)
    settle_receive({:convergence, ^ref, _boot_measurements, %{outcome: "ok"}})
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
    settle_receive(
      {:convergence, ^ref, _measurements, %{name: "test_worker_fast", outcome: "ok"}}
    )

    assert {:ok, ^late} = CasDirectory.get("ctl/test_worker_fast_dir.json", "late")
  end
end
