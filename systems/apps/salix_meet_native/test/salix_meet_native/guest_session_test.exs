defmodule SalixMeetNative.GuestSessionTest do
  use ExUnit.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixMeetNative"]

  alias SalixMeetNative.{Codec, Device, GuestSession, Wire}

  @device "spaces/abc/devices/7"
  @operation 1
  @rpc "https://meet.google.com/$rpc/google.rtc.meetings.v1."

  setup context do
    previous = SystemsRuntime.get_env(:salix_meet_native, :rpc_req_options)
    test_pid = self()
    join_state = Map.get(context, :join_state, :DEVICE_JOIN_STATE_JOINED)

    SystemsRuntime.put_env(:salix_meet_native, :rpc_req_options,
      plug: &meet(&1, test_pid, join_state)
    )

    on_exit(fn ->
      if previous == nil,
        do: SystemsRuntime.delete_env(:salix_meet_native, :rpc_req_options),
        else: SystemsRuntime.put_env(:salix_meet_native, :rpc_req_options, previous)
    end)
  end

  test "a guest marks itself left with the meeting token its sync loop rolled to" do
    session = start_guest()

    settle_until(fn ->
      receive do
        {:sync, "t1"} -> true
      after
        0 -> false
      end
    end)

    assert :ok = GuestSession.leave(session)
    # The session marks itself left from its own process, through the plug, before it replies.
    assert_received {:mark_left, "t2"}
  end

  # Meet answers 401 to the token the guest registered with once a Sync has rolled it, so the
  # acknowledgement lands only when the running join task moves to the rolled token.
  @tag join_state: :DEVICE_JOIN_STATE_KNOCKING
  test "a knocking guest acknowledges its join prerequisite with the rolled meeting token" do
    start_guest()

    settle_until(fn ->
      receive do
        {:acked, "t2"} -> true
      after
        0 -> false
      end
    end)
  end

  # Supervised by the test, so it stops before on_exit removes the stubbed
  # Meet transport: it traps exits and would outlive the test.
  defp start_guest do
    start_supervised!(
      {GuestSession,
       url: "https://meet.google.com/abc-defg-hij",
       subscriber: self(),
       captions: [],
       token_factory: [
         url: "https://guest.example/v1/handoff",
         secret: "s",
         req_options: [plug: &handoff/1]
       ]}
    )
  end

  defp handoff(conn) do
    frame = fn type, method, body ->
      %{
        "type" => type,
        "data" => %{
          "url" => @rpc <> method,
          "headers" => %{"x-goog-api-key" => "k"},
          "bodyB64" => Base.encode64(body),
          "userAgent" => "Mozilla/5.0"
        }
      }
    end

    frames = [
      frame.(
        "cmsreq",
        "MediaSessionService/CreateMediaSession",
        fixture("createmediasession-offer.bin.gz")
      ),
      frame.(
        "cmdreq",
        "MeetingDeviceService/CreateMeetingDevice",
        fixture("createmeetingdevice-req.bin")
      ),
      %{"type" => "joinclick"}
    ]

    Plug.Conn.send_resp(conn, 200, Jason.encode!(frames))
  end

  defp meet(conn, test_pid, join_state) do
    token = conn |> Plug.Conn.get_req_header("x-goog-meeting-token") |> List.first()

    case conn.path_info |> List.last() do
      "CreateMediaSession" ->
        Plug.Conn.send_resp(conn, 200, fixture("createmediasession-answer.bin"))

      "CreateMeetingDevice" ->
        device = %Wire.MeetingDevice{name: @device, join_state: join_state}

        conn
        |> Plug.Conn.put_resp_header("x-goog-meeting-token", "t1")
        |> Plug.Conn.send_resp(200, Codec.encode(device))

      "SyncMeetingSpaceCollections" ->
        send(test_pid, {:sync, token})

        conn
        |> Plug.Conn.put_resp_header("x-goog-meeting-token", "t2")
        |> Plug.Conn.send_resp(200, sync_response(join_state))

      "UpdateMeetingDevice" ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        cond do
          body == Device.mark_left_body(@device) ->
            send(test_pid, {:mark_left, token})
            Plug.Conn.send_resp(conn, 200, "")

          token != "t2" ->
            Plug.Conn.send_resp(conn, 401, "")

          body == Device.ack_operation_body(@device, @operation) ->
            send(test_pid, {:acked, token})
            Plug.Conn.send_resp(conn, 200, "")

          true ->
            Plug.Conn.send_resp(conn, 200, "")
        end
    end
  end

  defp sync_response(:DEVICE_JOIN_STATE_JOINED), do: ""

  defp sync_response(join_state) do
    device = %Wire.MeetingDevice{
      name: @device,
      join_state: join_state,
      ack_requirements: [%Wire.AckRequirement{operation: @operation, state: 1}]
    }

    Codec.encode(%Wire.SyncMeetingSpaceCollectionsResponse{
      devices: %Wire.SyncCollection{
        changed: %Wire.SyncCollectionState{
          cursor: %Wire.CollectionCursor{version: 1},
          resource_messages: [Codec.encode(device)]
        }
      }
    })
  end

  defp fixture(name), do: File.read!("test/fixtures/" <> name)
end
