defmodule SalixMeetNative.LiveMeetTest do
  use ExUnit.Case, async: false

  require Logger

  # A live Meet runs in real time. Its waits go through SystemsClock, which
  # this module does not stop, so they last the real time they name.
  require SystemsClock

  @moduletag :live_meet
  @moduletag timeout: 1_800_000

  setup do
    previous = Logger.level()
    Logger.configure(level: String.to_existing_atom(System.get_env("MEET_LOG_LEVEL", "info")))
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  test "joins a real Meet, chats, records and reports the Salix callback contract" do
    test = self()
    meeting_id = System.get_env("MEET_ID", "live-test")

    request = %{
      "meeting_id" => meeting_id,
      "meet_url" => System.fetch_env!("MEET_URL"),
      "bot_name" => System.get_env("MEET_GUEST_NAME", "Cirno"),
      "caption_language" => "Chinese, Mandarin (Simplified)"
    }

    {:ok, _pid, :started} =
      SalixMeetNative.join(request,
        deliver: fn event ->
          IO.puts(
            "[live] #{event["event_id"]} #{inspect(Map.drop(event, ["artifacts"]), limit: 12, printable_limit: 160)}"
          )

          send(test, {:delivered, event})
          :ok
        end,
        session: [
          profile: System.get_env("MEET_GOOGLE_PROFILE"),
          recording_dir: System.get_env("MEET_RECORDING_DIR"),
          master_token_factory: [
            base_url: System.fetch_env!("MEET_MTF_BASE_URL"),
            secret: System.fetch_env!("MEET_MTF_SECRET")
          ]
        ]
      )

    on_exit(fn -> SalixMeetNative.leave(meeting_id) end)

    assert %{"joiner_event" => %{"status" => "in_meeting"}} = await_joined_or_terminal(600_000)

    assert :ok = send_chat_when_open(meeting_id, 20)

    linger = String.to_integer(System.get_env("MEET_LINGER_MS", "30000"))
    terminal = await_terminal(linger) || leave_and_await(meeting_id)

    assert %{"status" => "done", "artifacts" => artifacts} = terminal

    IO.puts(
      "[live] artifacts " <>
        Enum.map_join(
          artifacts,
          ", ",
          &"#{&1["filename"]} #{byte_size(Base.decode64!(&1["data_b64"]))}B"
        )
    )

    assert SalixMeetNative.session_status(meeting_id) == {:ok, :none}
  end

  defp await_joined_or_terminal(timeout) do
    SystemsClock.vreceive do
      {:delivered, %{"joiner_event" => %{"status" => "in_meeting"}} = event} ->
        event

      {:delivered, %{"type" => "meeting_runtime_update", "status" => status} = event}
      when status in ~w(done failed cancelled) ->
        event

      {:delivered, _event} ->
        await_joined_or_terminal(timeout)
    after
      timeout -> :timeout
    end
  end

  defp leave_and_await(meeting_id) do
    assert :ok = SalixMeetNative.leave(meeting_id)
    await_terminal(60_000)
  end

  defp send_chat_when_open(meeting_id, attempts) do
    case SalixMeetNative.send_chat(meeting_id, "Hello from Salix native Meet", "live-test-1") do
      {:error, {:channel_not_open, _}} when attempts > 1 ->
        SystemsClock.sleep(1_500)
        send_chat_when_open(meeting_id, attempts - 1)

      result ->
        result
    end
  end

  defp await_terminal(timeout) do
    SystemsClock.vreceive do
      {:delivered, %{"event_id" => "" <> id} = event} ->
        if String.ends_with?(id, [":runtime:done", ":runtime:failed", ":runtime:cancelled"]),
          do: event,
          else: await_terminal(timeout)
    after
      timeout -> nil
    end
  end
end
