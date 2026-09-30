defmodule SalixAgent.StreamProgressTest do
  use ExUnit.Case, async: true

  alias SalixAgent.StreamProgress

  test "the owner reads what a dead writer had recorded" do
    progress = StreamProgress.new()
    assert StreamProgress.snapshot(progress) == nil

    owner = self()

    {:ok, writer} =
      Task.start(fn ->
        StreamProgress.install(progress)
        StreamProgress.begin_attempt(1)
        StreamProgress.observe_body(120, 200)
        StreamProgress.observe_body(80, 200)
        StreamProgress.observe_content()
        send(owner, :written)
        Process.sleep(:infinity)
      end)

    assert_receive :written
    Process.exit(writer, :kill)

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
    assert snapshot.attempt_started_at_ms <= System.system_time(:millisecond)
  end

  test "a new attempt clears the previous attempt's counters" do
    progress = StreamProgress.new()
    StreamProgress.install(progress)

    StreamProgress.begin_attempt(1)
    StreamProgress.observe_body(10, 503)
    StreamProgress.observe_content()

    StreamProgress.begin_attempt(2)

    assert %{
             attempt: 2,
             first_body_ms: nil,
             last_body_ms: nil,
             received_bytes: nil,
             received_chunks: nil,
             http_status: nil,
             first_content_ms: nil,
             last_content_ms: nil,
             content_deltas: 0
           } = StreamProgress.snapshot(progress)

    StreamProgress.install(nil)
  end

  test "an attempt stays in flight until it settles, and the next attempt reopens it" do
    progress = StreamProgress.new()
    StreamProgress.install(progress)

    StreamProgress.begin_attempt(1)
    StreamProgress.observe_content()
    assert %{attempt: 1, in_flight: true} = StreamProgress.snapshot(progress)

    StreamProgress.settle()
    assert %{attempt: 1, in_flight: false, content_deltas: 1} = StreamProgress.snapshot(progress)

    StreamProgress.begin_attempt(2)
    assert %{attempt: 2, in_flight: true} = StreamProgress.snapshot(progress)

    StreamProgress.install(nil)
  end

  test "writers are no-ops without an installed array, and snapshot rejects other terms" do
    StreamProgress.install(nil)
    assert StreamProgress.current() == nil
    assert :ok = StreamProgress.begin_attempt(1)
    assert :ok = StreamProgress.observe_body(5, 200)
    assert :ok = StreamProgress.observe_content()
    assert :ok = StreamProgress.settle()
    assert StreamProgress.snapshot(nil) == nil
    assert StreamProgress.snapshot(make_ref()) == nil
    assert StreamProgress.snapshot(%{}) == nil
  end
end
