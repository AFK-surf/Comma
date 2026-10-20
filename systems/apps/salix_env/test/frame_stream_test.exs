defmodule SalixEnv.FrameStreamTest do
  use SystemsClock.Case, async: true

  alias SalixEnv.FrameStream

  test "completed streams stop their receiver processes" do
    receivers =
      for index <- 1..25 do
        {:ok, receiver} = FrameStream.start_link(max_buffered_chunks: 2, idle_timeout: 1_000)
        monitor = SystemsRuntime.Proc.monitor(receiver)
        assert :ok = FrameStream.chunk(receiver, "chunk-#{index}")
        assert :ok = FrameStream.eof(receiver)
        assert Enum.to_list(FrameStream.stream(receiver)) == ["chunk-#{index}"]
        assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}
        receiver
      end

    refute Enum.any?(receivers, &SystemsRuntime.Proc.alive?/1)
  end
end
