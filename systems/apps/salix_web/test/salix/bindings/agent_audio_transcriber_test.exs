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

  defmodule DictationTranscriber do
    # The words it answers come in the test's configuration.
    def transcribe_audio_stream_with_metadata(cfg, stream, size, filename, _prompt, _opts) do
      [wav] = Enum.to_list(stream)
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:wav, wav, size, filename})
      {:ok, %{transcript: cfg["transcript"], duration_seconds: 1, chunks: []}}
    end
  end

  defp dictate(pcm, transcript) do
    AgentAudioTranscriber.transcribe_dictation(pcm,
      config_fun: fn -> {:ok, %{"transcript" => transcript}} end,
      transcriber: DictationTranscriber
    )
  end

  test "a live dictation segment goes as WAV of whole MP3 frames, and its words come back" do
    pcm = :binary.copy(<<1_000::signed-little-16>>, 16_000)
    assert {:ok, "明日の会議を予約して"} = dictate(pcm, "明日の会議を予約して")

    assert_received {:wav,
                     <<"RIFF", _::binary-size(4), "WAVE", _::binary-size(24), "data",
                       data_size::little-32, data::binary>> = wav, size, "dictation.wav"}

    assert size == byte_size(wav) and data_size == byte_size(data)
    assert binary_part(data, 0, byte_size(pcm)) == pcm
    assert rem(div(data_size, 2), 1_152) == 0
  end

  test "more words than a second of speech can hold are refused" do
    # A second of speech, then two of silence, which hold no words.
    pcm = :binary.copy(<<1_000::signed-little-16>>, 16_000) <> :binary.copy(<<0, 0>>, 32_000)

    made_up =
      "Help me update my project schedule on Notion and check for new notifications on GitHub."

    assert {:error, :asr_words_exceed_audio} = dictate(pcm, made_up)

    assert {:error, :asr_words_exceed_audio} =
             dictate(pcm, "帮我把 Comma 那个群里的消息转发到 Slack 的通知频道里面去。")

    assert {:ok, "好的，谢谢"} = dictate(pcm, "好的，谢谢")
  end
end
