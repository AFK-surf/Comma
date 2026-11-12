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

  # 2026-10-29: the recording ASR wrote "Steel.fall" and "Cloud Code" and took
  # names addressed in speech for speakers.
  test "a meeting recording asks for the meeting's own spellings, and no others" do
    stream_fun = fn _scope, _path -> {:ok, ["audio"], 5} end

    assert {:ok, _} =
             AgentAudioTranscriber.transcribe("agent-1", "/meetings/test/audio.ogg",
               config_fun: fn -> {:ok, %{}} end,
               stream_fun: stream_fun,
               transcriber: RecordingTranscriber,
               terms: ["JINFEI YANG", "Zijian Zuo", " ", "CFT", "JINFEI YANG"]
             )

    assert_received {:transcribed, 5, 5, "audio.ogg", prompt}
    assert prompt =~ "Spell these names as written here: JINFEI YANG, Zijian Zuo, CFT."
    # Every customer's meetings go through it, so it names no product itself.
    refute prompt =~ "still.fail"
  end

  # 2026-11-10: a desktop recording wrote the team's people and products by
  # sound ("金飞" for Jimmfly, "Steeltoe" for still.fail).
  test "a desktop recording asks for its Group glossary's names and corrects only the text" do
    stream_fun = fn _scope, _path -> {:ok, ["audio"], 5} end

    glossary_fun = fn "group-1", "tenant-1" ->
      {["still.fail", "Jimmfly"], [{"Speaker", "Talker"}]}
    end

    assert {:ok, result} =
             AgentAudioTranscriber.transcribe("agent-1", "/meetings/test/audio.ogg",
               config_fun: fn -> {:ok, %{}} end,
               stream_fun: stream_fun,
               transcriber: RecordingTranscriber,
               glossary_of: {"group-1", "tenant-1"},
               glossary_fun: glossary_fun
             )

    assert_received {:transcribed, 5, 5, "audio.ogg", prompt}
    assert prompt =~ "still.fail, Jimmfly"
    assert result.transcript == "[00:00:01] Talker: streamed"
    assert [%{transcript: "[00:00:01] Speaker: streamed"}] = result.chunks
  end

  # Spoken Mandarin came back in traditional characters for a zh-CN user
  # (Cue #5141); the audio does not decide the script, the person's locale does.
  test "a desktop recording writes Chinese in the script of the person's locale" do
    stream_fun = fn _scope, _path -> {:ok, ["audio"], 5} end

    prompt_for = fn locale ->
      assert {:ok, _} =
               AgentAudioTranscriber.transcribe("agent-1", "/meetings/test/audio.ogg",
                 config_fun: fn -> {:ok, %{}} end,
                 stream_fun: stream_fun,
                 transcriber: RecordingTranscriber,
                 glossary_of: {"group-1", "tenant-1"},
                 glossary_fun: fn _group, _tenant -> {[], []} end,
                 locale: locale
               )

      assert_received {:transcribed, 5, 5, "audio.ogg", prompt}
      prompt
    end

    assert prompt_for.("zh-TW") =~ "traditional Chinese"
    assert prompt_for.("zh_CN") =~ "simplified Chinese"
    refute prompt_for.("en-US") =~ ~r/(simplified|traditional) Chinese/
  end

  test "a desktop recording whose glossary cannot be read is still transcribed" do
    stream_fun = fn _scope, _path -> {:ok, ["audio"], 5} end

    assert {:ok, %{transcript: "[00:00:01] Speaker: streamed"}} =
             AgentAudioTranscriber.transcribe("agent-1", "/meetings/test/audio.ogg",
               config_fun: fn -> {:ok, %{}} end,
               stream_fun: stream_fun,
               transcriber: RecordingTranscriber,
               glossary_of: {"group-1", "tenant-1"},
               glossary_fun: fn _group, _tenant -> raise "control db unavailable" end
             )

    assert_received {:transcribed, 5, 5, "audio.ogg", prompt}
    refute prompt =~ "Names:"
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
    # A meeting recording keeps the tier's own settings and is cut at pauses.
    assert_received {:asked, %{}, [voice: true]}
    assert {:ok, _} = upload.(purpose: :dictation)
    assert_received {:transcribed, 3, 3, "recording.m4a", dictation_prompt}
    refute dictation_prompt == recording_prompt
    # A person waits for dictation: short reasoning, a request asked again, a bound under 10 s.
    assert_received {:asked, %{"reasoning_effort" => "low"}, opts}
    assert is_function(opts[:transcribe_fun], 4)
    assert opts[:batch_timeout_ms] < 10_000
    # Audio without speech is told from speech before the model is asked.
    assert opts[:voice]
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

  @tag :ffmpeg
  test "dictation without a voiced sound is not asked, and words its speech cannot hold are dropped" do
    test = SystemsRuntime.Proc.self()

    dictate = fn pcm, answer ->
      AgentAudioTranscriber.transcribe_dictation(pcm,
        config_fun: fn -> {:ok, %{}} end,
        transcribe_fun: fn _cfg, _audio, "mp3", _prompt ->
          SystemsRuntime.Proc.send(test, :asked)
          {:ok, answer}
        end
      )
    end

    made_up =
      "Help me update my project schedule on Notion and check for new notifications on GitHub."

    # Three seconds of a quiet room: the model, which would make a request up, is not asked.
    quiet = :binary.copy(<<20::signed-little-16>>, 48_000)
    assert {:error, :asr_empty_transcript} = dictate.(quiet, made_up)
    refute_received :asked

    # A second of speech, then two of silence, which hold no words.
    pcm = :binary.copy(<<1_000::signed-little-16>>, 16_000) <> :binary.copy(<<0, 0>>, 32_000)
    assert {:error, :asr_empty_transcript} = dictate.(pcm, made_up)
    assert_received :asked

    assert {:error, :asr_empty_transcript} =
             dictate.(pcm, "帮我把 Comma 那个群里的消息转发到 Slack 的通知频道里面去。")

    assert {:ok, "好的，谢谢"} = dictate.(pcm, "好的，谢谢")
  end
end
