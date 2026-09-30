defmodule SalixLlm.TranscribeTest do
  use ExUnit.Case, async: true

  alias SalixLlm.Transcribe

  defmodule SlowPreprocessingChunker do
    def with_mp3_chunks(audio, _source_filename, callback, opts) do
      send(self(), {:chunker_deadline, opts[:deadline_ms]})
      Process.sleep(25)

      path =
        Path.join(
          System.tmp_dir!(),
          "salix-deadline-chunk-#{System.unique_integer([:positive])}.mp3"
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
      send(self(), {:streaming_chunker_input, byte_size(bytes), source_size, opts[:deadline_ms]})

      path =
        Path.join(
          System.tmp_dir!(),
          "salix-streaming-chunk-#{System.unique_integer([:positive])}.mp3"
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

  defmodule OutOfOrderChunker do
    def with_mp3_chunks(_audio, _source_filename, callback, _opts) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "salix-manifest-chunks-#{System.unique_integer([:positive])}"
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
            Process.sleep(40)
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
                 max_concurrency: 2
               )
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
                 max_concurrency: 2
               )
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
        Process.sleep(200)
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
      test_pid = self()

      transcribe = fn _cfg, _audio_b64, "mp3", _prompt ->
        send(test_pid, :chunk_asr_started_after_deadline)
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
      Path.join(System.tmp_dir!(), "salix-transcribe-test-#{System.unique_integer([:positive])}")

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
