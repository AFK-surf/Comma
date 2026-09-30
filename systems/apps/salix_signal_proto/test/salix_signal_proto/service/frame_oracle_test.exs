defmodule SalixSignalProto.Service.FrameOracleTest do
  # Level 2 and 3 differential tests of the chat-socket client rules (CRS-01
  # sections 7.2, 7.3.1 and 10.1) against the oracle's reference chat client
  # (ORACLE_INTERFACE.md section 6.14). The oracle takes inner request or
  # response messages; Comma decodes the same message inside its frame. Strings
  # are valid UTF-8 because the oracle's test server cannot send anything
  # else. Run with `--include signal_oracle` and COMMA_SIGNAL_ORACLE=host:port.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.Service.Frame
  alias SalixSignalProto.Service.Frame.{FrameMessage, RequestMessage, ResponseMessage}
  alias SalixSignalProto.Test.Oracle

  @moduletag :signal_oracle
  @moduletag timeout: 300_000

  # The oracle reports integers only up to 2^53 - 1 (ORACLE_INTERFACE.md
  # section 2), so generated timestamps stay below that.
  @max_reported 9_007_199_254_740_991

  setup_all do
    {:ok, oracle: Oracle.connect!()}
  end

  describe "server requests (CRS-01 sections 7.2 and 10.1)" do
    property "Comma reports the oracle client's events and answers the same requests", %{
      oracle: oracle
    } do
      check all(inner <- request_message(), max_runs: 60) do
        result =
          Oracle.call!(oracle, "chat.client_receive_request", %{
            request: RequestMessage.encode(inner),
            ack_status: 200
          })

        {:ok, %Frame.Request{} = request} =
          Frame.decode(FrameMessage.encode(%FrameMessage{type: 1, request: inner}))

        event = Frame.server_event(request)
        assert Enum.reject([event], &(&1 == :ignore)) == oracle_events(result["events"])

        # Comma answers a pushed envelope only (after the owner acknowledges
        # it); never queue-empty or anything else (Comma decision 3).
        assert result["client_answered"] == match?({:incoming_message, _, _}, event)
      end
    end
  end

  describe "responses to Comma's requests (CRS-01 section 7.3.1)" do
    property "Comma accepts, fails or drops each response as the oracle client does", %{
      oracle: oracle
    } do
      check all(inner <- response_message(), max_runs: 300) do
        result =
          Oracle.call!(oracle, "chat.client_receive_response", %{
            response: ResponseMessage.encode(inner)
          })

        decoded = Frame.decode(FrameMessage.encode(%FrameMessage{type: 2, response: inner}))

        case result["outcome"] do
          "accepted" ->
            assert {:ok, %Frame.Response{id: 0} = response} = decoded
            assert response.status == result["status"]
            assert response.message == result["reason"]
            assert response.headers == Enum.map(result["headers"], &List.to_tuple/1)
            assert response.body == if(result["body"], do: Oracle.unhex(result["body"]))

          "accepted_unreportable" ->
            assert {:ok, %Frame.Response{id: 0}} = decoded

          "rejected" ->
            assert decoded == {:error, {:invalid_response, 0}}

          "ignored" ->
            # No id: dropped. Another id: matches no outstanding request,
            # valid or not.
            assert decoded == {:error, :malformed} or
                     match?({:ok, %Frame.Response{id: id}} when id != 0, decoded) or
                     match?({:error, {:invalid_response, id}} when id != 0, decoded)
        end
      end
    end
  end

  defp oracle_events(events) do
    Enum.map(events, fn
      %{"event" => "pushed_envelope"} = event ->
        {:incoming_message, Oracle.unhex(event["envelope"]), event["server_delivery_timestamp"]}

      %{"event" => "backlog_sent"} ->
        :queue_empty
    end)
  end

  # --- Generators ---

  defp request_message do
    gen all(
          verb <- member_of([nil, "PUT", "put", "GET"]),
          path <-
            member_of([
              nil,
              "/api/v1/message",
              "/api/v1/queue/empty",
              "/api/v1/message?x=1",
              "/v1/other"
            ]),
          id <- one_of([constant(nil), integer(0..1_000_000)]),
          body <- one_of([constant(nil), binary(max_length: 16)]),
          headers <- list_of(request_header(), max_length: 4)
        ) do
      %RequestMessage{verb: verb, path: path, id: id, body: body, headers: headers}
    end
  end

  defp request_header do
    gen all(
          name <-
            member_of([
              "X-Signal-Timestamp",
              "x-signal-timestamp",
              " x-signal-timestamp",
              "x-signal-timestamp ",
              "X-Signal-Alert"
            ]),
          value <- timestamp_value(),
          colon? <- frequency([{9, constant(true)}, {1, constant(false)}])
        ) do
      if colon?, do: name <> ":" <> value, else: name <> value
    end
  end

  defp timestamp_value do
    gen all(
          number <- integer(0..@max_reported),
          form <-
            member_of([
              :plain,
              :plus,
              :padded,
              :leading_zero,
              :negative,
              :inner_space,
              :text,
              :empty
            ])
        ) do
      digits = Integer.to_string(number)

      case form do
        :plain -> digits
        :plus -> "+" <> digits
        :padded -> " \t" <> digits <> "\r\n"
        :leading_zero -> "0" <> digits
        :negative -> "-" <> digits
        :inner_space -> digits <> " 1"
        :text -> "0x" <> digits
        :empty -> ""
      end
    end
  end

  defp response_message do
    gen all(
          id <- frequency([{8, constant(0)}, {1, constant(nil)}, {1, constant(7)}]),
          status <-
            frequency([
              {6, integer(100..599)},
              {1, constant(nil)},
              {1, member_of([0, 99, 999, 1000, 65_535])}
            ]),
          reason <- one_of([constant(nil), string(:printable, max_length: 8)]),
          body <- one_of([constant(nil), binary(max_length: 8)]),
          headers <- list_of(response_header(), max_length: 3)
        ) do
      %ResponseMessage{id: id, status: status, message: reason, body: body, headers: headers}
    end
  end

  defp response_header do
    gen all(
          name <- string(name_chars(), max_length: 6),
          colon? <- frequency([{9, constant(true)}, {1, constant(false)}]),
          value <- string(value_chars(), max_length: 8)
        ) do
      if colon?, do: name <> ":" <> value, else: name <> value
    end
  end

  # Token characters, and some that are not: space, tab, parentheses, a
  # non-ASCII letter.
  defp name_chars,
    do: [?a..?z, ?A..?Z, ?0..?9, ?-, ?_, ?!, ?~, ?\s, ?\t, ?(, 0xE9]

  # Printable characters, white space (tab, CR, LF, NBSP), `:`, control bytes
  # and DEL, and a non-ASCII letter.
  defp value_chars,
    do: [?a..?z, ?0..?9, ?:, ?\s, ?\t, ?\r, ?\n, 0xA0, 0x01, 0x00, 0x7F, 0xE9]
end
