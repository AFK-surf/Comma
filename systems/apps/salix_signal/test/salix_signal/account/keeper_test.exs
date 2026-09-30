defmodule SalixSignal.Account.KeeperTest do
  # The ring keeper scans the account table at start, after each cluster
  # membership change, and on one periodic chain. A membership change adds
  # one pass; it must not start another periodic chain, or rolling restarts
  # multiply full account-table scans on every surviving node.
  use ExUnit.Case, async: false

  alias SalixSignal.Account.Keeper

  @interval_ms 300

  test "membership changes add one pass each and keep one periodic chain" do
    test = self()

    pid =
      start_supervised!(
        {Keeper,
         interval_ms: @interval_ms,
         membership_delay_ms: 1,
         reconcile: fn -> send(test, {:pass, System.monotonic_time(:microsecond)}) end}
      )

    assert_receive {:pass, _}

    for event <- [:nodeup, :nodedown, :nodeup] do
      send(pid, {event, :"peer@keeper-test", [node_type: :visible]})
      assert_receive {:pass, _}
    end

    # Let the membership passes finish, then measure only periodic passes.
    Process.sleep(div(@interval_ms, 2))
    flush_passes()

    times = for _ <- 1..5, do: next_pass()
    gaps = times |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

    # One chain: each pass follows the previous one by at least the interval.
    # Several chains interleave and leave shorter gaps.
    assert Enum.all?(gaps, &(&1 >= (@interval_ms - 1) * 1_000)),
           "periodic pass gaps in microseconds: #{inspect(gaps)}"
  end

  defp next_pass do
    assert_receive {:pass, at}, 5_000
    at
  end

  defp flush_passes do
    receive do
      {:pass, _} -> flush_passes()
    after
      0 -> :ok
    end
  end
end
