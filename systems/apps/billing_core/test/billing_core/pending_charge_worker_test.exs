defmodule BillingCore.Metering.PendingChargeWorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BillingCore.Metering.PendingChargeWorker

  test "a restarted worker resumes the persisted workset through run_once" do
    test_pid = self()

    run = fn opts ->
      send(test_pid, {:sweep, opts[:limit]})

      %{
        selected_count: 1,
        charged_count: 1,
        backed_off_count: 0,
        failed_count: 0,
        pending_count: 0,
        expired_count: 0
      }
    end

    first_name = unique_name()

    first =
      start_supervised!(
        Supervisor.child_spec(
          {PendingChargeWorker, name: first_name, run: run, limit: 7},
          id: first_name
        )
      )

    send(first, :run)
    assert_receive {:sweep, 7}
    GenServer.stop(first)

    second_name = unique_name()

    second =
      start_supervised!(
        Supervisor.child_spec(
          {PendingChargeWorker, name: second_name, run: run, limit: 7},
          id: second_name
        )
      )

    send(second, :run)
    assert_receive {:sweep, 7}
  end

  test "logs one finite warning per configured no-progress window" do
    run = fn _opts ->
      %{
        selected_count: 3,
        charged_count: 0,
        backed_off_count: 3,
        failed_count: 0,
        pending_count: 3,
        expired_count: 0
      }
    end

    worker =
      start_supervised!(
        {PendingChargeWorker,
         name: unique_name(), run: run, stuck_sweep_threshold: 2, interval_ms: :timer.hours(1)}
      )

    log =
      capture_log(fn ->
        send(worker, :run)
        refute_receive :never, 25
        send(worker, :run)
        refute_receive :never, 25
        send(worker, :run)
        refute_receive :never, 25
      end)

    assert length(Regex.scan(~r/backlog made no progress/, log)) == 1
  end

  test "disabled worker emits a bounded startup warning and never sweeps" do
    test_pid = self()

    log =
      capture_log(fn ->
        _worker =
          start_supervised!(
            {PendingChargeWorker,
             name: unique_name(), enabled: false, run: fn _ -> send(test_pid, :swept) end}
          )

        refute_receive :swept, 25
      end)

    assert log =~ "billing pending charge worker disabled"
  end

  defp unique_name,
    do: String.to_atom("pending_charge_worker_#{System.unique_integer([:positive])}")
end
