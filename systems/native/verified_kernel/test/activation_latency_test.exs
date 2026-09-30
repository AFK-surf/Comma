Code.require_file("support/activation_fixture.exs", __DIR__)

defmodule SalixVerifiedKernel.ActivationLatencyTest do
  use ExUnit.Case, async: false
  alias SalixVerifiedKernel.Session
  alias SalixVerifiedKernel.Test.ActivationFixture, as: Fixture

  test "materialization replay preserves protected result refs and the original handle" do
    initial = Fixture.build("agent", "session", messages: 80, refs: 20, padding: 100)
    queued = Fixture.apply_events(initial, [Fixture.queue_event("session")])
    before = Session.export(queued)
    {events, true, _hwm} = Session.query(queued, :materialize_pending_input_events, 100)
    projected = Fixture.apply_events(queued, events)
    assert Session.get(projected, :queue_ack_id) == 1
    assert Session.get(projected, :async_result_refs) == before.async_result_refs
    assert Session.export(queued) == before
    assert Session.export(Fixture.apply_events(queued, events)) == Session.export(projected)
  end

  @tag :activation_latency
  @tag timeout: 120_000
  test "long-history activation kernel work alone fits the 500 ms budget" do
    initial = Fixture.build("agent", "session")
    assert byte_size(Session.persist(initial)) >= 15_000_000
    queued = Fixture.apply_events(initial, [Fixture.queue_event("session")])

    # Lower bound only: the real actor also repairs, configures, authorizes,
    # builds its prompt, and writes the encoded snapshot. No LLM or IFC here.
    {us, timings} =
      :timer.tc(fn ->
        {query_us, {events, true, hwm}} =
          :timer.tc(fn -> Session.query(queued, :materialize_pending_input_events, 100) end)

        {project_us, _projected} =
          :timer.tc(fn ->
            Fixture.apply_events(queued, events ++ [%{"type" => "bump_hwm", "hwm" => hwm}])
          end)

        {replay_us, replayed} =
          :timer.tc(fn ->
            Fixture.apply_events(
              queued,
              events ++
                [
                  %{"type" => "bump_hwm", "hwm" => hwm},
                  %{"type" => "status", "session_id" => "session", "status" => "active"}
                ]
            )
          end)

        {normalize_us, {:ok, prepared}} =
          :timer.tc(fn -> Session.lifecycle(replayed, :prepare_write) end)

        {persist_us, _bytes} = :timer.tc(fn -> Session.persist(prepared) end)

        %{
          materialize: query_us / 1000,
          project: project_us / 1000,
          replay: replay_us / 1000,
          prepare_write: normalize_us / 1000,
          persist: persist_us / 1000
        }
      end)

    IO.inspect(timings, label: "activation kernel stages (ms)")

    assert us <= 500_000,
           "activation kernel lower bound #{us / 1000} ms exceeds 500 ms: #{inspect(timings)}"
  end
end
