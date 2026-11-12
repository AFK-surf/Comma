defmodule SalixLlm.TranscribeTest do
  use SystemsClock.Case, async: true

  alias SalixLlm.Transcribe

  defmodule SlowPreprocessingChunker do
    def with_mp3_chunks(audio, _source_filename, callback, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:chunker_deadline, opts[:deadline_ms]}
      )

      SystemsRuntime.Proc.sleep(25)

      path =
        Path.join(
          System.tmp_dir!(),
          "salix-deadline-chunk-#{SystemsRuntime.Proc.unique_integer([:positive])}.mp3"
        )

      File.write!(path, audio)

      try do
        callback.([
          %{
            index: 0,
            offset_seconds: 0,
            path: path,
            format: "mp3",
            source_duration_seconds: 1
          }
        ])
      after
        File.rm(path)
      end
    end
  end

  defmodule StreamingChunker do
    def with_mp3_chunks_stream(stream, source_size, _source_filename, callback, opts) do
      bytes = stream |> Enum.to_list() |> IO.iodata_to_binary()

      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:streaming_chunker_input, byte_size(bytes), source_size, opts[:deadline_ms]}
      )

      path =
        Path.join(
          System.tmp_dir!(),
          "salix-streaming-chunk-#{SystemsRuntime.Proc.unique_integer([:positive])}.mp3"
        )

      File.write!(path, bytes)

      try do
        callback.([
          %{
            index: 0,
            offset_seconds: 0,
            path: path,
            format: "mp3",
            source_duration_seconds: 7
          }
        ])
      after
        File.rm(path)
      end
    end
  end

  # Cuts a failed chunk "a|b|c" into one-minute parts "a", "b" and "c".
  defmodule PartChunker do
    def with_mp3_chunks(audio, "chunk.mp3", callback, segment_seconds: 60) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "salix-part-chunks-#{SystemsRuntime.Proc.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      parts =
        audio
        |> String.split("|")
        |> Enum.with_index()
        |> Enum.map(fn {contents, index} ->
          path = Path.join(dir, "part-#{index}.mp3")
          File.write!(path, contents)
          %{index: index, offset_seconds: index * 60, path: path, format: "mp3"}
        end)

      try do
        callback.(parts)
      after
        File.rm_rf(dir)
      end
    end
  end

  defmodule UncutChunker do
    def with_mp3_chunks(_audio, _source_filename, _callback, _opts), do: {:error, :ffmpeg_failed}
  end

  defmodule OutOfOrderChunker do
    def with_mp3_chunks(_audio, _source_filename, callback, _opts) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "salix-manifest-chunks-#{SystemsRuntime.Proc.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      chunks = [
        chunk(dir, 2, 600, "third"),
        chunk(dir, 0, 0, "first"),
        chunk(dir, 1, 300, "silence")
      ]

      try do
        callback.(chunks)
      after
        File.rm_rf(dir)
      end
    end

    defp chunk(dir, index, offset_seconds, contents) do
      path = Path.join(dir, "chunk-#{index}.mp3")
      File.write!(path, contents)

      %{
        index: index,
        offset_seconds: offset_seconds,
        path: path,
        format: "mp3",
        source_duration_seconds: 901
      }
    end
  end

  describe "accumulate_content/1" do
    test "folds SSE delta.content, skipping [DONE] and extra_content (gemini thought sig)" do
      sse = ~S"""
      data: {"choices":[{"delta":{"content":"[00:00] Speaker 1: 你好。","role":"assistant"},"index":0}]}

      data: {"choices":[{"delta":{"content":"\n[00:05] Speaker 2: 好的，我这边没有要同步的。"},"index":0}]}

      data: {"choices":[{"delta":{"extra_content":"c2lnbmF0dXJlLWJsb2I=","role":"assistant"},"finish_reason":"stop","index":0}]}

      data: [DONE]
      """

      assert Transcribe.accumulate_content(sse) ==
               "[00:00] Speaker 1: 你好。\n[00:05] Speaker 2: 好的，我这边没有要同步的。"
    end

    test "handles a plain (non-stream) chat-completions JSON body" do
      body = %{"choices" => [%{"message" => %{"content" => "  hello world  "}}]}
      assert Transcribe.accumulate_content(body) == "hello world"
    end

    test "ignores malformed / non-data lines" do
      assert Transcribe.accumulate_content("some\nrandom\ntext") == ""
      assert Transcribe.accumulate_content("data: not-json\n") == ""
      assert Transcribe.accumulate_content(%{}) == ""
    end
  end

  describe "transcribe/4 guards" do
    test "errors when config is incomplete" do
      assert {:error, :asr_base_url_missing} = Transcribe.transcribe(%{}, "AAAA", "mp3", "p")

      assert {:error, :asr_model_missing} =
               Transcribe.transcribe(%{"base_url" => "http://x/v1"}, "AAAA", "mp3", "p")

      assert {:error, :asr_api_key_missing} =
               Transcribe.transcribe(
                 %{"base_url" => "http://x/v1", "model" => "gemini-audio"},
                 "AAAA",
                 "mp3",
                 "p"
               )

      assert {:error, :asr_audio_empty} =
               Transcribe.transcribe(
                 %{"base_url" => "http://x/v1", "model" => "gemini-audio", "api_key" => "k"},
                 "",
                 "mp3",
                 "p"
               )
    end
  end

  describe "transcribe/4 provider completion" do
    test "requires an explicit successful finish reason for plain JSON responses" do
      for finish_reason <- ["stop", "end_turn"] do
        body =
          %{
            "choices" => [
              %{
                "message" => %{"content" => "[00:00] Speaker: complete"},
                "finish_reason" => finish_reason
              }
            ]
          }

        assert {:ok, "[00:00] Speaker: complete"} = Transcribe.complete_content(body)
      end

      for body <- [
            %{
              "choices" => [
                %{
                  "message" => %{"content" => "[00:00] Speaker: partial"},
                  "finish_reason" => nil
                }
              ]
            },
            %{
              "choices" => [
                %{
                  "message" => %{"content" => "[00:00] Speaker: partial"},
                  "finish_reason" => ""
                }
              ]
            },
            %{
              "choices" => [
                %{"message" => %{"content" => "[00:00] Speaker: partial"}}
              ]
            }
          ] do
        assert {:error, :asr_response_incomplete} = Transcribe.complete_content(body)
      end
    end

    test "accepts either an SSE stop reason or [DONE] as an explicit successful terminator" do
      stopped = """
      data: {"choices":[{"delta":{"content":"[00:00] Speaker: complete"},"finish_reason":null,"index":0}]}

      data: {"choices":[{"delta":{},"finish_reason":"stop","index":0}]}
      """

      done = """
      data: {"choices":[{"delta":{"content":"[00:00] Speaker: complete"},"finish_reason":null,"index":0}]}

      data: [DONE]
      """

      assert {:ok, "[00:00] Speaker: complete"} = Transcribe.complete_content(stopped)
      assert {:ok, "[00:00] Speaker: complete"} = Transcribe.complete_content(done)
    end

    test "rejects an SSE stream that reaches EOF without an explicit terminator" do
      body = """
      data: {"choices":[{"delta":{"content":"[00:00] Speaker: partial"},"finish_reason":null,"index":0}]}
      """

      assert {:error, :asr_stream_incomplete} = Transcribe.complete_content(body)
    end

    test "rejects malformed JSON in an SSE data frame even when other frames are complete" do
      body = """
      data: {"choices":[{"delta":{"content":"[00:00] Speaker: partial"},"finish_reason":null,"index":0}]}

      data: {"choices":[

      data: [DONE]
      """

      assert {:error, :asr_malformed_sse} = Transcribe.complete_content(body)
    end

    test "rejects provider error events without exposing provider payloads" do
      for body <- [
            """
            data: {"choices":[{"delta":{"content":"[00:00] Speaker: partial"},"finish_reason":null,"index":0}]}

            data: {"type":"error","error":{"message":"sensitive provider detail"}}

            data: [DONE]
            """,
            """
            event: error
            data: {"message":"sensitive provider detail"}

            data: [DONE]
            """
          ] do
        assert {:error, :asr_provider_error} = Transcribe.complete_content(body)
      end

      assert {:error, :asr_provider_error} = Transcribe.complete_content(%{"error" => %{}})
    end

    test "rejects JSON transcripts with any explicit non-success finish reason" do
      for reason <- ["length", "max_tokens", "content_filter", "tool_calls", "MAX_TOKENS"] do
        body =
          %{
            "choices" => [
              %{
                "message" => %{"content" => "[00:00] Speaker: partial"},
                "finish_reason" => reason
              }
            ]
          }

        assert Transcribe.accumulate_content(body) == "[00:00] Speaker: partial"

        assert {:error, {:asr_incomplete_transcript, ^reason}} =
                 Transcribe.complete_content(body)
      end
    end

    test "rejects SSE transcripts with any explicit non-success finish reason" do
      for reason <- ["length", "max_tokens", "content_filter", "tool_calls", "MAX_TOKENS"] do
        body = """
        data: {"choices":[{"delta":{"content":"[00:00] Speaker: partial"},"finish_reason":null,"index":0}]}

        data: {"choices":[{"delta":{},"finish_reason":"#{reason}","index":0}]}

        data: [DONE]
        """

        assert Transcribe.accumulate_content(body) == "[00:00] Speaker: partial"

        assert {:error, {:asr_incomplete_transcript, ^reason}} =
                 Transcribe.complete_content(body)
      end
    end
  end

  describe "transcribe_chunks/4" do
    test "merges complete chunk results in index order and rebases local timestamps" do
      chunks = test_chunks(["first", "second"], [0, 300])

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        case Base.decode64!(audio_b64) do
          "first" ->
            SystemsRuntime.Proc.sleep(40)
            {:ok, "[00:02] Alice: first"}

          "second" ->
            {:ok, "[00:02] Bob: second"}
        end
      end

      assert {:ok, transcript} =
               Transcribe.transcribe_chunks(%{}, chunks, "prompt",
                 transcribe_fun: transcribe,
                 max_concurrency: 2
               )

      assert transcript ==
               "[00:00:02] Alice: first\n[00:05:02] Bob: second"
    end

    test "one failed chunk fails the complete batch without returning partial text" do
      chunks = test_chunks(["first", "broken", "third"], [0, 300, 600])

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        case Base.decode64!(audio_b64) do
          "broken" -> {:error, {:asr_http, 503, "unavailable"}}
          value -> {:ok, "[00:01] Speaker: #{value}"}
        end
      end

      assert {:error, {:asr_chunk_failed, 1, {:asr_http, 503, "unavailable"}}} =
               Transcribe.transcribe_chunks(%{}, chunks, "prompt",
                 transcribe_fun: transcribe,
                 max_concurrency: 2,
                 part_chunker: UncutChunker
               )
    end

    test "a failed chunk is asked again as one-minute parts, and its parts' words take its place" do
      chunks = test_chunks(["first", "loop|b|c"], [0, 300])
      test_pid = SystemsRuntime.Proc.self()

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        SystemsRuntime.Proc.send(test_pid, {:asked, Base.decode64!(audio_b64)})

        case Base.decode64!(audio_b64) do
          "loop|b|c" -> {:error, {:asr_incomplete_transcript, "length"}}
          "b" -> {:error, :asr_empty_transcript}
          value -> {:ok, "[00:01] Speaker: #{value}"}
        end
      end

      assert {:ok, transcript} =
               Transcribe.transcribe_chunks(%{}, chunks, "prompt",
                 transcribe_fun: transcribe,
                 part_chunker: PartChunker
               )

      assert transcript ==
               "[00:00:01] Speaker: first\n[00:05:01] Speaker: loop\n[00:07:01] Speaker: c"

      for audio <- ["first", "loop|b|c", "loop", "b", "c"], do: assert_received({:asked, ^audio})
      refute_received {:asked, _}
    end

    test "a part that fails too fails the complete batch" do
      chunks = test_chunks(["first", "a|bad"], [0, 300])

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        case Base.decode64!(audio_b64) do
          "first" -> {:ok, "[00:01] Speaker: first"}
          "a" -> {:ok, "[00:01] Speaker: a"}
          _failing -> {:error, {:asr_http, 503, "unavailable"}}
        end
      end

      assert {:error,
              {:asr_chunk_failed, 1, {:asr_part_failed, 1, {:asr_http, 503, "unavailable"}}}} =
               Transcribe.transcribe_chunks(%{}, chunks, "prompt",
                 transcribe_fun: transcribe,
                 part_chunker: PartChunker
               )
    end

    test "a declined chunk is asked again before it is cut" do
      [chunk] = test_chunks(["a|b"], [300])
      declines = :counters.new(1, [])
      test_pid = SystemsRuntime.Proc.self()

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        audio = Base.decode64!(audio_b64)
        SystemsRuntime.Proc.send(test_pid, {:asked, audio})

        if audio == "a|b" and :counters.get(declines, 1) < 2 do
          :counters.add(declines, 1, 1)
          {:error, {:asr_incomplete_transcript, "content_filter: OTHER"}}
        else
          {:ok, "[00:01] Alice: #{audio}"}
        end
      end

      assert {:ok, "[00:05:01] Alice: a|b"} =
               Transcribe.transcribe_chunks(%{}, [chunk], "prompt",
                 transcribe_fun: transcribe,
                 part_chunker: PartChunker
               )

      for _ <- 1..3, do: assert_received({:asked, "a|b"})
      refute_received {:asked, _}
    end

    test "declined audio is asked of the fallback model at once, before it is cut" do
      [chunk] = test_chunks(["a|b"], [300])
      test_pid = SystemsRuntime.Proc.self()

      transcribe = fn cfg, audio_b64, "mp3", _prompt ->
        SystemsRuntime.Proc.send(test_pid, {:asked, cfg["model"], Base.decode64!(audio_b64)})

        case cfg["model"] do
          "primary" -> {:error, {:asr_incomplete_transcript, "content_filter: OTHER"}}
          "fallback" -> {:ok, "[00:01] Alice: from fallback"}
        end
      end

      cfg = %{"model" => "primary", "fallback_model" => "fallback"}

      assert {:ok, "[00:05:01] Alice: from fallback"} =
               Transcribe.transcribe_chunks(cfg, [chunk], "prompt",
                 transcribe_fun: transcribe,
                 part_chunker: PartChunker
               )

      assert_received {:asked, "primary", "a|b"}
      assert_received {:asked, "fallback", "a|b"}
      refute_received {:asked, _, _}
    end

    test "a part the model declines is noted in the transcript, and the other parts stand" do
      chunks = test_chunks(["first", "a|bad|c"], [0, 300])

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        case Base.decode64!(audio_b64) do
          "a|bad|c" -> {:error, {:asr_incomplete_transcript, "content_filter: OTHER"}}
          "bad" -> {:error, {:asr_incomplete_transcript, "content_filter: OTHER"}}
          value -> {:ok, "[00:01] Speaker: #{value}"}
        end
      end

      assert {:ok, transcript} =
               Transcribe.transcribe_chunks(%{}, chunks, "prompt",
                 transcribe_fun: transcribe,
                 part_chunker: PartChunker
               )

      assert transcript ==
               """
               [00:00:01] Speaker: first
               [00:05:01] Speaker: a
               [00:06:00] (Not transcribed: the transcription model declined this audio until [00:07:00].)
               [00:07:01] Speaker: c\
               """
    end

    test "a declined chunk that cannot be cut is noted, and declined audio alone fails" do
      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        case Base.decode64!(audio_b64) do
          "declined" -> {:error, {:asr_incomplete_transcript, "content_filter"}}
          value -> {:ok, "[00:01] Speaker: #{value}"}
        end
      end

      opts = [transcribe_fun: transcribe, part_chunker: UncutChunker]

      assert {:ok,
              "[00:00:01] Speaker: first\n" <>
                "[00:05:00] (Not transcribed: the transcription model declined this audio until [00:06:00].)"} =
               Transcribe.transcribe_chunks(
                 %{},
                 test_chunks(["first", "declined"], [0, 300]),
                 "prompt",
                 opts
               )

      assert {:error, :asr_declined} =
               Transcribe.transcribe_chunks(%{}, test_chunks(["declined"], [0]), "prompt", opts)
    end

    test "with voice facts, a chunk without speech is not asked and made-up words are dropped" do
      chunks =
        ["quiet", "story", "speech"]
        |> test_chunks([0, 300, 600])
        |> Enum.zip([0.4, 2.0, 30.0])
        |> Enum.map(fn {chunk, voiced} -> Map.put(chunk, :voiced_seconds, voiced) end)

      test_pid = SystemsRuntime.Proc.self()

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        audio = Base.decode64!(audio_b64)
        SystemsRuntime.Proc.send(test_pid, {:asked, audio})

        case audio do
          "story" -> {:ok, "[00:00] Unknown: " <> String.duplicate("Once upon a time. ", 10)}
          "speech" -> {:ok, "[00:03] Alice: hello"}
        end
      end

      assert {:ok, "[00:10:03] Alice: hello"} =
               Transcribe.transcribe_chunks(%{}, chunks, "prompt",
                 transcribe_fun: transcribe,
                 part_chunker: UncutChunker
               )

      for audio <- ["story", "speech"], do: assert_received({:asked, ^audio})
      refute_received {:asked, _}
    end

    test "dictation's lower floor asks a clip of one short word, and none without a voiced sound" do
      chunks =
        ["silence", "word"]
        |> test_chunks([0, 60])
        |> Enum.zip([0.0, 0.4])
        |> Enum.map(fn {chunk, voiced} -> Map.put(chunk, :voiced_seconds, voiced) end)

      test_pid = SystemsRuntime.Proc.self()

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        SystemsRuntime.Proc.send(test_pid, {:asked, Base.decode64!(audio_b64)})
        {:ok, "好的"}
      end

      assert {:ok, "好的"} =
               Transcribe.transcribe_chunks(%{}, chunks, "prompt",
                 transcribe_fun: transcribe,
                 min_voiced_seconds: 0.04
               )

      assert_received {:asked, "word"}
      refute_received {:asked, _}
    end

    test "a transcript that ends long before its chunk's speech is asked again as parts" do
      [chunk] = test_chunks(["a|b"], [300])
      chunk = Map.merge(chunk, %{voiced_seconds: 250.0, speech_end_seconds: 290.0})

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        case Base.decode64!(audio_b64) do
          "a|b" -> {:ok, "[00:10] Alice: a"}
          part -> {:ok, "[00:01] Alice: #{part}"}
        end
      end

      assert {:ok, "[00:05:01] Alice: a\n[00:06:01] Alice: b"} =
               Transcribe.transcribe_chunks(%{}, [chunk], "prompt",
                 transcribe_fun: transcribe,
                 part_chunker: PartChunker
               )
    end

    test "a transcript that ends early stands when its parts fail" do
      [chunk] = test_chunks(["a|b"], [300])
      chunk = Map.merge(chunk, %{voiced_seconds: 250.0, speech_end_seconds: 290.0})

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        case Base.decode64!(audio_b64) do
          "a|b" -> {:ok, "[00:10] Alice: a"}
          _part -> {:error, {:asr_http, 503, "unavailable"}}
        end
      end

      assert {:ok, "[00:05:10] Alice: a"} =
               Transcribe.transcribe_chunks(%{}, [chunk], "prompt",
                 transcribe_fun: transcribe,
                 part_chunker: PartChunker
               )
    end

    test "zero-width characters or an empty code fence are no transcript" do
      chunks = test_chunks(["music", "fence", "speech"], [0, 300, 600])

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        case Base.decode64!(audio_b64) do
          "music" -> {:ok, "\u200B\u200B\uFEFF"}
          "fence" -> {:ok, "```\n```"}
          "speech" -> {:ok, "```text\n[00:03] Alice: hello\n```"}
        end
      end

      assert {:ok, "[00:10:03] Alice: hello"} =
               Transcribe.transcribe_chunks(%{}, chunks, "prompt", transcribe_fun: transcribe)
    end

    test "a token-limited provider response fails its ASR chunk and the complete batch" do
      chunks = test_chunks(["complete", "truncated"], [0, 300])

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        case Base.decode64!(audio_b64) do
          "complete" ->
            Transcribe.complete_content(%{
              "choices" => [
                %{
                  "message" => %{"content" => "[00:01] Speaker: complete"},
                  "finish_reason" => "stop"
                }
              ]
            })

          "truncated" ->
            Transcribe.complete_content(%{
              "choices" => [
                %{
                  "message" => %{"content" => "[00:01] Speaker: partial"},
                  "finish_reason" => "length"
                }
              ]
            })
        end
      end

      assert {:error, {:asr_chunk_failed, 1, {:asr_incomplete_transcript, "length"}}} =
               Transcribe.transcribe_chunks(%{}, chunks, "prompt",
                 transcribe_fun: transcribe,
                 max_concurrency: 2,
                 part_chunker: UncutChunker
               )
    end

    test "a chunk the provider's safety filter stops is logged with its index and cause" do
      chunks = test_chunks(["filtered"], [0])

      transcribe = fn _cfg, _audio_b64, "mp3", _prompt ->
        Transcribe.complete_content(%{
          "choices" => [
            %{"message" => %{"content" => ""}, "finish_reason" => "content_filter: OTHER"}
          ]
        })
      end

      log =
        ExUnit.CaptureLog.capture_log(
          [format: {CommaLog.Formatter, :format}, metadata: :all],
          fn ->
            assert {:error, :asr_declined} =
                     Transcribe.transcribe_chunks(%{}, chunks, "prompt",
                       transcribe_fun: transcribe,
                       part_chunker: UncutChunker
                     )
          end
        )

      assert [%{"level" => "warning", "msg" => msg}] =
               log |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert msg ==
               "ASR chunk failed: index=0 offset_seconds=0 " <>
                 "reason=asr_incomplete_transcript_content_filter: OTHER"
    end

    test "an empty speech chunk is complete, while an entirely empty batch is not" do
      chunks = test_chunks(["silence", "speech"], [0, 300])

      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        case Base.decode64!(audio_b64) do
          "silence" -> {:error, :asr_empty_transcript}
          "speech" -> {:ok, "[00:03] Speaker: hello"}
        end
      end

      assert {:ok, "[00:05:03] Speaker: hello"} =
               Transcribe.transcribe_chunks(%{}, chunks, "prompt", transcribe_fun: transcribe)

      assert {:error, :asr_empty_transcript} =
               Transcribe.transcribe_chunks(%{}, test_chunks(["silence"], [0]), "prompt",
                 transcribe_fun: transcribe
               )
    end

    test "a whole-batch deadline bounds fallback even when many chunks are slow" do
      chunks = test_chunks(["one", "two", "three", "four"], [0, 300, 600, 900])

      slow_transcribe = fn _cfg, _audio_b64, "mp3", _prompt ->
        SystemsRuntime.Proc.sleep(200)
        {:ok, "[00:01] Speaker: eventually"}
      end

      started = System.monotonic_time(:millisecond)

      assert {:error, :asr_batch_timeout} =
               Transcribe.transcribe_chunks(%{}, chunks, "prompt",
                 transcribe_fun: slow_transcribe,
                 max_concurrency: 2,
                 batch_timeout_ms: 20
               )

      assert System.monotonic_time(:millisecond) - started < 150
    end
  end

  describe "the request" do
    test "asks for the reasoning effort the tier names, and none otherwise" do
      cfg = %{"reasoning_effort" => "low"}

      assert %{"reasoning_effort" => "low", "model" => "gemini-audio"} =
               Transcribe.request_body("gemini-audio", cfg, "AAAA", "mp3", "p")

      refute Map.has_key?(
               Transcribe.request_body("gemini-audio", %{}, "AAAA", "mp3", "p"),
               "reasoning_effort"
             )
    end
  end

  describe "hedged/2" do
    # Each request takes the next answer: an answer, or :hang to never answer.
    defp scripted(answers) do
      {:ok, script} = Agent.start_link(fn -> {answers, 0} end)

      fun = fn _cfg, _audio_b64, _format, _prompt ->
        case Agent.get_and_update(script, fn {[next | rest], n} -> {next, {rest, n + 1}} end) do
          # Nothing sends this: the request never answers.
          :hang -> receive(do: (:never -> nil))
          answer -> answer
        end
      end

      {fun, fn -> Agent.get(script, fn {_rest, n} -> n end) end}
    end

    test "a slow request is asked again and the first complete transcript wins" do
      {fun, requests} = scripted([:hang, {:ok, "second"}])
      assert {:ok, "second"} = Transcribe.hedged(fun, 10).(%{}, "AAAA", "mp3", "p")
      assert requests.() == 2

      {fun, requests} = scripted([{:ok, "first"}])
      assert {:ok, "first"} = Transcribe.hedged(fun, 60_000).(%{}, "AAAA", "mp3", "p")
      assert requests.() == 1
    end

    test "a failed request is asked again at once, and two failures return the first" do
      cut = {:error, {:asr_incomplete_transcript, "content_filter"}}
      {fun, _requests} = scripted([cut, {:ok, "whole"}])
      assert {:ok, "whole"} = Transcribe.hedged(fun, 60_000).(%{}, "AAAA", "mp3", "p")

      {fun, requests} = scripted([cut, {:error, :asr_provider_error}])
      assert ^cut = Transcribe.hedged(fun, 60_000).(%{}, "AAAA", "mp3", "p")
      assert requests.() == 2
    end
  end

  describe "transcribe_audio_with_metadata/5" do
    test "retains an ordered, rebased chunk manifest including empty speech chunks" do
      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        case Base.decode64!(audio_b64) do
          "first" -> {:ok, "[00:02] Alice: first"}
          "silence" -> {:error, :asr_empty_transcript}
          "third" -> {:ok, "[00:03] Carol: third"}
        end
      end

      assert {:ok, result} =
               Transcribe.transcribe_audio_with_metadata(%{}, "audio", "audio.ogg", "prompt",
                 chunker: OutOfOrderChunker,
                 transcribe_fun: transcribe,
                 max_concurrency: 2
               )

      assert result == %{
               transcript: "[00:00:02] Alice: first\n[00:10:03] Carol: third",
               duration_seconds: 901,
               chunks: [
                 %{index: 0, offset_seconds: 0, transcript: "[00:00:02] Alice: first"},
                 %{index: 1, offset_seconds: 300, transcript: ""},
                 %{index: 2, offset_seconds: 600, transcript: "[00:10:03] Carol: third"}
               ]
             }
    end

    test "the whole-job deadline includes preprocessing before chunk ASR" do
      test_pid = SystemsRuntime.Proc.self()

      transcribe = fn _cfg, _audio_b64, "mp3", _prompt ->
        SystemsRuntime.Proc.send(test_pid, :chunk_asr_started_after_deadline)
        {:ok, "late transcript"}
      end

      assert {:error, :asr_batch_timeout} =
               Transcribe.transcribe_audio_with_metadata(%{}, "audio", "audio.ogg", "prompt",
                 chunker: SlowPreprocessingChunker,
                 transcribe_fun: transcribe,
                 batch_timeout_ms: 10
               )

      assert_receive {:chunker_deadline, deadline_ms}
      assert is_integer(deadline_ms)
      refute_receive :chunk_asr_started_after_deadline
    end

    test "streams the workspace artifact into preprocessing under the whole-job deadline" do
      transcribe = fn _cfg, audio_b64, "mp3", _prompt ->
        assert Base.decode64!(audio_b64) == "streamed audio"
        {:ok, "[00:01] Speaker: complete"}
      end

      assert {:ok,
              %{
                transcript: "[00:00:01] Speaker: complete",
                duration_seconds: 7,
                chunks: [
                  %{
                    index: 0,
                    offset_seconds: 0,
                    transcript: "[00:00:01] Speaker: complete"
                  }
                ]
              }} =
               Transcribe.transcribe_audio_stream_with_metadata(
                 %{},
                 ["streamed ", "audio"],
                 byte_size("streamed audio"),
                 "audio.ogg",
                 "prompt",
                 chunker: StreamingChunker,
                 transcribe_fun: transcribe
               )

      assert_receive {:streaming_chunker_input, 14, 14, deadline_ms}
      assert is_integer(deadline_ms)
    end
  end

  defp test_chunks(contents, offsets) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "salix-transcribe-test-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    contents
    |> Enum.zip(offsets)
    |> Enum.with_index()
    |> Enum.map(fn {{content, offset}, index} ->
      path = Path.join(dir, "chunk-#{index}.mp3")
      File.write!(path, content)

      %{index: index, offset_seconds: offset, path: path, format: "mp3"}
    end)
  end
end
