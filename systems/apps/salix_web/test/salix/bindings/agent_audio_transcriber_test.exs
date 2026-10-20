defmodule Salix.Bindings.AgentAudioTranscriberTest do
  use SystemsClock.Case, async: true

  alias Salix.Bindings.AgentAudioTranscriber

  defmodule RecordingTranscriber do
    def transcribe_audio_stream_with_metadata(cfg, stream, size, filename, prompt, opts \\ []) do
      received = Enum.reduce(stream, 0, &(byte_size(&1) + &2))

      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:transcribed, received, size, filename, prompt}
      )

      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:asked, cfg, opts})

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
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:streamed, agent_id, path})

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

  test "Quick Chat's words are asked for as dictation, quickly, not as timed speaker lines" do
    upload = fn opts ->
      AgentAudioTranscriber.transcribe_upload(
        ["M4A"],
        3,
        "recording.m4a",
        [config_fun: fn -> {:ok, %{}} end, transcriber: RecordingTranscriber] ++ opts
      )
    end

    assert {:ok, _} = upload.([])
    assert_received {:transcribed, 3, 3, "recording.m4a", recording_prompt}
    # A meeting recording keeps the tier's own settings.
    assert_received {:asked, %{}, []}
    assert {:ok, _} = upload.(purpose: :dictation)
    assert_received {:transcribed, 3, 3, "recording.m4a", dictation_prompt}
    refute dictation_prompt == recording_prompt
    # A person waits for dictation: short reasoning, a request asked again, a bound under 10 s.
    assert_received {:asked, %{"reasoning_effort" => "low"}, opts}
    assert is_function(opts[:transcribe_fun], 4)
    assert opts[:batch_timeout_ms] < 10_000
  end
end
