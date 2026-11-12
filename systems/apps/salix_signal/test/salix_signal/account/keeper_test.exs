defmodule SalixSignal.Account.KeeperTest do
  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixSignal"]

  alias SalixSignal.Account.Keeper

  # A ring change (a peer becoming ready, a node draining) moves account
  # owners like a node joining or leaving does: one pass after the delay.
  test "a ring change adds one reconcile pass after the membership delay" do
    parent = SystemsRuntime.Proc.self()

    start_supervised!(
      {Keeper,
       interval_ms: 60_000,
       membership_delay_ms: 50,
       reconcile: fn -> SystemsRuntime.Proc.send(parent, :reconciled) end}
    )

    settle_receive(:reconciled)

    :ok = Keeper.ring_changed()
    :ok = Keeper.ring_changed()
    settle_refute_receive(:reconciled, 20)
    SystemsClock.sleep(50)
    settle_receive(:reconciled)
    settle_refute_receive(:reconciled, 100)
  end
end
