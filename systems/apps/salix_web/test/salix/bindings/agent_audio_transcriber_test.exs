defmodule Salix.Bindings.AgentAudioTranscriberTest do
  use ExUnit.Case, async: true

  alias Salix.Bindings.AgentAudioTranscriber

  defmodule RecordingTranscriber do
    def transcribe_audio_stream_with_metadata(_cfg, stream, size, filename, prompt) do
      received = Enum.reduce(stream, 0, &(byte_size(&1) + &2))
      send(self(), {:transcribed, received, size, filename, prompt})

      {:ok,
       %{
         transcript: "[00:00:01] Speaker: streamed",
         duration_seconds: 11,
         chunks: [
           %{index: 0, offset_seconds: 0, transcript: "[00:00:01] Speaker: streamed"}
         ]
       }}
    end
  end

  test "streams a large normal workspace file into the shared transcriber" do
    size = 11 * 1024 * 1024

    stream_fun = fn %{agent_id: agent_id}, path ->
      send(self(), {:streamed, agent_id, path})

      stream =
        Stream.repeatedly(fn -> :binary.copy(<<0xA5>>, 256 * 1024) end)
        |> Stream.take(44)

      {:ok, stream, size}
    end

    assert {:ok, %{duration_seconds: 11}} =
             AgentAudioTranscriber.transcribe("agent-1", "/meetings/test/audio.ogg",
               config_fun: fn -> {:ok, %{}} end,
               stream_fun: stream_fun,
               transcriber: RecordingTranscriber
             )

    assert_receive {:streamed, "agent-1", "/meetings/test/audio.ogg"}
    assert_receive {:transcribed, ^size, ^size, "audio.ogg", _prompt}
  end

  test "rejects paths outside the normal agent-visible workspace" do
    opts = [config_fun: fn -> {:ok, %{}} end]

    assert {:error, :audio_path_not_absolute} =
             AgentAudioTranscriber.transcribe("agent-1", "relative.ogg", opts)

    assert {:error, :audio_path_not_visible} =
             AgentAudioTranscriber.transcribe(
               "agent-1",
               "/.runtime/compaction-recovery.md",
               opts
             )
  end

  test "recording uploads use the same configured transcription engine and prompt" do
    assert {:ok, %{duration_seconds: 11}} =
             AgentAudioTranscriber.transcribe_upload(["M4A"], 3, "recording.m4a",
               config_fun: fn -> {:ok, %{}} end,
               transcriber: RecordingTranscriber
             )

    assert_receive {:transcribed, 3, 3, "recording.m4a", _prompt}

    assert {:error, :asr_not_configured} =
             AgentAudioTranscriber.transcribe_upload([], 0, "recording.m4a",
               config_fun: fn -> {:error, :asr_not_configured} end
             )
  end

  test "rejects empty, invalid, and oversized streams before provider dispatch" do
    call = fn size ->
      AgentAudioTranscriber.transcribe("agent-1", "/audio.ogg",
        config_fun: fn -> {:ok, %{}} end,
        stream_fun: fn _ctx, _path -> {:ok, [], size} end,
        transcriber: RecordingTranscriber
      )
    end

    assert {:error, :asr_audio_empty} = call.(0)
    assert {:error, :asr_audio_size_invalid} = call.(-1)
    assert {:error, :asr_audio_too_large} = call.(30 * 1024 * 1024 + 1)
    refute_receive {:transcribed, _, _, _, _}
  end
end
