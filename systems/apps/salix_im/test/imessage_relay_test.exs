defmodule SalixIM.IMessageRelayTest do
  use SystemsClock.Case, async: true
  alias SalixIM.IMessageRelay

  test "split UTF-8/JSON chunks and keepalives preserve event ordering" do
    owner = SystemsRuntime.Proc.self()

    handler = fn event ->
      SystemsRuntime.Proc.send(owner, {:event, event["event_id"]})
      :ok
    end

    wire =
      Jason.encode!(%{"event_id" => "1", "type" => "message", "text" => "你好"}) <>
        "\n" <>
        Jason.encode!(%{"type" => "keepalive"}) <>
        "\n" <>
        Jason.encode!(%{"event_id" => "2", "type" => "message"}) <> "\n"

    final =
      for <<byte <- wire>>, reduce: "" do
        buffer ->
          assert {:ok, next} = IMessageRelay.decode_chunk(buffer, <<byte>>, handler)
          next
      end

    assert final == ""
    assert_receive {:event, "1"}
    assert_receive {:event, "2"}
    refute_receive {:event, _}
  end

  test "failed admission stops before processing a later event in the same chunk" do
    handler = fn %{"event_id" => id} ->
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:seen, id})
      {:error, :unavailable}
    end

    assert {:error, :unavailable} =
             IMessageRelay.decode_chunk(
               "",
               "{\"event_id\":\"1\"}\n{\"event_id\":\"2\"}\n",
               handler
             )

    assert_receive {:seen, "1"}
    refute_receive {:seen, "2"}
  end
end

defmodule SalixIM.IMessageRelayHTTPTest do
  use SystemsClock.Case, async: false

  defmodule TailEndpoint do
    def init(body), do: body

    def call(conn, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  defmodule StreamEndpoint do
    def init(body), do: body

    def call(conn, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/x-ndjson")
      |> Plug.Conn.send_resp(200, body)
    end
  end
end
