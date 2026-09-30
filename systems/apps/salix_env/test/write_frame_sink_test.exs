defmodule SalixEnv.WriteFrameSinkTest do
  use ExUnit.Case, async: false

  alias SalixEnv.{Transfer, WriteFrameSink}

  test "owner phase timeout sends the exact write-stream cancel" do
    test = self()

    owner =
      spawn(fn ->
        receive do
          {:env_write_stream, :chunk, ref, from, id, "payload"} ->
            send(test, {:write_phase_started, ref, from, id})

            receive do
              {:env_write_stream_cancel, cancel_ref, cancel_from} ->
                send(test, {:write_phase_cancelled, cancel_ref, cancel_from})
            end
        end
      end)

    {:ok, sink} = WriteFrameSink.start(owner, "stream-1", 30)
    url = WriteFrameSink.url(sink)

    assert {:ok, %{"ok" => false, "error" => error}} = Transfer.send_bytes(url, "payload")
    assert error =~ "timeout"

    assert_receive {:write_phase_started, ref, from, "stream-1"}
    assert_receive {:write_phase_cancelled, ^ref, ^from}, 100
  end

  test "caller death aborts the remote write and retires an unclaimed sink" do
    test = self()

    owner =
      spawn(fn ->
        receive do
          {:env_write_stream_abort, "stream-caller", reason} ->
            send(test, {:write_stream_aborted, reason})
        end
      end)

    caller = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, sink} =
      WriteFrameSink.start(owner, "stream-caller", 5_000,
        caller: caller,
        absolute_timeout_ms: 5_000
      )

    url = WriteFrameSink.url(sink)
    monitor = Process.monitor(sink)
    Process.exit(caller, :kill)

    assert_receive {:write_stream_aborted, {:remote_write_stream_caller_down, :killed}}, 300
    assert_receive {:DOWN, ^monitor, :process, ^sink, reason}, 300
    assert reason in [:normal, :noproc]
    assert {:error, {404, _}} = Transfer.send_bytes(url, "late")
  end

  test "transfer handler death aborts the claimed remote write and retires the sink" do
    test = self()

    owner =
      spawn(fn ->
        receive do
          {:env_write_stream, :chunk, ref, from, "stream-handler", "payload"} ->
            send(from, {:env_write_stream_reply, ref, :ok})
            send(test, :write_handler_chunk_forwarded)

            receive do
              {:env_write_stream_abort, "stream-handler", reason} ->
                send(test, {:write_handler_stream_aborted, reason})
            end
        end
      end)

    {:ok, sink} =
      WriteFrameSink.start(owner, "stream-handler", 5_000, absolute_timeout_ms: 5_000)

    url = WriteFrameSink.url(sink)
    token = :sys.get_state(sink).token
    monitor = Process.monitor(sink)

    handler =
      spawn(fn ->
        send(sink, {:transfer_chunk, token, self(), "payload"})

        receive do
          {:transfer_ack, ^token} -> send(test, {:write_handler_claimed, self()})
        end

        receive do
          :disconnect -> exit(:client_disconnected)
        end
      end)

    assert_receive :write_handler_chunk_forwarded, 300
    assert_receive {:write_handler_claimed, ^handler}, 300
    send(handler, :disconnect)

    assert_receive {:write_handler_stream_aborted,
                    {:remote_write_stream_transfer_down, :client_disconnected}},
                   300

    assert_receive {:DOWN, ^monitor, :process, ^sink, :normal}, 300
    assert {:error, {404, _}} = Transfer.send_bytes(url, "late")
  end

  test "an abandoned remote write URL has an absolute abort deadline" do
    test = self()

    owner =
      spawn(fn ->
        receive do
          {:env_write_stream_abort, "stream-deadline", reason} ->
            send(test, {:write_stream_deadline_abort, reason})
        end
      end)

    {:ok, sink} =
      WriteFrameSink.start(owner, "stream-deadline", 5_000, absolute_timeout_ms: 30)

    monitor = Process.monitor(sink)

    assert_receive {:write_stream_deadline_abort, :remote_write_stream_absolute_timeout}, 300
    assert_receive {:DOWN, ^monitor, :process, ^sink, :normal}, 300
  end
end
