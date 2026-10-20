defmodule SalixAgent.StreamProgressTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.StreamProgress

  test "the owner reads what a dead writer had recorded" do
    progress = StreamProgress.new()
    assert StreamProgress.snapshot(progress) == nil

    owner = SystemsRuntime.Proc.self()

    {:ok, writer} =
      SystemsRuntime.Task.start(fn ->
        StreamProgress.install(progress)
        StreamProgress.begin_attempt(1)
        StreamProgress.observe_body(120, 200)
        StreamProgress.observe_body(80, 200)
        StreamProgress.observe_content()
        SystemsRuntime.Proc.send(owner, :written)
        SystemsRuntime.Proc.sleep(:infinity)
      end)

    assert_receive :written
    SystemsRuntime.Proc.exit(writer, :kill)

    assert %{
             attempt: 1,
             in_flight: true,
             received_bytes: 200,
             received_chunks: 2,
             http_status: 200,
             content_deltas: 1
           } = snapshot = StreamProgress.snapshot(progress)

    assert is_integer(snapshot.first_body_ms) and snapshot.first_body_ms >= 0
    assert snapshot.last_body_ms >= snapshot.first_body_ms
    assert is_integer(snapshot.first_content_ms)
    assert snapshot.elapsed_ms >= snapshot.last_body_ms
    assert snapshot.attempt_started_at_ms <= SystemsClock.system_time(:millisecond)
  end
end
