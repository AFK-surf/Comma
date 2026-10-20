defmodule SalixStore.S3.AWSTimeoutBudgetTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The adapter latency bound behind the 2026-08-17 staging write-stall: the
  REMOTE I/O STAGES of one store call (checkout, connect, send, receive) must
  reach a terminal state in bounded time. Per-attempt receive timeouts are
  tiered (fast for small operations, bulk for large transfers), and the
  whole-call retry budget stops new attempts once spent — so a stalled
  backend costs a caller seconds, not attempts x 30s. Local payload work is
  outside the promised bound (see SalixStore.S3.AWS moduledoc). Driven against real TCP
  sockets so the actual Finch receive-timeout path is exercised.

  Only lower bounds are read from the wall clock. That a call ends within
  its bounds is asserted on the limits each attempt runs under (the
  `[:salix_store, :s3, :attempt]` event), not on how long the call took: on
  a loaded machine the scheduler can add any amount to that.
  """
  use SystemsClock.Case, async: false

  alias SalixStore.S3.AWS

  setup do
    prev = Application.get_all_env(:salix_store)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, backlog: 16])

    {:ok, port} = :inet.port(listener)

    SystemsRuntime.put_env(:salix_store, :s3_endpoint, "http://127.0.0.1:#{port}")
    SystemsRuntime.put_env(:salix_store, :s3_bucket, "timeout-test")

    on_exit(fn ->
      :gen_tcp.close(listener)
      # put_all_env cannot delete keys absent from the snapshot, so the keys
      # this test introduces are removed explicitly.
      SystemsRuntime.delete_env(:salix_store, :s3_timeouts)
      Application.put_all_env([{:salix_store, prev}])
    end)

    {:ok, listener: listener}
  end

  test "the budget hard-bounds the remote stages: fast_recv 300 / budget 350 resolves near 350ms" do
    # The review repro for the soft-budget bug: with a 300ms receive timeout
    # and a 350ms budget, the old shape let attempt 2 run its full receive
    # timeout past the budget (~610ms+ total). Hard-threading the remaining
    # budget through each attempt clamps attempt 2 to the ~40ms remainder.
    SystemsRuntime.put_env(:salix_store, :s3_timeouts, fast_recv_ms: 300, budget_ms: 350)

    {elapsed_ms, {:error, _}, attempts} = attempts(fn -> AWS.get("stall/endtoend", []) end)

    assert elapsed_ms >= 300
    assert [%{remaining_ms: first} | _] = attempts

    # Every attempt runs under the remainder of the one 350ms deadline, so
    # attempt 2 gets what attempt 1 left, never another full 300ms.
    remainders = Enum.map(attempts, & &1.remaining_ms)
    assert first <= 350
    assert remainders == Enum.sort(remainders, :desc)
    assert Enum.all?(attempts, &(&1.receive_timeout_ms == min(300, &1.remaining_ms)))
  end

  test "a wedged upload (accepted but never read) is ended by the budget", %{listener: listener} do
    # The server accepts the connection and then never reads a byte, so the
    # request-body send blocks once the socket buffers fill. Finch's
    # request_timeout starts only AFTER the body is sent and receive_timeout
    # never engages, so only the outer cancellable attempt deadline can end
    # this call — the exact shape of the incident's stalled write.
    SystemsRuntime.put_env(:salix_store, :s3_timeouts, fast_recv_ms: 10_000, budget_ms: 400)

    acceptor = start_black_hole_server(listener)

    body = :binary.copy(<<0>>, 4 * 1024 * 1024)
    {elapsed_ms, result, attempts} = attempts(fn -> AWS.put("wedged/put", body, []) end)

    assert {:error, {:ambiguous, _}} = result
    assert elapsed_ms >= 400
    assert attempts != []
    assert Enum.all?(attempts, &(&1.remaining_ms <= 400))

    stop_server(acceptor)
  end

  # Runs `fun` and returns the wall time it took (read only for lower
  # bounds), its result, and the limits of every attempt it made, in order.
  defp attempts(fun) do
    test = SystemsRuntime.Proc.self()
    handler = "s3-attempts-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:salix_store, :s3, :attempt],
        fn _event, measurements, _metadata, _config ->
          SystemsRuntime.Proc.send(test, {handler, measurements})
        end,
        nil
      )

    try do
      started = System.monotonic_time(:millisecond)
      result = fun.()
      {System.monotonic_time(:millisecond) - started, result, collect(handler, [])}
    after
      SystemsRuntime.Telemetry.detach(handler)
    end
  end

  defp collect(handler, acc) do
    SystemsRuntime.Proc.receive do
      {^handler, measurements} -> collect(handler, [measurements | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Accepts, then neither reads nor writes: an upload black hole.
  defp start_black_hole_server(listener),
    do:
      SystemsRuntime.Proc.spawn_link(fn ->
        accept_loop(listener, fn _socket -> SystemsRuntime.Proc.sleep(60_000) end)
      end)

  defp stop_server(pid) do
    ref = SystemsRuntime.Proc.monitor(pid)
    SystemsRuntime.Proc.unlink(pid)
    SystemsRuntime.Proc.exit(pid, :kill)

    SystemsRuntime.Proc.receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp accept_loop(listener, handler_fun) do
    case :gen_tcp.accept(listener, 30_000) do
      {:ok, socket} ->
        handler = SystemsRuntime.Proc.spawn_link(fn -> handler_fun.(socket) end)
        :ok = :gen_tcp.controlling_process(socket, handler)
        accept_loop(listener, handler_fun)

      {:error, _} ->
        :ok
    end
  end
end
