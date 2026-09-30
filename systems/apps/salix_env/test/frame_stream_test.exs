defmodule SalixEnv.FrameStreamTest do
  use ExUnit.Case, async: true

  alias SalixEnv.FrameStream

  test "completed streams stop their receiver processes" do
    receivers =
      for index <- 1..25 do
        {:ok, receiver} = FrameStream.start_link(max_buffered_chunks: 2, idle_timeout: 1_000)
        monitor = Process.monitor(receiver)
        assert :ok = FrameStream.chunk(receiver, "chunk-#{index}")
        assert :ok = FrameStream.eof(receiver)
        assert Enum.to_list(FrameStream.stream(receiver)) == ["chunk-#{index}"]
        assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}, 200
        receiver
      end

    refute Enum.any?(receivers, &Process.alive?/1)
  end

  test "an abandoned buffered stream expires its receiver and data" do
    {:ok, receiver} = FrameStream.start_link(max_buffered_chunks: 2, idle_timeout: 20)
    monitor = Process.monitor(receiver)
    assert :ok = FrameStream.chunk(receiver, "abandoned")
    assert_receive {:DOWN, ^monitor, :process, ^receiver, :normal}, 200
  end

  test "idle expiry releases a blocked producer" do
    {:ok, receiver} = FrameStream.start_link(max_buffered_chunks: 1, idle_timeout: 20)
    assert :ok = FrameStream.chunk(receiver, "buffered")
    producer = Task.async(fn -> FrameStream.chunk(receiver, "blocked", 500) end)
    assert Task.await(producer, 500) == {:error, :stream_idle_timeout}
    refute Process.alive?(receiver)
  end
end
