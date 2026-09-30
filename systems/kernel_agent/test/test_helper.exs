Logger.configure(level: :info)

defmodule KernelAgent.FakeProvider do
  @moduledoc "A one-port HTTP server that answers each POST with the next scripted JSON body."

  def start(responses) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()
    pid = spawn_link(fn -> serve(listen, responses, test) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    {port, pid}
  end

  defp serve(_listen, [], _test), do: :ok

  defp serve(listen, [{status, body} | rest], test) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {headers, request} = read_request(socket, "")
    send(test, {:provider_request, headers, request})
    reason = if status == 200, do: "OK", else: "Error"

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} #{reason}\r\ncontent-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])

    :gen_tcp.close(socket)
    serve(listen, rest, test)
  end

  defp read_request(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, body] ->
        [_ | lines] = String.split(head, "\r\n")

        headers =
          Map.new(
            lines,
            &(&1
              |> String.split(": ", parts: 2)
              |> then(fn [k, v] -> {String.downcase(k), v} end))
          )

        length = String.to_integer(headers["content-length"] || "0")
        {headers, read_body(socket, body, length)}

      _ ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, buffer <> data)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length, do: body

  defp read_body(socket, body, length) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, body <> data, length)
  end
end

ExUnit.start()
