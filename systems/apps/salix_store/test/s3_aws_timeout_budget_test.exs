defmodule SalixStore.S3.AWSTimeoutBudgetTest do
  @moduledoc """
  The adapter latency bound behind the 2026-08-17 staging write-stall: the
  REMOTE I/O STAGES of one store call (checkout, connect, send, receive) must
  reach a terminal state in bounded time. Per-attempt receive timeouts are
  tiered (fast for small operations, bulk for large transfers), and the
  whole-call retry budget stops new attempts once spent — so a stalled
  backend costs a caller seconds, not attempts x 30s. Local payload work is
  outside the promised bound (see SalixStore.S3.AWS moduledoc). Driven against real TCP
  sockets so the actual Finch receive-timeout path is exercised.
  """
  use ExUnit.Case, async: false

  alias SalixStore.S3.AWS

  setup do
    prev = Application.get_all_env(:salix_store)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, backlog: 16])

    {:ok, port} = :inet.port(listener)

    Application.put_env(:salix_store, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_store, :s3_bucket, "timeout-test")

    on_exit(fn ->
      :gen_tcp.close(listener)
      # put_all_env cannot delete keys absent from the snapshot, so the keys
      # this test introduces are removed explicitly.
      Application.delete_env(:salix_store, :s3_timeouts)
      Application.put_all_env([{:salix_store, prev}])
    end)

    {:ok, listener: listener}
  end

  # A listener that is never accepted from: connects succeed (kernel backlog)
  # but no byte of response ever arrives — the receive-timeout stall shape,
  # NOT the connection-refused/closed shape.
  test "a stalled backend resolves a small call at the fast timeout tier, not 30s per attempt" do
    Application.put_env(:salix_store, :s3_timeouts, fast_recv_ms: 200, budget_ms: 60_000)

    {elapsed_ms, result} = timed(fn -> AWS.get("stall/get", []) end)

    # All four attempts (initial + 3 transient retries) time out at the fast
    # tier: ~4 x 200ms + backoffs. The old shape was 4 x 30s.
    assert {:error, _reason} = result
    assert elapsed_ms >= 200
    assert elapsed_ms < 3_000
  end

  test "the whole-call budget clamps even the first attempt and stops retries once spent" do
    # A 1ms budget clamps attempt 1's own deadline: the call resolves in
    # milliseconds, not one full receive timeout.
    Application.put_env(:salix_store, :s3_timeouts, fast_recv_ms: 500, budget_ms: 1)
    {one_attempt_ms, {:error, _}} = timed(fn -> AWS.get("stall/budget", []) end)

    # A generous budget lets all four attempts run.
    Application.put_env(:salix_store, :s3_timeouts, fast_recv_ms: 500, budget_ms: 60_000)
    {all_attempts_ms, {:error, _}} = timed(fn -> AWS.get("stall/budget", []) end)

    assert one_attempt_ms < 300
    assert all_attempts_ms > 1_800
  end

  test "the budget hard-bounds the remote stages: fast_recv 300 / budget 350 resolves near 350ms" do
    # The review repro for the soft-budget bug: with a 300ms receive timeout
    # and a 350ms budget, the old shape let attempt 2 run its full receive
    # timeout past the budget (~610ms+ total). Hard-threading the remaining
    # budget through each attempt clamps attempt 2 to the ~40ms remainder.
    Application.put_env(:salix_store, :s3_timeouts, fast_recv_ms: 300, budget_ms: 350)

    {elapsed_ms, {:error, _}} = timed(fn -> AWS.get("stall/endtoend", []) end)

    assert elapsed_ms >= 300
    assert elapsed_ms < 450
  end

  test "a wedged upload (accepted but never read) is ended by the budget", %{listener: listener} do
    # The server accepts the connection and then never reads a byte, so the
    # request-body send blocks once the socket buffers fill. Finch's
    # request_timeout starts only AFTER the body is sent and receive_timeout
    # never engages, so only the outer cancellable attempt deadline can end
    # this call — the exact shape of the incident's stalled write.
    Application.put_env(:salix_store, :s3_timeouts, fast_recv_ms: 10_000, budget_ms: 400)

    acceptor = start_black_hole_server(listener)

    body = :binary.copy(<<0>>, 4 * 1024 * 1024)
    {elapsed_ms, result} = timed(fn -> AWS.put("wedged/put", body, []) end)

    assert {:error, {:ambiguous, _}} = result
    assert elapsed_ms >= 400
    assert elapsed_ms < 1_500

    stop_server(acceptor)
  end

  test "config.json storage.timeouts reaches the adapter end to end" do
    # The release-config seam and the adapter must agree on shape: apply
    # ConfigJson's own output to the application env and prove the configured
    # fast timeout governs a real stalled call. A key drift between the two
    # would silently revert operators' overrides to defaults — the gap this
    # seam exists to close.
    env =
      SalixStore.ConfigJson.app_env(%{
        "storage" => %{"timeouts" => %{"fast_recv_ms" => 200, "budget_ms" => 60_000}}
      })

    assert {app, key, value} = Enum.find(env, fn {_a, k, _v} -> k == :s3_timeouts end)
    Application.put_env(app, key, value)

    {elapsed_ms, {:error, _}} = timed(fn -> AWS.get("config/e2e", []) end)

    # ~4 x 200ms + backoffs under the configured value; the 10s default tier
    # would take 40s+.
    assert elapsed_ms >= 200
    assert elapsed_ms < 3_000
  end

  test "a saturated pool still honors the budget, and the pool recovers" do
    # Wedge more concurrent calls than the Finch pool has connections
    # (size 50): 50 occupy connections against an accepting-but-silent
    # server, the rest queue in pool checkout. Every caller — wedged or
    # queued — must resolve within the outer budget (never the 5s checkout
    # exception path), and afterwards the pool must serve a healthy request:
    # killed callers' connections are discarded by Finch's caller-death
    # monitoring, not leaked back into the pool.
    {:ok, wedge_listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, backlog: 128])

    {:ok, wedge_port} = :inet.port(wedge_listener)
    Application.put_env(:salix_store, :s3_endpoint, "http://127.0.0.1:#{wedge_port}")
    Application.put_env(:salix_store, :s3_timeouts, fast_recv_ms: 5_000, budget_ms: 700)

    results =
      1..60
      |> Enum.map(fn i ->
        Task.async(fn -> timed(fn -> AWS.get("saturate/#{i}", []) end) end)
      end)
      |> Task.await_many(30_000)

    for {elapsed_ms, result} <- results do
      assert {:error, _} = result
      assert elapsed_ms < 4_000
    end

    # Recovery on the SAME origin — Finch keys pools by {scheme, host, port},
    # so only a same-port healthy request proves the wedged pool's connections
    # were discarded rather than leaked or poisoned. The very listener that
    # black-holed the salvo now starts serving: its acceptor drains the
    # backlog of dead sockets (closed when Finch discarded each killed
    # caller's connection) and then answers the fresh request.
    Application.put_env(:salix_store, :s3_timeouts, fast_recv_ms: 5_000, budget_ms: 10_000)
    acceptor = start_slow_server(wedge_listener, delay_ms: 10)

    assert {:ok, %{etag: _}} = AWS.multipart_upload_part("saturate/after", "upload-1", 1, "x")

    stop_server(acceptor)
    :gen_tcp.close(wedge_listener)
  end

  test "S3 stages stay bounded regardless of payload size or shape" do
    # Contract scope (see SalixStore.S3.AWS moduledoc): the budget bounds the
    # S3 stages — signing, checkout, connect, send, receive — while LOCAL
    # payload preparation is deliberately outside it. This pins the part that
    # is promised: whatever the body's size or shape, the remote interaction
    # against a black-holed endpoint resolves at ~budget rather than running
    # a full receive-timeout per attempt.
    Application.put_env(:salix_store, :s3_timeouts, fast_recv_ms: 10_000, budget_ms: 300)

    bodies = [
      {"binary", :binary.copy(<<0>>, 32 * 1024 * 1024)},
      {"iodata", List.duplicate(:binary.copy(<<0>>, 1024 * 1024), 32)}
    ]

    for {shape, body} <- bodies do
      {prep_ms, _} = timed(fn -> :crypto.hash(:sha256, body) end)
      {elapsed_ms, result} = timed(fn -> AWS.put("bounded/#{shape}", body, []) end)

      assert {:error, {:ambiguous, _}} = result

      # The S3 stages must not add a receive-timeout-sized wait on top of
      # whatever the payload itself costs. Generous slack keeps this a
      # contract assertion, not a machine-speed race.
      assert elapsed_ms < prep_ms + 3_000,
             "#{shape}: call took #{elapsed_ms}ms with payload work measured at #{prep_ms}ms"
    end
  end

  test "a trickling response cannot outlive the budget", %{listener: listener} do
    # Chunks arrive every 100ms — well inside the 300ms receive (idle) timeout,
    # so the idle timeout alone would NEVER fire and the old shape hung for as
    # long as the server kept dripping. The per-attempt complete-response
    # deadline (remaining budget) is what must end this call.
    Application.put_env(:salix_store, :s3_timeouts, fast_recv_ms: 300, budget_ms: 800)

    acceptor = start_trickle_server(listener, chunk_every_ms: 100)

    {elapsed_ms, {:error, _}} = timed(fn -> AWS.get("trickle/get", []) end)

    assert elapsed_ms >= 700
    assert elapsed_ms < 2_500

    stop_server(acceptor)
  end

  test "large transfers keep the bulk window while small calls fail fast", %{listener: listener} do
    Application.put_env(:salix_store, :s3_timeouts, fast_recv_ms: 100, bulk_recv_ms: 5_000)

    # Every connection: consume the request, hold it past the fast tier, then
    # answer 200 — slow but healthy, exactly what the bulk tier must tolerate
    # and the fast tier must not wait for.
    acceptor = start_slow_server(listener, delay_ms: 400)

    assert {:ok, %{etag: _}} = AWS.multipart_upload_part("bulk/part", "upload-1", 1, "chunk")
    assert {:error, _} = AWS.get("bulk/get", [])

    stop_server(acceptor)
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  # The acceptors own nothing the test must wait on; connections they hold
  # are dropped when the test closes the listener.
  defp start_slow_server(listener, delay_ms: delay_ms),
    do: spawn_link(fn -> accept_loop(listener, &slow_handler(&1, delay_ms)) end)

  defp start_trickle_server(listener, chunk_every_ms: chunk_every_ms),
    do: spawn_link(fn -> accept_loop(listener, &trickle_handler(&1, chunk_every_ms)) end)

  # Accepts, then neither reads nor writes: an upload black hole.
  defp start_black_hole_server(listener),
    do: spawn_link(fn -> accept_loop(listener, fn _socket -> Process.sleep(60_000) end) end)

  defp stop_server(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  defp accept_loop(listener, handler_fun) do
    case :gen_tcp.accept(listener, 30_000) do
      {:ok, socket} ->
        handler = spawn(fn -> handler_fun.(socket) end)
        :ok = :gen_tcp.controlling_process(socket, handler)
        accept_loop(listener, handler_fun)

      {:error, _} ->
        :ok
    end
  end

  defp slow_handler(socket, delay_ms) do
    _ = drain_request(socket)
    Process.sleep(delay_ms)

    _ =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\netag: \"part-etag\"\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
      )

    :gen_tcp.close(socket)
  end

  # Sends valid headers, then drips the body one byte at a time forever —
  # each chunk resets an idle-based receive timeout, so only a
  # complete-response deadline ends the request.
  defp trickle_handler(socket, chunk_every_ms) do
    _ = drain_request(socket)

    _ =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\netag: \"trickle\"\r\ncontent-length: 100000\r\n\r\n"
      )

    trickle_body(socket, chunk_every_ms)
  end

  defp trickle_body(socket, chunk_every_ms) do
    Process.sleep(chunk_every_ms)

    case :gen_tcp.send(socket, "x") do
      :ok -> trickle_body(socket, chunk_every_ms)
      {:error, _} -> :gen_tcp.close(socket)
    end
  end

  # Read the full request: headers, then content-length bytes of body.
  defp drain_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data

        case String.split(acc, "\r\n\r\n", parts: 2) do
          [headers, body] ->
            expected = content_length(headers)

            if byte_size(body) >= expected,
              do: acc,
              else: drain_request(socket, acc)

          [_incomplete] ->
            drain_request(socket, acc)
        end

      {:error, _} ->
        acc
    end
  end

  defp content_length(headers) do
    case Regex.run(~r/^content-length:\s*(\d+)\r?$/im, headers) do
      [_, len] -> String.to_integer(len)
      nil -> 0
    end
  end
end
