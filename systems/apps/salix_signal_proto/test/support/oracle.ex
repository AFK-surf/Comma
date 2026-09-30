defmodule SalixSignalProto.Test.Oracle do
  @moduledoc false
  # Client for the black-box oracle in function mode (ORACLE_INTERFACE.md):
  # one JSON request per line over TCP at COMMA_SIGNAL_ORACLE (host:port).
  # Tests that use it carry the :signal_oracle tag, which test_helper.exs
  # excludes by default.

  @timeout 30_000

  def connect! do
    [host, port] = "COMMA_SIGNAL_ORACLE" |> System.fetch_env!() |> String.split(":")

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), String.to_integer(port), [
        :binary,
        active: false,
        packet: :line,
        buffer: 16 * 1024 * 1024,
        recbuf: 16 * 1024 * 1024
      ])

    socket
  end

  @doc "Returns `{:ok, result}` or `{:error, kind}`. Compare kinds only as advice."
  def call(socket, op, args) do
    id = System.unique_integer([:positive])
    line = JSON.encode!(%{id: id, op: op, args: encode_args(args)})
    :ok = :gen_tcp.send(socket, [line, "\n"])
    {:ok, response} = :gen_tcp.recv(socket, 0, @timeout)

    case JSON.decode!(response) do
      %{"id" => ^id, "ok" => true, "result" => result} -> {:ok, result}
      %{"id" => ^id, "ok" => false, "error" => %{"kind" => kind}} -> {:error, kind}
    end
  end

  def call!(socket, op, args) do
    {:ok, result} = call(socket, op, args)
    result
  end

  def hex(bytes), do: Base.encode16(bytes, case: :lower)
  def unhex(hex), do: Base.decode16!(hex, case: :lower)

  # Binaries are bytes and become lowercase hex. Wrap a JSON string argument
  # as `{:text, string}`. Other values pass through.
  defp encode_args(args) do
    Map.new(args, fn
      {key, {:text, value}} -> {key, value}
      {key, value} when is_binary(value) -> {key, hex(value)}
      {key, value} -> {key, value}
    end)
  end
end
