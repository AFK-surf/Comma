defmodule SalixEnv.TransferTest do
  @moduledoc """
  Cross-node transfer covers one-time tokens, byte delivery
  to the owner, the completion envelope, and TTL expiry. Exercises the real
  Bandit listener started by the app.
  """
  use SystemsClock.Case, async: false

  alias SalixEnv.Transfer
  alias SalixEnv.Transfer.StreamReceiver
  alias SalixEnv.Transfer.Tokens

  test "registered token streams bytes to the owner and returns a completion envelope" do
    {:ok, receiver} = StreamReceiver.start_link()
    {_token, url, stream} = StreamReceiver.register!(receiver)
    payload = SystemsRuntime.Proc.random_bytes(2048)
    consumer = SystemsRuntime.Task.async(fn -> Enum.to_list(stream) end)

    assert {:ok, %{"ok" => true, "bytes" => 2048}} = Transfer.send_bytes(url, payload)
    assert IO.iodata_to_binary(SystemsRuntime.Task.await(consumer, :infinity)) == payload
  end

  test "a token is one-time: the second POST 404s" do
    {:ok, receiver} = StreamReceiver.start_link()
    {_token, url, stream} = StreamReceiver.register!(receiver)
    consumer = SystemsRuntime.Task.async(fn -> Enum.to_list(stream) end)

    assert {:ok, %{"ok" => true}} = Transfer.send_bytes(url, "first")
    assert IO.iodata_to_binary(SystemsRuntime.Task.await(consumer, :infinity)) == "first"

    assert {:error, {404, _}} = Transfer.send_bytes(url, "second")
  end
end
