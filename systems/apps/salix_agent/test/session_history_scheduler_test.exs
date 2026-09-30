defmodule SalixAgent.SessionHistorySchedulerTest do
  use ExUnit.Case, async: false
  alias SalixAgent.SessionHistory.{Scheduler, Worker}
  alias SalixStore.Ids

  setup do
    start_supervised!(Scheduler)
    a = Ids.new_agent_id(Ids.new_group_id(Ids.new_tenant_id()))
    b = Ids.new_agent_id(Ids.new_group_id(Ids.new_tenant_id()))
    %{a: a, b: b}
  end

  defp lane do
    spawn_link(fn -> loop() end)
  end

  defp loop do
    receive do
      {owner, :claim} ->
        send(owner, {self(), Scheduler.claim()})
        loop()

      {owner, :complete} ->
        send(owner, {self(), Scheduler.complete()})
        loop()

      {owner, {:maintenance, key}} ->
        send(owner, {self(), Scheduler.maintenance(key)})
        loop()

      :stop ->
        :ok
    end
  end

  defp call(pid, action) do
    send(pid, {self(), action})
    assert_receive {^pid, result}, 1000
    result
  end

  test "tenant cap reserves capacity for others and total cap includes all tenants", %{a: a, b: b} do
    [x, y, z, w, v] = lanes = for _ <- 1..5, do: lane()
    on_exit(fn -> for pid <- lanes, do: Process.exit(pid, :kill) end)
    for i <- 1..100, do: Worker.hint(a, "s#{i}")
    assert {^a, _} = call(x, :claim)
    assert {^a, _} = call(y, :claim)
    assert call(z, :claim) == nil
    Worker.hint(b, "quiet-1")
    Worker.hint(b, "quiet-2")
    assert call(z, :claim) == {b, "quiet-1"}
    assert call(w, :claim) == {b, "quiet-2"}
    c = Ids.new_agent_id(Ids.new_group_id(Ids.new_tenant_id()))
    Worker.hint(c, "third")
    assert call(v, :claim) == nil
    assert call(v, {:maintenance, {a, "archive"}}) == :busy
    call(x, :complete)
    assert call(v, :claim) == {c, "third"}
    for pid <- [y, z, w, v], do: call(pid, :complete)
  end

  test "same-session refresh stays serial even with spare tenant capacity", %{a: a} do
    x = lane()
    y = lane()
    on_exit(fn -> for pid <- [x, y], do: Process.exit(pid, :kill) end)
    Worker.hint(a, "s")
    assert call(x, :claim) == {a, "s"}
    for _ <- 1..50, do: Worker.hint(a, "s")
    assert call(y, :claim) == nil
    Worker.hint(a, "other")
    assert call(y, :claim) == {a, "other"}
    call(y, :complete)
    assert call(y, :claim) == nil
    call(x, :complete)
    assert call(y, :claim) == {a, "s"}
    call(y, :complete)
    assert call(x, :claim) == nil
  end

  test "maintenance occupies a tenant slot and excludes its active session", %{a: a} do
    [x, y, z] = lanes = for _ <- 1..3, do: lane()
    on_exit(fn -> for pid <- lanes, do: Process.exit(pid, :kill) end)
    assert call(x, {:maintenance, {a, "archive"}}) == :ok
    Worker.hint(a, "archive")
    Worker.hint(a, "recent-1")
    Worker.hint(a, "recent-2")
    assert call(y, :claim) == {a, "recent-1"}
    assert call(z, :claim) == nil
    call(y, :complete)
    assert call(z, :claim) == {a, "recent-2"}
    call(z, :complete)
    assert call(y, :claim) == nil
    call(x, :complete)
    assert call(y, :claim) == {a, "archive"}
    call(y, :complete)
  end

  test "tenant turns and recent priority apply after completion", %{a: a, b: b} do
    x = lane()
    on_exit(fn -> Process.exit(x, :kill) end)
    Worker.hint(a, "a1")
    Worker.hint(a, "a2")
    assert call(x, :claim) == {a, "a1"}
    call(x, :complete)
    Worker.hint(b, "b1")
    assert call(x, {:maintenance, {a, "old"}}) == :busy
    assert call(x, :claim) == {b, "b1"}
    call(x, :complete)
    assert call(x, :claim) == {a, "a2"}
    call(x, :complete)
    assert call(x, {:maintenance, {a, "old"}}) == :ok
    assert call(x, :claim) == nil
    call(x, :complete)
  end

  test "a dead consumer releases its session and preserves a refresh", %{a: a} do
    x = lane()
    Worker.hint(a, "s")
    assert call(x, :claim) == {a, "s"}
    Process.unlink(x)
    ref = Process.monitor(x)
    Process.exit(x, :kill)
    assert_receive {:DOWN, ^ref, :process, ^x, _}
    # Wait for the scheduler to process its own DOWN signal.
    await_claim({a, "s"}, System.monotonic_time(:millisecond) + 1000)
    assert Scheduler.complete() == :ok
  end

  defp await_claim(key, deadline) do
    case Scheduler.claim() do
      ^key ->
        :ok

      nil ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(5)
        await_claim(key, deadline)
    end
  end
end
