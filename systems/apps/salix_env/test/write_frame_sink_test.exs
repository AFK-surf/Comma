defmodule SalixEnv.WriteFrameSinkTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SystemsClock.Test, scope: ["Elixir.SalixStore", "Elixir.SalixEnv"]
  alias SalixEnv.{Transfer, WriteFrameSink}

  test "caller death aborts the remote write and retires an unclaimed sink" do
    test = SystemsRuntime.Proc.self()

    owner =
      SystemsRuntime.Proc.spawn(fn ->
        SystemsRuntime.Proc.receive do
          {:env_write_stream_abort, "stream-caller", reason} ->
            SystemsRuntime.Proc.send(test, {:write_stream_aborted, reason})
        end
      end)

    caller = SystemsRuntime.Proc.spawn(fn -> SystemsClock.sleep(:infinity) end)

    {:ok, sink} =
      WriteFrameSink.start(owner, "stream-caller", 5_000,
        caller: caller,
        absolute_timeout_ms: 5_000
      )

    url = WriteFrameSink.url(sink)
    monitor = SystemsRuntime.Proc.monitor(sink)
    SystemsRuntime.Proc.exit(caller, :kill)

    settle_receive({:write_stream_aborted, {:remote_write_stream_caller_down, :killed}})
    settle_receive({:DOWN, ^monitor, :process, ^sink, reason})
    assert reason in [:normal, :noproc]
    assert {:error, {404, _}} = Transfer.send_bytes(url, "late")
  end
end
