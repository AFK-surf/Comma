defmodule SalixIM.IMessageRelayTest do
  use ExUnit.Case, async: true
  alias SalixIM.IMessageRelay

  test "split UTF-8/JSON chunks and keepalives preserve event ordering" do
    owner = self()

    handler = fn event ->
      send(owner, {:event, event["event_id"]})
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
      send(self(), {:seen, id})
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

  test "malformed and oversized lines fail closed" do
    handler = fn _ -> flunk("invalid frame reached handler") end

    assert {:error, :invalid_imessage_event} =
             IMessageRelay.decode_chunk("", "not json\n", handler)

    assert {:error, :invalid_imessage_event} = IMessageRelay.decode_chunk("", "{}\n", handler)

    assert {:error, :imessage_event_too_large} =
             IMessageRelay.decode_chunk("", String.duplicate("x", 1_048_577), handler)
  end
end

defmodule SalixIM.IMessageRelayHTTPTest do
  use ExUnit.Case, async: false

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

  test "HTTP EOF rejects a partial event without admitting it" do
    previous = Application.get_env(:salix_im, :imessage)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:salix_im, :imessage),
        else: Application.put_env(:salix_im, :imessage, previous)
    end)

    complete = Jason.encode!(%{"event_id" => "1", "type" => "message"}) <> "\n"

    for {body, opts, expected} <- [
          {complete, [], :ok},
          {complete <> ~s({"event_id":"2","type":"mess), [], {:error, :invalid_imessage_event}},
          {complete <> ~s({"event_id":"2","type":"mess), [duration_ms: 0], :ok}
        ] do
      port =
        SalixIM.TestSupport.BanditServer.start!(fn port ->
          {Bandit, plug: {StreamEndpoint, body}, port: port}
        end)

      Application.put_env(:salix_im, :imessage,
        enabled: true,
        relay_id: "stream-test",
        base_url: "http://127.0.0.1:#{port}",
        bearer_token: "stream-test-secret",
        shared_handle: "comma@example.test"
      )

      owner = self()

      handler = fn event ->
        send(owner, {:admitted, event["event_id"]})
        :ok
      end

      assert SalixIM.IMessageRelay.stream("0", handler, opts) == expected
      assert_receive {:admitted, "1"}
      refute_receive {:admitted, "2"}
    end
  end

  test "an empty Go relay tail starts at the beginning without accepting malformed cursors" do
    previous = Application.get_env(:salix_im, :imessage)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:salix_im, :imessage),
        else: Application.put_env(:salix_im, :imessage, previous)
    end)

    for {body, expected} <- [
          {%{}, {:ok, ""}},
          {%{"latest_event_id" => "42"}, {:ok, "42"}},
          {%{"latest_event_id" => nil}, {:error, :imessage_relay_unavailable}},
          {%{"error" => "unavailable"}, {:error, :imessage_relay_unavailable}}
        ] do
      port =
        SalixIM.TestSupport.BanditServer.start!(fn port ->
          {Bandit, plug: {TailEndpoint, body}, port: port}
        end)

      Application.put_env(:salix_im, :imessage,
        enabled: true,
        relay_id: "tail-test",
        base_url: "http://127.0.0.1:#{port}",
        bearer_token: "tail-test-secret",
        shared_handle: "comma@example.test"
      )

      assert SalixIM.IMessageRelay.tail() == expected
    end
  end
end
