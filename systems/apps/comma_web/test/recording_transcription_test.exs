defmodule CommaWeb.RecordingTranscriptionTest do
  use SystemsClock.Case, async: true
  import Plug.Test
  import Plug.Conn

  setup do
    owner = SystemsRuntime.Proc.self()
    id = {__MODULE__, SystemsRuntime.Proc.make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach(
        id,
        [:salix, :operation, :stop],
        fn _event, measurements, metadata, _ ->
          if SystemsRuntime.Proc.self() == owner and
               metadata.operation in ["meeting_asr", "dictation_asr"] do
            SystemsRuntime.Proc.send(owner, {:asr_observed, measurements, metadata})
          end
        end,
        nil
      )

    failure_id = {__MODULE__, :failure, SystemsRuntime.Proc.make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach(
        failure_id,
        [:salix, :asr, :failure],
        fn _event, _measurements, metadata, _ ->
          if SystemsRuntime.Proc.self() == owner,
            do: SystemsRuntime.Proc.send(owner, {:asr_failed, metadata})
        end,
        nil
      )

    on_exit(fn ->
      SystemsRuntime.Telemetry.detach(id)
      SystemsRuntime.Telemetry.detach(failure_id)
    end)
  end

  test "streams an uploaded M4A into the shared ASR boundary and returns text with source timing" do
    owner = SystemsRuntime.Proc.self()

    result = %{
      transcript: "[00:01] Speaker: 会议开始。",
      duration_seconds: 840,
      chunks: [%{index: 0, offset_seconds: 0, transcript: "[00:01] Speaker: 会议开始。"}]
    }

    request =
      conn(:post, "/v1/comma/me/recordings/transcribe", "M4A fixture")
      |> put_req_header("content-type", "audio/mp4")

    response =
      CommaWeb.RecordingTranscription.call(request,
        transcribe: fn stream, size, filename ->
          SystemsRuntime.Proc.send(owner, {:upload, Enum.join(stream), size, filename})
          {:ok, result}
        end
      )

    assert_receive {:upload, "M4A fixture", 11, "recording.m4a"}
    assert response.status == 200
    assert response.resp_body =~ "event: transcription"
    assert response.resp_body =~ Jason.encode!(%{status: "ready", result: result})
    assert_receive {:asr_observed, %{duration: duration}, %{surface: "comma", outcome: "ok"}}
    assert duration >= 0
    refute_receive {:asr_observed, _, _}
  end

  test "a dictation upload is observed apart from meeting recordings" do
    request =
      conn(:post, "/v1/comma/me/recordings/transcribe?purpose=dictation", "M4A")
      |> put_req_header("content-type", "audio/mp4")

    response =
      CommaWeb.RecordingTranscription.call(request,
        transcribe: fn _, _, _ ->
          {:ok, %{transcript: "把 GitHub 上的评论总结一下", duration_seconds: 3, chunks: []}}
        end
      )

    assert response.resp_body =~ "把 GitHub 上的评论总结一下"
    # The request observes its outcome before it answers.
    assert_received {:asr_observed, _, %{operation: "dictation_asr", outcome: "ok"}}
    refute_received {:asr_observed, _, _}
  end

  test "a failed recording logs and counts why, while the client sees one sentence" do
    request =
      conn(:post, "/v1/comma/me/recordings/transcribe", "M4A")
      |> put_req_header("content-type", "audio/mp4")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        response =
          CommaWeb.RecordingTranscription.call(request,
            transcribe: fn _, _, _ ->
              {:error,
               {:asr_chunk_failed, 2, {:asr_incomplete_transcript, "content_filter: OTHER"}}}
            end
          )

        assert response.resp_body =~ "Transcription failed. The audio remains in Drive."
      end)

    assert log =~
             "recording transcription failed: source=recording_upload " <>
               "reason=asr_chunk_failed index=2 cause=asr_incomplete_transcript_content_filter: OTHER"

    assert_received {:asr_failed, %{operation: "recording_upload", reason: "content_filter"}}
    assert_received {:asr_observed, _, %{operation: "meeting_asr", outcome: "error"}}
  end

  test "a transcriber that raises is logged by its exception, not swallowed" do
    request =
      conn(:post, "/v1/comma/me/recordings/transcribe?purpose=dictation", "M4A")
      |> put_req_header("content-type", "audio/mp4")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        CommaWeb.RecordingTranscription.call(request,
          transcribe: fn _, _, _ -> raise ArgumentError, "private detail" end
        )
      end)

    assert log =~ "recording transcription failed: source=dictation reason=ArgumentError"
    refute log =~ "private detail"
    assert_received {:asr_failed, %{operation: "dictation", reason: "other"}}
  end
end
