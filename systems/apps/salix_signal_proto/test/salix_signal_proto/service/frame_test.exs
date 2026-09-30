defmodule SalixSignalProto.Service.FrameTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.Service.Frame
  alias SalixSignalProto.Service.Frame.{Request, Response}
  alias SalixSignalProto.Test.Vectors

  # CRS-01 section 7.4: the oracle's keepalive request, request id 0.
  test "the keepalive request encodes to the CRS-01 section 7.4 bytes" do
    frame =
      Frame.encode_request(%Request{verb: "GET", path: "/v1/keepalive", id: 0, headers: []})

    inner = Vectors.hex!("0a03474554120d2f76312f6b656570616c6976652000")
    assert frame == Vectors.hex!("08011216") <> inner
  end

  # CRS-01 section 7: vectors/CRS-01/ws-client-requests-and-responses.json
  describe "CRS-01 ws-client-requests-and-responses" do
    for {vector, index} <-
          Enum.with_index(
            Vectors.load!("crs/CRS-01/ws-client-requests-and-responses.json")["cases"]
          ) do
      @vector vector
      test "case #{index}: the response parses as the oracle client parsed it" do
        request = @vector["inputs"]["client_request"]
        expected = @vector["outputs"]["client_result"]

        assert {:ok, %Response{} = response} =
                 Frame.decode(Vectors.hex!(@vector["inputs"]["outer_websocket_message"]))

        assert response.id == request["id"]
        assert response.status == expected["status"]
        assert response.message == expected["message"]
        assert response.headers == Enum.map(expected["headers"], &List.to_tuple/1)
        assert response.body == if(expected["body"], do: Vectors.hex!(expected["body"]))
      end
    end
  end

  # CRS-01 section 10: vectors/CRS-01/ws-server-requests.json
  describe "CRS-01 ws-server-requests" do
    for {vector, index} <-
          Enum.with_index(Vectors.load!("crs/CRS-01/ws-server-requests.json")["cases"]) do
      @vector vector
      test "case #{index}: the pushed request gives the oracle client's events" do
        assert {:ok, %Request{} = request} =
                 Frame.decode(Vectors.hex!(@vector["inputs"]["outer_websocket_message"]))

        expected =
          Enum.map(@vector["outputs"]["client_events"], fn
            %{"event" => "pushed_envelope"} = event ->
              {:incoming_message, Vectors.hex!(event["envelope"]),
               event["server_delivery_timestamp"]}

            %{"event" => "backlog_sent"} ->
              :queue_empty
          end)

        events = Enum.reject([Frame.server_event(request)], &(&1 == :ignore))
        assert events == expected
      end
    end
  end

  test "an acknowledgement carries the reason phrase the server requires" do
    frame = Frame.encode_response(%Response{id: Frame.max_request_id(), status: 200})

    assert {:ok, %Response{id: 0xFFFF_FFFF_FFFF_FFFF, status: 200, message: "OK", body: nil}} =
             Frame.decode(frame)
  end

  test "request ids wrap to 0 after 2^64 - 1" do
    assert Frame.next_request_id(0) == 1
    assert Frame.next_request_id(Frame.max_request_id()) == 0
  end

  test "frames without the part their kind needs, or with both parts, are dropped" do
    # CRS-01 section 7.1: kind 1 without a request; kind 2 without a
    # response; kind 0; bytes that do not parse; a request with a response.
    assert Frame.decode(<<0x08, 0x01>>) == {:error, :malformed}
    assert Frame.decode(<<0x08, 0x02>>) == {:error, :malformed}

    response = Frame.encode_response(%Response{id: 1, status: 200})
    <<0x08, 0x02, rest::binary>> = response
    assert Frame.decode(<<0x08, 0x00, rest::binary>>) == {:error, :malformed}
    assert Frame.decode(<<0x08, 0x01, rest::binary>>) == {:error, :malformed}

    both = %Frame.FrameMessage{
      request: %Frame.RequestMessage{verb: "PUT", path: "/api/v1/message", id: 1},
      response: %Frame.ResponseMessage{id: 1, status: 200}
    }

    assert Frame.decode(Frame.FrameMessage.encode(%{both | type: 1})) == {:error, :malformed}
    assert Frame.decode(Frame.FrameMessage.encode(%{both | type: 2})) == {:error, :malformed}
    assert Frame.decode(<<0xFF, 0xFF>>) == {:error, :malformed}
  end

  # CRS-01 section 7.3.1, table rows.
  test "responses follow the client rules: drop, fail the request, or accept" do
    decode = fn fields ->
      inner = struct(Frame.ResponseMessage, Map.merge(%{id: 0, status: 200}, fields))
      Frame.decode(Frame.FrameMessage.encode(%Frame.FrameMessage{type: 2, response: inner}))
    end

    assert decode.(%{id: nil}) == {:error, :malformed}

    for fields <- [
          %{status: nil},
          %{status: 99},
          %{status: 1000},
          %{headers: ["no-colon"]},
          %{headers: [":v"]},
          %{headers: ["Name :v"]},
          %{headers: ["A:b\x01c"]}
        ] do
      assert decode.(fields) == {:error, {:invalid_response, 0}}, inspect(fields)
    end

    assert {:ok, %Response{status: 999, message: nil, headers: headers}} =
             decode.(%{status: 999, headers: ["A:b:c", "B:", "C:  v\t"]})

    assert headers == [{"a", "b:c"}, {"b", ""}, {"c", "v"}]
  end

  # CRS-01 sections 7.2 (client rules) and 10.1.
  test "server requests: only PUT with an id on the two paths is recognized; the last valid timestamp wins" do
    push = fn fields ->
      Map.merge(%Request{verb: "PUT", path: "/api/v1/message", id: 1, body: "e"}, fields)
    end

    assert Frame.server_event(push.(%{id: nil})) == :ignore
    assert Frame.server_event(push.(%{verb: "put"})) == :ignore
    assert Frame.server_event(push.(%{path: "/api/v1/message?x=1"})) == :ignore
    assert Frame.server_event(push.(%{path: "/api/v1/queue/empty"})) == :queue_empty
    assert Frame.server_event(push.(%{body: nil})) == {:incoming_message, "", 0}

    headers = [
      {"x-signal-timestamp", "5"},
      {"x-signal-timestamp", "+7"},
      {"x-signal-timestamp", "x"}
    ]

    assert Frame.server_event(push.(%{headers: headers})) == {:incoming_message, "e", 7}

    assert Frame.server_event(push.(%{headers: [{"x-signal-timestamp", "18446744073709551616"}]})) ==
             {:incoming_message, "e", 0}
  end

  property "requests and responses survive an encode and decode" do
    check all(
            verb <- member_of(["GET", "PUT", "POST", "DELETE", "HEAD", "PATCH"]),
            path <- string(:printable, max_length: 64),
            id <- integer(0..Frame.max_request_id()),
            status <- integer(100..599),
            body <- one_of([constant(nil), binary(max_length: 64)]),
            headers <- list_of(header(), max_length: 4)
          ) do
      request = %Request{verb: verb, path: path, id: id, body: body, headers: headers}
      assert Frame.decode(Frame.encode_request(request)) == {:ok, request}

      response = %Response{id: id, status: status, message: "x", body: body, headers: headers}
      assert Frame.decode(Frame.encode_response(response)) == {:ok, response}
    end
  end

  property "arbitrary bytes decode or are rejected without raising" do
    check all(bytes <- binary(max_length: 128)) do
      assert match?({:ok, _}, Frame.decode(bytes)) or
               match?({:error, {:invalid_response, _}}, Frame.decode(bytes)) or
               Frame.decode(bytes) == {:error, :malformed}
    end
  end

  defp header do
    gen all(
          name <- string([?a..?z, ?-], min_length: 1, max_length: 12),
          value <- string([?a..?z, ?0..?9, ?:, ?\s, ?/], max_length: 16)
        ) do
      {name, String.trim(value)}
    end
  end
end
