defmodule SalixMeetNative.RuntimeTest do
  use ExUnit.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.SalixMeetNative"]

  alias SalixMeetNative.{FakeSession, Runtime, Transcript}
  alias SalixMeetNative.Events.Event

  @request %{
    "meeting_id" => "mtg_1",
    "meet_url" => "https://meet.google.com/abc-defg-hij",
    "bot_name" => "Cue",
    "caption_language" => "Chinese, Mandarin (Simplified)"
  }

  defp start(opts \\ []) do
    test = self()
    deliver = Keyword.get(opts, :deliver, fn event -> send(test, {:delivered, event}) && :ok end)

    {:ok, runtime} =
      Runtime.start_link(
        request: Map.merge(@request, Keyword.get(opts, :request, %{})),
        deliver: deliver,
        session_module: FakeSession,
        empty_grace_ms: Keyword.get(opts, :grace, 60_000),
        session: [test_pid: test],
        fallback: Keyword.get(opts, :fallback)
      )

    settle_receive({:fake_session, session, session_opts})
    {runtime, session, session_opts}
  end

  defp delivered do
    settle_receive({:delivered, event})
    event
  end

  defp event(type, payload, actor, source \\ "collections"),
    do: {:event, %Event{type: type, actor: actor, payload: payload, source: source}}

  defp participant(device, name, state),
    do: event("participant", %{"device" => device, "name" => name, "state" => state}, name)

  test "a joined meeting reports admission, final captions, inbound chat and a done update with artifacts",
       %{} do
    {runtime, session, session_opts} = start()
    assert session_opts[:guest_name] == "Cue"
    assert session_opts[:captions] == [{"cmn-Hans-CN", "cmn-Hans-CN"}]

    FakeSession.emit(session, {:status, %{self: "knocking"}})

    assert %{
             "event_id" => "mtg_1:waiting_room",
             "joiner_event" => %{"type" => "status", "status" => "waiting_room"}
           } = delivered()

    FakeSession.emit(session, {:status, {:self_device, "spaces/s/devices/9"}})
    FakeSession.emit(session, {:status, %{self: "joined"}})

    assert %{
             "event_id" => "mtg_1:in_meeting",
             "joiner_event" => %{"status" => "in_meeting", "timestamp" => ts}
           } = delivered()

    assert is_integer(ts)

    FakeSession.emit(session, participant("spaces/s/devices/1", "Alice", "joined"))

    FakeSession.emit(
      session,
      event("caption", %{"text" => "draft", "final" => false}, "spaces/s/devices/1", "captions")
    )

    FakeSession.emit(
      session,
      event("caption", %{"text" => "你好", "final" => true}, "spaces/s/devices/1", "captions")
    )

    FakeSession.emit(
      session,
      event("caption", %{"text" => "再见", "final" => true}, "spaces/s/devices/1", "captions")
    )

    assert %{
             "event_id" => "mtg_1:captions:1",
             "type" => "meeting_runtime_update",
             "captions" => captions
           } = delivered()

    assert Enum.map(captions, &{&1["speaker"], &1["text"], &1["source"]}) == [
             {"Alice", "你好", "captions"},
             {"Alice", "再见", "captions"}
           ]

    FakeSession.emit(
      session,
      event("chat", %{"text" => "hi", "device" => "spaces/s/devices/1", "id" => "m1"}, "Alice")
    )

    FakeSession.emit(
      session,
      event(
        "chat",
        %{"text" => "hi", "device" => "spaces/s/devices/1", "id" => "m1", "reactions" => [%{}]},
        "Alice"
      )
    )

    FakeSession.emit(
      session,
      event(
        "chat",
        %{"text" => "from bot", "device" => "spaces/s/devices/9", "id" => "m2"},
        "Cue"
      )
    )

    assert %{
             "event_id" => "mtg_1:chat_message:" <> _,
             "joiner_event" => %{"type" => "chat_message", "sender" => "Alice", "text" => "hi"}
           } = delivered()

    FakeSession.emit(session, {:recording, %{audio: write_audio()}})

    FakeSession.emit(
      session,
      event(
        "chat",
        %{"text" => "/leave", "device" => "spaces/s/devices/1", "id" => "m3"},
        "Alice"
      )
    )

    assert %{"joiner_event" => %{"text" => "/leave"}} = delivered()
    settle_receive({:fake_call, :leave})

    assert %{"event_id" => "mtg_1:meeting_ended", "joiner_event" => %{"type" => "meeting_ended"}} =
             delivered()

    assert %{
             "event_id" => "mtg_1:runtime:done",
             "status" => "done",
             "transcript_source" => "captions",
             "artifacts" => [transcript, audio]
           } =
             delivered()

    assert Base.decode64!(transcript["data_b64"]) == Transcript.build(captions)

    assert {audio["kind"], audio["filename"], audio["content_type"]} ==
             {"audio", "audio.ogg", "audio/ogg"}

    assert File.read!(audio["src_path"]) == "OggS"
    refute Map.has_key?(audio, "data_b64")

    settle_refute_receive({:delivered, _}, 300)
    refute Process.alive?(runtime)
  end

  test "a refused admission fails with the provider stop reason" do
    {_runtime, session, _} = start()
    FakeSession.emit(session, {:status, %{self: "knocking"}})
    assert %{"joiner_event" => %{"status" => "waiting_room"}} = delivered()
    FakeSession.emit(session, {:ended, :admission_denied})

    assert %{
             "event_id" => "mtg_1:error",
             "joiner_event" => %{
               "status" => "error",
               "reason_code" => "admission_denied",
               "message" => "admission_denied: meeting admission was denied"
             }
           } =
             delivered()

    assert %{"status" => "failed", "reason_code" => "admission_denied"} = update = delivered()
    refute Map.has_key?(update, "artifacts")
  end

  test "a meeting that ended before admission is cancelled" do
    {_runtime, session, _} = start()
    FakeSession.emit(session, {:ended, :left})

    assert %{"event_id" => "mtg_1:runtime:cancelled", "status" => "cancelled"} =
             update = delivered()

    refute Map.has_key?(update, "reason_code")
  end

  test "removal after admission still publishes the recording" do
    {_runtime, session, _} = start()
    FakeSession.emit(session, {:status, %{self: "joined"}})
    assert %{"joiner_event" => %{"status" => "in_meeting"}} = delivered()

    FakeSession.emit(
      session,
      event("caption", %{"text" => "kept", "final" => true}, "x/devices/2", "captions")
    )

    FakeSession.emit(session, {:ended, :removed_from_meeting})

    assert %{"event_id" => "mtg_1:captions:1"} = delivered()

    assert %{
             "event_id" => "mtg_1:meeting_ended",
             "joiner_event" => %{
               "type" => "meeting_ended",
               "reason_code" => "removed_from_meeting"
             }
           } = delivered()

    assert %{
             "status" => "done",
             "reason_code" => "removed_from_meeting",
             "artifacts" => [%{"kind" => "transcript"}]
           } = delivered()
  end

  test "live ASR captions join the caption stream and get their own transcript section" do
    {runtime, session, _} = start()
    FakeSession.emit(session, {:status, %{self: "joined"}})
    assert %{"joiner_event" => %{"status" => "in_meeting"}} = delivered()

    FakeSession.emit(
      session,
      event("caption", %{"text" => "google", "final" => true}, "x/devices/2", "captions")
    )

    asr = %{
      "speaker" => "Bob",
      "text" => "live",
      "timestamp" => 1_800_000_000,
      "timestamp_ms" => 1_800_000_000_500,
      "source" => "live"
    }

    send(runtime, {:meet_asr, asr})
    assert %{"event_id" => "mtg_1:captions:1", "captions" => captions} = delivered()
    assert asr in captions and length(captions) == 2

    FakeSession.emit(session, {:ended, :left})
    assert %{"joiner_event" => %{"type" => "meeting_ended"}} = delivered()
    assert %{"status" => "done", "artifacts" => [transcript]} = delivered()
    text = Base.decode64!(transcript["data_b64"])
    assert text =~ ~r/## Google\n\S+ …\/2: google\n/
    assert text =~ ~r/## Live\n\S+ Bob: live\n/
  end

  test "a failure after admission still publishes the captured transcript and recording" do
    {_runtime, session, _} = start()
    FakeSession.emit(session, {:status, %{self: "joined"}})
    assert %{"joiner_event" => %{"status" => "in_meeting"}} = delivered()

    FakeSession.emit(
      session,
      event("caption", %{"text" => "kept", "final" => true}, "x/devices/2", "captions")
    )

    FakeSession.emit(session, {:recording, %{audio: write_audio()}})
    FakeSession.emit(session, {:ended, {:gave_up, :collections_down}})

    assert %{"event_id" => "mtg_1:captions:1"} = delivered()
    assert %{"joiner_event" => %{"status" => "error"}} = delivered()

    assert %{
             "status" => "failed",
             "error" => "Lost the connection to the meeting and could not rejoin",
             "artifacts" => [%{"kind" => "transcript"}, %{"kind" => "audio"}]
           } = delivered()
  end

  test "a recording that cannot be stored is dropped so the transcript and status still land" do
    test = self()

    deliver = fn event ->
      if Enum.any?(event["artifacts"] || [], &Map.has_key?(&1, "src_path")),
        do: {:error, {:artifact_ingest_failed, "audio", :artifact_too_large}},
        else: send(test, {:delivered, event}) && :ok
    end

    {_runtime, session, _} = start(deliver: deliver)
    FakeSession.emit(session, {:status, %{self: "joined"}})
    assert %{"joiner_event" => %{"status" => "in_meeting"}} = delivered()

    FakeSession.emit(
      session,
      event("caption", %{"text" => "kept", "final" => true}, "x/devices/2", "captions")
    )

    FakeSession.emit(session, {:recording, %{audio: write_audio()}})
    FakeSession.emit(session, {:ended, :left})

    assert %{"event_id" => "mtg_1:captions:1"} = delivered()
    assert %{"event_id" => "mtg_1:meeting_ended"} = delivered()

    assert %{
             "event_id" => "mtg_1:runtime:done",
             "transcript_source" => "captions",
             "artifacts" => [%{"kind" => "transcript"}]
           } = delivered()
  end

  test "a crashed meeting session fails the meeting" do
    {_runtime, session, _} = start()
    FakeSession.emit(session, {:crash, :boom})
    assert %{"joiner_event" => %{"status" => "error", "message" => message}} = delivered()
    assert message == "The meeting assistant stopped unexpectedly"
    assert %{"status" => "failed"} = delivered()
  end

  test "a refused guest join reports a readable reason" do
    {_runtime, session, _} = start()

    FakeSession.emit(
      session,
      {:ended, {:token_factory, {:http, 502, "handoff", "meet-rejected", nil}}}
    )

    assert %{"joiner_event" => %{"message" => message}} = delivered()
    assert message == "Google Meet refused to let the assistant join."
    assert %{"status" => "failed", "error" => ^message} = delivered()
  end

  test "a native join whose Google account cannot sign in joins once as a guest" do
    {_runtime, native, _} = start(fallback: {FakeSession, [test_pid: self(), mode: :guest]})
    FakeSession.emit(native, {:ended, {:native, {:token_factory_status, 401}}})

    settle_receive({:fake_session, guest, guest_opts})
    assert guest_opts[:mode] == :guest
    assert guest_opts[:url] == @request["meet_url"]
    assert guest_opts[:guest_name] == "Cue"
    assert %{"joiner_event" => %{"status" => "guest_fallback"}} = delivered()

    FakeSession.emit(guest, {:status, %{self: "joined"}})
    assert %{"joiner_event" => %{"status" => "in_meeting"}} = delivered()

    # The fallback is used once: a second login failure fails the meeting.
    FakeSession.emit(guest, {:ended, {:native, {:token_factory_status, 401}}})

    assert %{"joiner_event" => %{"reason_code" => "google_login_required"}} = delivered()
    assert %{"status" => "failed", "reason_code" => "google_login_required"} = delivered()
  end

  test "a native join that fails for another reason does not fall back" do
    {_runtime, native, _} = start(fallback: {FakeSession, [test_pid: self(), mode: :guest]})
    FakeSession.emit(native, {:ended, {:native, {:token_factory_status, 503}}})

    assert %{"joiner_event" => %{"message" => message}} = delivered()
    assert message == "Could not reach the meeting join service"
    assert %{"status" => "failed", "error" => ^message} = delivered()
    settle_refute_receive({:fake_session, _, _})
  end

  test "retryable callback failures are retried in order and permanent rejections are skipped" do
    test = self()
    {:ok, attempts} = Agent.start_link(fn -> %{} end)

    deliver = fn event ->
      n =
        Agent.get_and_update(attempts, fn m ->
          {Map.get(m, event["event_id"], 0) + 1, Map.update(m, event["event_id"], 1, &(&1 + 1))}
        end)

      send(test, {:attempt, event["event_id"], n})

      cond do
        event["event_id"] == "mtg_1:waiting_room" and n < 3 -> {:error, :retryable}
        event["event_id"] == "mtg_1:in_meeting" -> {:error, {:permanent, :rejected}}
        true -> send(test, {:delivered, event}) && :ok
      end
    end

    {_runtime, session, _} = start(deliver: deliver)
    FakeSession.emit(session, {:status, %{self: "knocking"}})
    FakeSession.emit(session, {:status, %{self: "joined"}})
    FakeSession.emit(session, {:ended, :left})

    assert %{"event_id" => "mtg_1:waiting_room"} = delivered()
    assert_received {:attempt, "mtg_1:waiting_room", 3}
    settle_receive({:attempt, "mtg_1:in_meeting", 1})
    assert %{"event_id" => "mtg_1:meeting_ended"} = delivered()
    assert %{"event_id" => "mtg_1:runtime:done"} = delivered()
    refute_received {:attempt, "mtg_1:in_meeting", 2}
  end

  test "the bot leaves after everyone else has gone for the grace period, and caption commands reach the session" do
    {_runtime, session, _} = start(grace: 200)
    FakeSession.emit(session, {:status, {:self_device, "me"}})
    FakeSession.emit(session, {:status, %{self: "joined"}})
    assert %{"joiner_event" => %{"status" => "in_meeting"}} = delivered()

    FakeSession.emit(
      session,
      event("chat", %{"text" => "/setlang ja:en", "device" => "a", "id" => "c1"}, "A")
    )

    settle_receive({:fake_call, {:set_caption_lang, "ja", "en"}})
    _ = delivered()

    FakeSession.emit(session, participant("a", "A", "joined"))
    FakeSession.emit(session, participant("a", "A", "left"))
    settle_receive({:fake_call, :leave})
  end

  test "a bot that stays alone in the meeting leaves after ten minutes" do
    {_runtime, session, _} = start(grace: 200)
    FakeSession.emit(session, {:status, {:self_device, "me"}})
    FakeSession.emit(session, {:status, %{self: "joined"}})
    assert %{"joiner_event" => %{"status" => "in_meeting"}} = delivered()
    joined_at = SystemsClock.monotonic_time(:millisecond)

    settle_receive({:fake_call, :leave})
    assert SystemsClock.monotonic_time(:millisecond) - joined_at >= 600_000
    assert %{"event_id" => "mtg_1:meeting_ended"} = delivered()
    assert %{"event_id" => "mtg_1:runtime:done"} = delivered()
  end

  test "a participant who joins before the alone timeout keeps the bot in the meeting" do
    {_runtime, session, _} = start(grace: 200)
    FakeSession.emit(session, {:status, {:self_device, "me"}})
    FakeSession.emit(session, {:status, %{self: "joined"}})
    assert %{"joiner_event" => %{"status" => "in_meeting"}} = delivered()

    FakeSession.emit(session, participant("a", "A", "joined"))
    SystemsClock.run_for(700_000)
    refute_received {:fake_call, :leave}
  end

  test "caption languages follow the Go runtime mapping" do
    assert Runtime.caption_language("English") == "en-US"
    assert Runtime.caption_language("Chinese, Mandarin (Simplified)") == "cmn-Hans-CN"
    assert Runtime.caption_language("ja-JP") == "ja-JP"
    assert Runtime.caption_language("日本語") == "en-US"
    assert Runtime.caption_language(nil) == "en-US"
  end

  test "transcripts match the Go runtime byte for byte" do
    input = "test/fixtures/golden/transcript_in.json" |> File.read!() |> Jason.decode!()
    output = "test/fixtures/golden/transcript_out.json" |> File.read!() |> Jason.decode!()
    for {name, captions} <- input, do: assert(Transcript.build(captions) == output[name], name)
  end

  defp write_audio do
    path =
      Path.join(
        System.tmp_dir!(),
        "meet-runtime-#{SystemsRuntime.Proc.unique_integer([:positive])}.ogg"
      )

    File.write!(path, "OggS")
    path
  end
end
