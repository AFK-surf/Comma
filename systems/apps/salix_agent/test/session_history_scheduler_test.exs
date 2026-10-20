defmodule SalixAgent.SessionHistorySchedulerTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  alias SalixAgent.SessionHistory.{Scheduler, Worker}
  alias SalixStore.Ids

  setup do
    start_supervised!(Scheduler)
    a = Ids.new_agent_id(Ids.new_group_id(Ids.new_tenant_id()))
    b = Ids.new_agent_id(Ids.new_group_id(Ids.new_tenant_id()))
    %{a: a, b: b}
  end

  defp lane do
    SystemsRuntime.Proc.spawn_link(fn -> loop() end)
  end

  defp loop do
    SystemsRuntime.Proc.receive do
      {owner, :claim} ->
        SystemsRuntime.Proc.send(owner, {SystemsRuntime.Proc.self(), Scheduler.claim()})
        loop()

      {owner, :complete} ->
        SystemsRuntime.Proc.send(owner, {SystemsRuntime.Proc.self(), Scheduler.complete()})
        loop()

      {owner, {:maintenance, key}} ->
        SystemsRuntime.Proc.send(owner, {SystemsRuntime.Proc.self(), Scheduler.maintenance(key)})
        loop()

      :stop ->
        :ok
    end
  end

  defp call(pid, action) do
    SystemsRuntime.Proc.send(pid, {SystemsRuntime.Proc.self(), action})
    assert_receive {^pid, result}
    result
  end

  test "tenant cap reserves capacity for others and total cap includes all tenants", %{a: a, b: b} do
    [x, y, z, w, v] = lanes = for _ <- 1..5, do: lane()
    on_exit(fn -> for pid <- lanes, do: SystemsRuntime.Proc.exit(pid, :kill) end)
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
end
