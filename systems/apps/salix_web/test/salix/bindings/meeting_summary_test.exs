defmodule Salix.Bindings.MeetingSummaryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Salix.Bindings.MeetingSummary, as: M
  alias SalixWeb.LLMProxy

  defmodule ReplayProcessLogFormatter do
    @moduledoc false

    def format(%{meta: %{pid: pid}} = event, pid),
      do: :logger_formatter.format(event, %{})

    def format(_event, _pid), do: ""
  end

  defmodule TranscriptArtifactRuntime do
    @behaviour SalixMeet.Ports.AgentRuntime

    @impl true
    def read_workspace(_agent_id, _path),
      do: {:ok, Application.fetch_env!(:salix_web, :meeting_summary_test_transcript)}

    @impl true
    def stat_workspace(_agent_id, _path) do
      transcript = Application.fetch_env!(:salix_web, :meeting_summary_test_transcript)
      {:ok, %{size: byte_size(transcript)}}
    end

    @impl true
    def ensure_agent(_request), do: :ok

    @impl true
    def verify_agent(_request), do: :ok

    @impl true
    def prepare_workspace_write(_agent_id, _path, _data), do: {:error, :unused}

    @impl true
    def stream_workspace_write(_agent_id, _env_id, _dst_path, _src_path),
      do: {:error, :unused}

    @impl true
    def commit_event(_request), do: {:error, :unused}
  end

  defmodule RecordingAudioTranscriber do
    @behaviour SalixAgent.AudioTranscriber

    @impl true
    def transcribe(agent_id, path) do
      send(self(), {:meeting_audio_transcriber, agent_id, path})

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

  defmodule RaisingAudioTranscriber do
    @behaviour SalixAgent.AudioTranscriber

    @impl true
    def transcribe(_agent_id, _path) do
      raise "stream transcriber crashed"
    end
  end

  defmodule RaisingTemplateS3 do
    @behaviour SalixStore.S3

    @impl true
    def get("ctl/templates/raising-review-template.json", _opts),
      do: raise("ASR template storage crashed")

    @impl true
    def get(key, opts), do: SalixStore.S3.Fake.get(key, opts)

    @impl true
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_uploads(prefix, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake
  end

  defmodule MockSummaryProvider do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:summary_provider_request, req})
      end

      summary = %{
        "title" => "Mock meeting summary",
        "attendees" => [],
        "duration_minutes" => 1,
        "timeline" => [],
        "key_points" => ["The team discussed the meeting summary token budget."],
        "action_items" => [],
        "decisions" => [],
        "open_questions" => [],
        "blockers" => []
      }

      resp = %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(summary)}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 10, "total_tokens" => 20}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(resp))
    end

    match _ do
      Plug.Conn.send_resp(conn, 404, "mock: not found")
    end
  end

  defmodule EchoErrorProvider do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"echoed_request" => body}))
    end

    match _ do
      Plug.Conn.send_resp(conn, 404, "not found")
    end
  end

  describe "summarize/1" do
    @tag :replay_log_capture
    test "privacy-safe replay never logs a provider error body that echoes transcript text" do
      start_supervised!(
        {Bandit,
         plug: EchoErrorProvider,
         port: 0,
         startup_log: false,
         thousand_island_options: [supervisor_options: [name: __MODULE__.EchoErrorServer]]}
      )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(__MODULE__.EchoErrorServer)
      sentinel = "PRIVATE_REPLAY_SENTINEL_MUST_NOT_REACH_LOGS"

      state = %{
        "meeting_id" => "privacy-safe-replay",
        "meeting_agent_id" => "isolated-replay-agent",
        "title" => "Private replay",
        "captions" => []
      }

      transcript =
        "[00:00] Speaker: #{sentinel} with enough substantive evidence.\n" <>
          "[00:10] Speaker: second substantive sentence for the evidence gate.\n" <>
          "[00:20] Speaker: third substantive sentence for the evidence gate."

      context = %{
        "transcript" => transcript,
        "captions_transcript" => transcript,
        "asr_transcript" => "",
        "duration_seconds" => 30
      }

      llm = %{
        "model" => "mock-model",
        "base_url" => "http://127.0.0.1:#{port}",
        "api_key" => "test-key",
        "max_tokens" => 1_000
      }

      {replay_log, log} =
        capture_replay_logs(fn ->
          Task.async(fn -> Logger.debug("unrelated background database log") end)
          |> Task.await()

          assert :skip = M.replay_summary(state, context, llm)
        end)

      assert log =~ "unrelated background database log"
      refute log =~ sentinel
      assert replay_log == ""
    end

    @tag :replay_log_capture
    test "replay silence is process-scoped but privacy evidence includes other processes" do
      for level <- [:debug, :info, :warning, :error] do
        {replay_log, log} =
          capture_replay_logs(fn ->
            Logger.log(level, "replay caller log")

            Task.async(fn -> Logger.log(level, "background privacy sentinel") end)
            |> Task.await()
          end)

        assert replay_log =~ "replay caller log"
        refute replay_log =~ "background privacy sentinel"
        assert log =~ "replay caller log"
        assert log =~ "background privacy sentinel"
      end
    end

    test "falls back to the current agent/default template and its token budget" do
      prev_template = Application.get_env(:comma_core, :default_agent_template)
      prev_summary_template = Application.get_env(:salix_web, :meeting_summary_template)
      prev_skip_metering = Application.get_env(:salix_web, :meeting_summary_skip_metering)
      :persistent_term.put({MockSummaryProvider, :test_pid}, self())
      Application.delete_env(:salix_web, :meeting_summary_template)

      on_exit(fn ->
        :persistent_term.erase({MockSummaryProvider, :test_pid})

        if is_nil(prev_template) do
          Application.delete_env(:comma_core, :default_agent_template)
        else
          Application.put_env(:comma_core, :default_agent_template, prev_template)
        end

        restore_env(:salix_web, :meeting_summary_template, prev_summary_template)

        if is_nil(prev_skip_metering) do
          Application.delete_env(:salix_web, :meeting_summary_skip_metering)
        else
          Application.put_env(:salix_web, :meeting_summary_skip_metering, prev_skip_metering)
        end
      end)

      start_supervised!(
        {Bandit,
         plug: MockSummaryProvider,
         port: 0,
         startup_log: false,
         thousand_island_options: [supervisor_options: [name: __MODULE__.MockSummaryServer]]}
      )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(__MODULE__.MockSummaryServer)

      Application.put_env(:salix_web, :meeting_summary_skip_metering, true)

      Application.put_env(:comma_core, :default_agent_template, %{
        "model" => "mock-model",
        "max_tokens" => 65_536,
        "provider_config" => %{
          "base_url" => "http://127.0.0.1:#{port}",
          "api_key" => "test-key"
        }
      })

      state = %{
        "meeting_id" => "summary-token-budget-test",
        "meeting_agent_id" => "missing-agent-uses-default-template",
        "title" => "Token budget discussion",
        "captions" => [
          %{
            "speaker" => "Alice",
            "text" =>
              "We need meeting summaries to use the configured model token budget rather than a small hard cap.",
            "timestamp" => 1000
          },
          %{
            "speaker" => "Bob",
            "text" =>
              "Long transcripts should still produce the full structured JSON summary without being cut off early.",
            "timestamp" => 1010
          },
          %{
            "speaker" => "Alice",
            "text" => "Please verify the provider request uses the template max token value.",
            "timestamp" => 1020
          }
        ]
      }

      assert {:ok, summary} = M.summarize(state)
      assert summary["title"] == "Mock meeting summary"

      assert_receive {:summary_provider_request, req}, 2_000
      assert req["model"] == "mock-model"
      assert req["max_tokens"] == 65_536
      refute req["max_tokens"] == 2_000
    end

    test "configured summary template takes priority without changing generic agent resolution" do
      prev_template = Application.get_env(:comma_core, :default_agent_template)
      prev_summary_template = Application.get_env(:salix_web, :meeting_summary_template)
      prev_skip_metering = Application.get_env(:salix_web, :meeting_summary_skip_metering)
      :persistent_term.put({MockSummaryProvider, :test_pid}, self())

      on_exit(fn ->
        :persistent_term.erase({MockSummaryProvider, :test_pid})
        restore_env(:comma_core, :default_agent_template, prev_template)
        restore_env(:salix_web, :meeting_summary_template, prev_summary_template)
        restore_env(:salix_web, :meeting_summary_skip_metering, prev_skip_metering)
      end)

      start_supervised!(
        {Bandit,
         plug: MockSummaryProvider,
         port: 0,
         startup_log: false,
         thousand_island_options: [
           supervisor_options: [name: __MODULE__.DedicatedSummaryServer]
         ]}
      )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(__MODULE__.DedicatedSummaryServer)
      base_url = "http://127.0.0.1:#{port}"
      template_id = "meeting-summary-#{System.unique_integer([:positive])}"

      assert {:ok, _template} =
               SalixAgent.Templates.create(%{
                 "template_id" => template_id,
                 "name" => "Dedicated meeting summary",
                 "model" => "summary-model",
                 "max_tokens" => 12_345,
                 "provider_config" => %{
                   "base_url" => base_url,
                   "api_key" => "summary-key"
                 }
               })

      Application.put_env(:salix_web, :meeting_summary_skip_metering, true)
      Application.put_env(:salix_web, :meeting_summary_template, template_id)

      Application.put_env(:comma_core, :default_agent_template, %{
        "model" => "generic-default-model",
        "max_tokens" => 2_048,
        "provider_config" => %{
          "base_url" => base_url,
          "api_key" => "default-key"
        }
      })

      agent_id = "missing-agent-uses-dedicated-summary-template"

      state = %{
        "meeting_id" => "dedicated-summary-template-test",
        "meeting_agent_id" => agent_id,
        "title" => "Dedicated summary model",
        "captions" => [
          %{
            "speaker" => "Alice",
            "text" => "Use a dedicated model for the final structured meeting notes.",
            "timestamp" => 1_000
          },
          %{
            "speaker" => "Bob",
            "text" => "Keep the live meeting copilot on the meeting agent template.",
            "timestamp" => 1_010
          },
          %{
            "speaker" => "Alice",
            "text" => "The summary template should take priority only in this binding.",
            "timestamp" => 1_020
          }
        ]
      }

      assert {:ok, summary} = M.summarize(state)
      assert summary["title"] == "Mock meeting summary"

      assert_receive {:summary_provider_request, req}, 2_000
      assert req["model"] == "summary-model"
      assert req["max_tokens"] == 12_345

      assert {:ok, generic_llm} = LLMProxy.resolve_llm(agent_id)
      assert generic_llm["model"] == "generic-default-model"
      assert generic_llm["max_tokens"] == 2_048

      Application.put_env(
        :salix_web,
        :meeting_summary_template,
        "missing-dedicated-summary-template"
      )

      assert {:ok, fallback_summary} =
               M.summarize(%{state | "meeting_id" => "summary-template-fallback-test"})

      assert fallback_summary["title"] == "Mock meeting summary"
      assert_receive {:summary_provider_request, fallback_req}, 2_000
      assert fallback_req["model"] == "generic-default-model"
      assert fallback_req["max_tokens"] == 2_048
    end

    test "uses rich raw ASR when canonical captions are short and keeps both sources distinct" do
      previous_template = Application.get_env(:comma_core, :default_agent_template)
      previous_skip_metering = Application.get_env(:salix_web, :meeting_summary_skip_metering)
      :persistent_term.put({MockSummaryProvider, :test_pid}, self())

      on_exit(fn ->
        :persistent_term.erase({MockSummaryProvider, :test_pid})
        restore_env(:comma_core, :default_agent_template, previous_template)
        restore_env(:salix_web, :meeting_summary_skip_metering, previous_skip_metering)
      end)

      start_supervised!(
        {Bandit,
         plug: MockSummaryProvider,
         port: 0,
         startup_log: false,
         thousand_island_options: [supervisor_options: [name: __MODULE__.DualSourceServer]]}
      )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(__MODULE__.DualSourceServer)
      Application.put_env(:salix_web, :meeting_summary_skip_metering, true)

      Application.put_env(:comma_core, :default_agent_template, %{
        "model" => "mock-model",
        "max_tokens" => 65_536,
        "provider_config" => %{
          "base_url" => "http://127.0.0.1:#{port}",
          "api_key" => "test-key"
        }
      })

      state = %{
        "meeting_id" => "dual-source-summary-test",
        "meeting_agent_id" => "missing-agent-uses-default-template",
        "title" => "Grounded summary",
        "captions" => []
      }

      context = %{
        "version" => 2,
        "source" => "captions",
        "transcript" => "[00:01] Alice: SDK United",
        "captions_transcript" => "[00:01] Alice: SDK United",
        "duration_seconds" => 125,
        "asr_transcript" =>
          "[00:00:01] Unknown: the SDK service needs a prototype.\n" <>
            "[00:00:08] Unknown: preserve both raw evidence sources.\n" <>
            "[00:00:14] Unknown: do not invent a person or an owner."
      }

      assert {:ok, summary} = M.summarize(state, context)
      assert summary["duration_minutes"] == 2
      assert_receive {:summary_provider_request, req}, 2_000

      user = get_in(req, ["messages", Access.at(1), "content"])
      assert user =~ "Actual duration: 2 minutes"

      assert length(Regex.scan(~r/SDK United/, user)) == 1
      assert user =~ "[00:00:01] Unknown: the SDK service"
    end
  end

  describe "build_transcript/1" do
    test "renders [MM:SS] Speaker: text with relative timestamps" do
      caps = [
        %{"speaker" => "Alice", "text" => "大家好，欢迎参加周会。", "timestamp" => 1000},
        %{"speaker" => "Bob", "text" => "好的，我这周在看接口。", "timestamp" => 1006}
      ]

      t = M.build_transcript(caps)
      assert String.starts_with?(t, "[00:00] Alice: 大家好")
      assert String.contains?(t, "\n[00:06] Bob: 好的")
    end

    test "omits speaker prefix when speaker is blank (timestamp prefix still present)" do
      caps = [%{"speaker" => "", "text" => "只有内容没有说话人。", "timestamp" => 1000}]
      assert M.build_transcript(caps) == "[00:00] 只有内容没有说话人。"
    end

    test "empty captions -> empty transcript" do
      assert M.build_transcript([]) == ""
      assert M.build_transcript([%{"speaker" => "A", "text" => ""}]) == ""
    end

    test "orders timestamped captions chronologically before rendering" do
      captions = [
        %{"speaker" => "Carol", "text" => "third", "timestamp" => 1_020},
        %{"speaker" => "Alice", "text" => "first", "timestamp" => 1_000},
        %{"speaker" => "Bob", "text" => "second", "timestamp" => 1_010}
      ]

      assert M.build_transcript(captions) ==
               "[00:00] Alice: first\n[00:10] Bob: second\n[00:20] Carol: third"
    end

    test "keeps initial silence when an explicit meeting anchor is available" do
      captions = [
        %{"speaker" => "Alice", "text" => "first spoken caption", "timestamp" => 1_010}
      ]

      assert M.build_transcript(captions, 1_000) ==
               "[00:10] Alice: first spoken caption"
    end

    test "keeps only the newest incremental caption while preserving interleaved speech" do
      captions = [
        %{
          "speaker" => "Alice",
          "text" => "这个评估器现在还不太完整",
          "timestamp" => 1_000
        },
        %{"speaker" => "Bob", "text" => "嗯", "timestamp" => 1_002},
        %{
          "speaker" => "Alice",
          "text" => "这个评估器现在还不太完整，需要把确定性评分器补上",
          "timestamp" => 1_020
        }
      ]

      transcript = M.build_transcript(captions, 1_000)

      refute transcript =~ "[00:00] Alice: 这个评估器现在还不太完整\n"

      assert transcript =~
               "[00:20] Alice: 这个评估器现在还不太完整，需要把确定性评分器补上"

      assert transcript =~ "[00:02] Bob: 嗯"
    end

    test "does not collapse distinct same-speaker statements" do
      captions = [
        %{"speaker" => "Alice", "text" => "first independent point", "timestamp" => 1_000},
        %{"speaker" => "Alice", "text" => "second independent point", "timestamp" => 1_010}
      ]

      assert M.build_transcript(captions, 1_000) ==
               "[00:00] Alice: first independent point\n" <>
                 "[00:10] Alice: second independent point"
    end
  end

  describe "prepare_context/1" do
    test "returns the exact captions-plus-chat transcript used by summarize/2" do
      previous_asr = Application.get_env(:salix_web, :meeting_asr_template)
      Application.delete_env(:salix_web, :meeting_asr_template)

      on_exit(fn -> restore_env(:salix_web, :meeting_asr_template, previous_asr) end)

      state = %{
        "meeting_id" => "context-captions-chat",
        "meeting_agent_id" => "agent-1",
        "captions" => [
          %{"speaker" => "Alice", "text" => "Ship the release.", "timestamp" => 100},
          %{"speaker" => "Bob", "text" => "Alice owns it.", "timestamp" => 105}
        ],
        "chats" => [
          %{"direction" => "incoming", "sender" => "Alice", "text" => "Due Friday"},
          %{"direction" => "outgoing", "sender" => "Bot", "text" => "ignored"}
        ]
      }

      expected =
        state["captions"]
        |> M.build_transcript()
        |> M.with_chat(state["chats"])

      assert {:ok, context} = M.prepare_context(state)
      assert context["version"] == 2
      assert context["source"] == "captions"
      assert context["transcript"] == expected
      assert context["captions_transcript"] == expected
      assert context["asr_transcript"] == ""
      assert context["duration_seconds"] == 5
      assert context["transcript_fingerprint"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
    end

    test "uses the joined-to-left boundary when ASR duration is unavailable" do
      previous_asr = Application.get_env(:salix_web, :meeting_asr_template)
      Application.delete_env(:salix_web, :meeting_asr_template)
      on_exit(fn -> restore_env(:salix_web, :meeting_asr_template, previous_asr) end)

      state = %{
        "meeting_id" => "context-runtime-duration",
        "meeting_agent_id" => "agent-1",
        "joined_at" => 1_000,
        "left_at" => 1_601,
        "captions" => [
          %{"speaker" => "Alice", "text" => "The late caption arrived.", "timestamp" => 1_590}
        ]
      }

      assert {:ok, context} = M.prepare_context(state)
      assert context["duration_seconds"] == 601
      assert context["transcript"] == "[09:50] Alice: The late caption arrived."
      assert context["captions_transcript"] == context["transcript"]
    end

    test "emits one bounded ASR fallback event when a configured template is unavailable" do
      previous_asr = Application.get_env(:salix_web, :meeting_asr_template)
      previous_runtime = Application.get_env(:salix_meet, :agent_runtime_mod)
      previous_transcript = Application.get_env(:salix_web, :meeting_summary_test_transcript)
      telemetry_id = {__MODULE__, :meeting_asr_unavailable, make_ref()}
      Application.put_env(:salix_web, :meeting_asr_template, "missing-meeting-asr-template")
      Application.put_env(:salix_meet, :agent_runtime_mod, TranscriptArtifactRuntime)

      Application.put_env(
        :salix_web,
        :meeting_summary_test_transcript,
        "[00:00] Runtime: this must remain fallback-only."
      )

      :ok =
        :telemetry.attach(
          telemetry_id,
          [:salix, :operation, :stop],
          fn _event, measurements, metadata, owner ->
            if metadata.component == "salix_meet" and metadata.operation == "meeting_asr" do
              send(owner, {:meeting_asr_telemetry, measurements, metadata})
            end
          end,
          self()
        )

      on_exit(fn ->
        :telemetry.detach(telemetry_id)
        restore_env(:salix_web, :meeting_asr_template, previous_asr)
        restore_env(:salix_meet, :agent_runtime_mod, previous_runtime)
        restore_env(:salix_web, :meeting_summary_test_transcript, previous_transcript)
      end)

      state = %{
        "meeting_id" => "asr-template-unavailable",
        "meeting_agent_id" => "agent-1",
        "summary" => %{"title" => "Untrusted runtime summary", "action_items" => []},
        "artifacts" => %{"transcript" => %{"path" => "/meetings/runtime/transcript.txt"}},
        "captions" => [
          %{
            "speaker" => "Alice",
            "text" => "The live captions remain available.",
            "timestamp" => 1
          },
          %{
            "speaker" => "Bob",
            "text" => "The configured ASR template is missing.",
            "timestamp" => 2
          },
          %{
            "speaker" => "Alice",
            "text" => "Fall back without hiding the signal.",
            "timestamp" => 3
          }
        ]
      }

      assert {:ok, %{"source" => "captions"}} = M.prepare_context(state)

      assert_receive {:meeting_asr_telemetry, %{duration: duration}, metadata}
      assert is_integer(duration) and duration >= 0
      assert metadata.component == "salix_meet"
      assert metadata.operation == "meeting_asr"
      assert metadata.outcome == "unavailable"
    end

    test "a runtime transcript is canonical only when captions and ASR are unavailable" do
      previous_runtime = Application.get_env(:salix_meet, :agent_runtime_mod)
      previous_transcript = Application.get_env(:salix_web, :meeting_summary_test_transcript)

      Application.put_env(:salix_meet, :agent_runtime_mod, TranscriptArtifactRuntime)

      Application.put_env(
        :salix_web,
        :meeting_summary_test_transcript,
        "[00:00] ASR Speaker: Alice will own the rollout."
      )

      on_exit(fn ->
        restore_env(:salix_meet, :agent_runtime_mod, previous_runtime)
        restore_env(:salix_web, :meeting_summary_test_transcript, previous_transcript)
      end)

      state = %{
        "meeting_id" => "runtime-summary-context",
        "meeting_agent_id" => "agent-1",
        "summary" => %{"title" => "Runtime", "action_items" => []},
        "artifacts" => %{"transcript" => %{"path" => "/meetings/runtime/transcript.txt"}},
        "captions" => [],
        "chats" => [
          %{"direction" => "incoming", "sender" => "Bob", "text" => "Alice is @alice"}
        ]
      }

      assert {:ok, context} = M.prepare_context(state)
      assert context["source"] == "runtime_transcript"
      assert context["transcript"] =~ "ASR Speaker: Alice will own the rollout."
      assert context["transcript"] =~ "In-meeting chat:\nBob: Alice is @alice"
    end
  end

  describe "asr_telemetry_outcome/1" do
    test "keeps availability failures separate from invalid media and result failures" do
      assert M.asr_telemetry_outcome({:error, %Req.TransportError{reason: :timeout}}) ==
               "unavailable"

      assert M.asr_telemetry_outcome({:error, {:asr_http, 429, "ratelimited"}}) ==
               "unavailable"

      assert M.asr_telemetry_outcome({:error, {:asr_http, 503, "unavailable"}}) ==
               "unavailable"

      assert M.asr_telemetry_outcome({:error, {:ffmpeg_failed, 1, "invalid audio"}}) ==
               "error"

      assert M.asr_telemetry_outcome({:error, {:ffprobe_failed, 1, "no audio stream"}}) ==
               "error"
    end
  end

  describe "prepare_context/3 canonical ASR wiring" do
    test "keeps raw ASR canonical when calibration is incomplete or fails" do
      {state, captions_transcript, asr, asr_result} = canonical_asr_fixture()

      calibrations = [
        %{
          "mode" => "chunked",
          "complete" => false,
          "transcript" => "",
          "planned_chunks" => 2,
          "calibrated_chunks" => 1,
          "fallback_chunks" => 1
        },
        %{
          "mode" => "direct",
          "complete" => false,
          "transcript" => "",
          "planned_chunks" => 1,
          "calibrated_chunks" => 0,
          "fallback_chunks" => 1
        }
      ]

      Enum.each(calibrations, fn calibration ->
        assert {:ok, context} =
                 prepare_canonical_asr_context(
                   state,
                   captions_transcript,
                   asr_result,
                   calibration
                 )

        assert context["source"] == "asr"
        assert context["transcript"] == asr
        assert context["captions_transcript"] == captions_transcript
        assert context["asr_transcript"] == asr
      end)
    end

    test "uses valid complete calibration while preserving both raw evidence sources" do
      {state, captions_transcript, asr, asr_result} = canonical_asr_fixture()
      calibrated = "[00:00:01] Alice: complete calibrated ASR content."

      calibration = %{
        "mode" => "direct",
        "complete" => true,
        "transcript" => calibrated,
        "planned_chunks" => 1,
        "calibrated_chunks" => 1,
        "fallback_chunks" => 0
      }

      assert {:ok, context} =
               prepare_canonical_asr_context(
                 state,
                 captions_transcript,
                 asr_result,
                 calibration
               )

      assert context["source"] == "calibrated"
      assert context["transcript"] == calibrated
      assert context["captions_transcript"] == captions_transcript
      assert context["asr_transcript"] == asr
    end

    test "rejects malformed or empty complete calibration on the production selection path" do
      {state, captions_transcript, asr, asr_result} = canonical_asr_fixture()

      calibrations = [
        %{"complete" => true, "transcript" => ""},
        %{"complete" => true, "transcript" => nil},
        %{"complete" => true, "transcript" => []}
      ]

      Enum.each(calibrations, fn calibration ->
        assert {:ok, context} =
                 prepare_canonical_asr_context(
                   state,
                   captions_transcript,
                   asr_result,
                   calibration
                 )

        assert context["source"] == "asr"
        assert context["transcript"] == asr
        assert context["captions_transcript"] == captions_transcript
        assert context["asr_transcript"] == asr
      end)
    end
  end

  describe "generic ASR boundary" do
    test "passes only the meeting agent id and audio path to the transcriber port" do
      previous_transcriber = Application.get_env(:salix_agent, :audio_transcriber_mod)
      Application.put_env(:salix_agent, :audio_transcriber_mod, RecordingAudioTranscriber)

      on_exit(fn ->
        restore_env(:salix_agent, :audio_transcriber_mod, previous_transcriber)
      end)

      state = %{
        "meeting_agent_id" => "agent-1",
        "artifacts" => %{"audio" => %{"path" => "/meetings/test/audio.ogg"}}
      }

      assert {:ok, %{"source" => "asr", "duration_seconds" => 11}} = M.prepare_context(state)
      assert_receive {:meeting_audio_transcriber, "agent-1", "/meetings/test/audio.ogg"}
    end

    test "emits an error outcome before reraising an ASR exception" do
      telemetry_id = {__MODULE__, :meeting_asr_exception, make_ref()}

      :ok =
        :telemetry.attach(
          telemetry_id,
          [:salix, :operation, :stop],
          fn _event, measurements, metadata, owner ->
            if metadata.component == "salix_meet" and metadata.operation == "meeting_asr" do
              send(owner, {:meeting_asr_exception_telemetry, measurements, metadata})
            end
          end,
          self()
        )

      on_exit(fn ->
        :telemetry.detach(telemetry_id)
      end)

      assert_raise RuntimeError, "stream transcriber crashed", fn ->
        M.transcribe_asr_observed(
          "agent-1",
          "/meetings/test/audio.ogg",
          RaisingAudioTranscriber
        )
      end

      assert_receive {:meeting_asr_exception_telemetry, %{duration: duration}, metadata}
      assert is_integer(duration) and duration >= 0
      assert metadata.outcome == "error"
    end

    test "public context preparation observes an ASR config exception before caption fallback" do
      previous_backend = Application.get_env(:salix_store, :s3_backend)
      previous_template = Application.get_env(:salix_web, :meeting_asr_template)
      telemetry_id = {__MODULE__, :meeting_asr_config_exception, make_ref()}

      Application.put_env(:salix_store, :s3_backend, RaisingTemplateS3)
      Application.put_env(:salix_web, :meeting_asr_template, "raising-review-template")

      :ok =
        :telemetry.attach(
          telemetry_id,
          [:salix, :operation, :stop],
          fn _event, measurements, metadata, owner ->
            if metadata.component == "salix_meet" and metadata.operation == "meeting_asr" do
              send(owner, {:meeting_asr_config_exception_telemetry, measurements, metadata})
            end
          end,
          self()
        )

      on_exit(fn ->
        :telemetry.detach(telemetry_id)
        restore_env(:salix_store, :s3_backend, previous_backend)
        restore_env(:salix_web, :meeting_asr_template, previous_template)
      end)

      state = %{
        "meeting_agent_id" => "agent-1",
        "captions" => [
          %{"speaker" => "Alice", "text" => "Captions remain available.", "timestamp" => 1}
        ]
      }

      assert {:ok, %{"source" => "captions", "asr_transcript" => ""}} =
               M.prepare_context(state)

      assert_receive {:meeting_asr_config_exception_telemetry, %{duration: duration}, metadata}
      assert is_integer(duration) and duration >= 0
      assert metadata.outcome == "error"
      refute_receive {:meeting_asr_config_exception_telemetry, _measurements, _metadata}
    end
  end

  describe "sufficient_evidence?/1 (willow gate: >=3 units and >=40 runes)" do
    test "real meeting transcript passes" do
      t =
        Enum.join(
          [
            "[00:00] Alice: 大家好，欢迎参加我们今天的项目周会。",
            "[00:06] Bob: 好的，我这周主要在看接口对接的问题。",
            "[00:12] 第一个是关于会议机器人怎么接入大模型能力。"
          ],
          "\n"
        )

      assert M.sufficient_evidence?(t) == true
    end

    test "too-short transcript fails" do
      assert M.sufficient_evidence?("[00:00] A: hi.") == false
    end

    test "empty transcript fails" do
      assert M.sufficient_evidence?("") == false
    end
  end

  describe "complete_calibration?/3" do
    test "rejects a plausible-looking calibration that stops before the source ends" do
      captions =
        "[00:00] Alice: kickoff.\n[10:00] Bob: the final decision is to ship on Friday."

      asr =
        "[00:00] Unknown: kickoff.\n[10:02] Unknown: the final decision is to ship on Friday."

      partial =
        "[00:00:00] Alice: kickoff with several polished details that look complete but are not."

      complete =
        "[00:00:00] Alice: kickoff.\n[00:10:02] Bob: the final decision is to ship on Friday."

      refute M.complete_calibration?(partial, captions, asr)
      assert M.complete_calibration?(complete, captions, asr)
    end

    test "rejects long output that preserves the tail but omits a source interval" do
      padding = String.duplicate(" detailed evidence", 20)

      captions =
        "[00:00] Alice: opening#{padding}.\n" <>
          "[05:00] Bob: middle#{padding}.\n" <>
          "[10:00] Carol: closing#{padding}."

      asr =
        "[00:02] Unknown: opening#{padding}.\n" <>
          "[05:02] Unknown: middle#{padding}.\n" <>
          "[10:02] Unknown: closing#{padding}."

      missing_middle =
        "[00:01] Alice: opening#{padding}.\n" <>
          "[10:01] Carol: closing#{padding}.\n" <>
          String.duplicate("untimestamped filler ", 35)

      refute M.complete_calibration?(missing_middle, captions, asr)
    end

    test "rejects reordered or out-of-window calibrated timestamps" do
      padding = String.duplicate(" grounded detail", 12)

      captions =
        "[00:00] Alice: opening#{padding}.\n" <>
          "[01:00] Bob: middle#{padding}.\n" <>
          "[02:00] Carol: closing#{padding}."

      asr =
        "[00:01] Unknown: opening#{padding}.\n" <>
          "[01:01] Unknown: middle#{padding}.\n" <>
          "[02:01] Unknown: closing#{padding}."

      reordered =
        "[02:01] Carol: closing#{padding}.\n" <>
          "[01:01] Bob: middle#{padding}.\n" <>
          "[00:01] Alice: opening#{padding}."

      invented_tail =
        "[00:01] Alice: opening#{padding}.\n" <>
          "[01:01] Bob: middle#{padding}.\n" <>
          "[02:01] Carol: closing#{padding}.\n" <>
          "[99:00] Unknown: invented#{padding}."

      refute M.complete_calibration?(reordered, captions, asr)
      refute M.complete_calibration?(invented_tail, captions, asr)
    end
  end

  describe "long transcript calibration" do
    test "keeps small evidence on one direct calibration request" do
      captions = [
        %{"speaker" => "Alice", "text" => "kickoff", "timestamp" => 1_000},
        %{"speaker" => "Bob", "text" => "ship Friday", "timestamp" => 1_010}
      ]

      caption_transcript = M.build_transcript(captions)

      asr =
        "[00:00:00] Unknown: kickoff with enough detail for calibration.\n" <>
          "[00:00:10] Unknown: ship Friday after the final review."

      calibrate = fn caption_window, asr_window ->
        send(self(), {:calibration_window, caption_window, asr_window})

        {:ok,
         "[00:00:00] Alice: kickoff with enough detail for calibration.\n" <>
           "[00:00:10] Bob: ship Friday after the final review."}
      end

      result =
        M.calibrate_transcript(captions, caption_transcript, %{transcript: asr}, calibrate)

      assert result == %{
               "mode" => "direct",
               "complete" => true,
               "transcript" =>
                 "[00:00:00] Alice: kickoff with enough detail for calibration.\n" <>
                   "[00:00:10] Bob: ship Friday after the final review.",
               "planned_chunks" => 1,
               "calibrated_chunks" => 1,
               "fallback_chunks" => 0
             }

      assert_receive {:calibration_window, ^caption_transcript, ^asr}
      refute_receive {:calibration_window, _, _}
    end

    test "rejects a polished head and tail when a middle calibration window falls back" do
      captions = long_window_captions()
      caption_transcript = M.build_transcript(captions)
      asr = long_window_asr()

      calibrate = fn caption_window, asr_window ->
        send(self(), {:calibration_window, caption_window, asr_window})

        cond do
          caption_window =~ "middle caption evidence" ->
            {:error, :timeout}

          caption_window =~ "opening caption evidence" ->
            {:ok, String.replace(caption_window, "caption", "calibrated")}

          true ->
            {:ok, String.replace(caption_window, "caption", "calibrated")}
        end
      end

      result =
        M.calibrate_transcript(
          captions,
          caption_transcript,
          long_asr_metadata(asr),
          calibrate,
          caption_anchor_seconds: 1_000
        )

      assert result == %{
               "mode" => "chunked",
               "complete" => false,
               "transcript" => "",
               "planned_chunks" => 3,
               "calibrated_chunks" => 2,
               "fallback_chunks" => 1
             }

      assert_receive {:calibration_window, opening_captions, opening_asr}
      assert opening_captions =~ "opening caption evidence"
      assert String.starts_with?(opening_captions, "[00:10]")
      refute opening_captions =~ "middle caption evidence"
      assert opening_asr =~ "opening ASR evidence"

      assert_receive {:calibration_window, middle_captions, middle_asr}
      assert middle_captions =~ "middle caption evidence"
      assert String.starts_with?(middle_captions, "[05:10]")
      refute middle_captions =~ "final caption evidence"
      assert middle_asr =~ "middle ASR evidence"

      assert_receive {:calibration_window, final_captions, final_asr}
      assert final_captions =~ "final caption evidence"
      assert String.starts_with?(final_captions, "[10:10]")
      assert final_asr =~ "final ASR evidence"
      refute_receive {:calibration_window, _, _}
    end

    test "accepts ordered chunk calibration only when every planned window is complete" do
      captions = long_window_captions()
      caption_transcript = M.build_transcript(captions)
      asr = long_window_asr()

      calibrate = fn caption_window, _asr_window ->
        {:ok, String.replace(caption_window, "caption", "calibrated")}
      end

      result =
        M.calibrate_transcript(
          captions,
          caption_transcript,
          long_asr_metadata(asr),
          calibrate,
          caption_anchor_seconds: 1_000
        )

      assert result["mode"] == "chunked"
      assert result["complete"]
      assert result["planned_chunks"] == 3
      assert result["calibrated_chunks"] == 3
      assert result["fallback_chunks"] == 0

      transcript = result["transcript"]
      assert length(Regex.scan(~r/opening calibrated evidence/, transcript)) == 1
      assert length(Regex.scan(~r/middle calibrated evidence/, transcript)) == 1
      assert length(Regex.scan(~r/final calibrated evidence/, transcript)) == 1

      assert :binary.match(transcript, "opening calibrated evidence") <
               :binary.match(transcript, "middle calibrated evidence")

      assert :binary.match(transcript, "middle calibrated evidence") <
               :binary.match(transcript, "final calibrated evidence")
    end

    test "never sends an oversized transcript as one request when chunk evidence is missing" do
      captions = [
        %{
          "speaker" => "Alice",
          "text" => String.duplicate("long caption evidence ", 1_100),
          "timestamp" => 1_000
        }
      ]

      caption_transcript = M.build_transcript(captions)
      asr = String.duplicate("long ASR evidence ", 1_200)

      result =
        M.calibrate_transcript(captions, caption_transcript, %{transcript: asr}, fn _, _ ->
          flunk("oversized evidence without a chunk manifest must not reach one LLM request")
        end)

      assert result == %{
               "mode" => "chunked_unavailable",
               "complete" => false,
               "transcript" => "",
               "planned_chunks" => 0,
               "calibrated_chunks" => 0,
               "fallback_chunks" => 0
             }
    end

    test "uses byte thresholds so CJK evidence cannot exceed the legacy request boundary" do
      cjk = String.duplicate("会", 7_000)
      assert String.length(cjk) == 7_000
      assert byte_size(cjk) == 21_000
      assert M.should_chunk_calibration?(cjk, "short ASR")

      result =
        M.calibrate_transcript([], cjk, %{transcript: "short ASR"}, fn _, _ ->
          flunk("CJK evidence above the byte limit must not use direct calibration")
        end)

      assert result["mode"] == "chunked_unavailable"
      refute result["complete"]
    end

    test "fails closed when timestamp-less captions cannot be assigned to a chunk" do
      captions =
        long_window_captions() ++
          [
            %{
              "speaker" => "Dana",
              "text" => "untimestamped caption evidence " <> String.duplicate("delta ", 1_200)
            }
          ]

      caption_transcript = M.build_transcript(captions)
      asr = long_window_asr()

      result =
        M.calibrate_transcript(
          captions,
          caption_transcript,
          long_asr_metadata(asr),
          fn _, _ -> flunk("unanchored captions must fail before any model call") end,
          caption_anchor_seconds: 1_000
        )

      assert result == %{
               "mode" => "chunked",
               "complete" => false,
               "transcript" => "",
               "planned_chunks" => 3,
               "calibrated_chunks" => 0,
               "fallback_chunks" => 3
             }
    end

    test "rejects a chunk manifest that omits the opening audio interval" do
      captions = long_window_captions()
      caption_transcript = M.build_transcript(captions)
      asr = long_window_asr()

      shifted =
        long_asr_metadata(asr)
        |> Map.update!(:chunks, fn chunks ->
          Enum.map(chunks, &Map.update!(&1, :offset_seconds, fn offset -> offset + 300 end))
        end)

      result =
        M.calibrate_transcript(
          captions,
          caption_transcript,
          shifted,
          fn _, _ ->
            flunk("a manifest without offset zero must not calibrate")
          end,
          caption_anchor_seconds: 1_000
        )

      assert result["mode"] == "chunked_unavailable"
      refute result["complete"]
      assert result["planned_chunks"] == 0
    end

    test "initial silence does not shift caption windows to the first caption" do
      [_opening | captions] = long_window_captions()
      caption_transcript = M.build_transcript(captions)
      asr = long_window_asr()

      calibrate = fn caption_window, _asr_window ->
        send(self(), {:aligned_caption_window, caption_window})
        {:ok, String.replace(caption_window, "caption", "calibrated")}
      end

      result =
        M.calibrate_transcript(
          captions,
          caption_transcript,
          long_asr_metadata(asr),
          calibrate,
          caption_anchor_seconds: 1_000
        )

      refute result["complete"]
      assert result["planned_chunks"] == 3
      assert result["calibrated_chunks"] == 2
      assert result["fallback_chunks"] == 1

      assert_receive {:aligned_caption_window, middle_window}
      assert String.starts_with?(middle_window, "[05:10]")
      assert_receive {:aligned_caption_window, final_window}
      assert String.starts_with?(final_window, "[10:10]")
      refute_receive {:aligned_caption_window, _}
    end
  end

  describe "parse_summary/1" do
    test "parses structured JSON into the render shape" do
      json =
        ~s|{"title":"周会","key_points":["要点1","要点2"],"action_items":[{"description":"做X","owner":"张三","deadline":""}],"decisions":["定了A"]}|

      assert {:ok, s} = M.parse_summary(json)
      assert s["title"] == "周会"
      assert s["key_points"] == ["要点1", "要点2"]
      assert hd(s["action_items"]) == %{"description" => "做X", "owner" => "张三", "deadline" => ""}
      assert s["decisions"] == ["定了A"]
    end

    test "strips ```json code fences" do
      assert {:ok, s} = M.parse_summary("```json\n{\"title\":\"T\",\"key_points\":[\"a\"]}\n```")
      assert s["title"] == "T"
      assert s["key_points"] == ["a"]
    end

    test "extracts the JSON object from surrounding prose (preamble/postamble)" do
      raw =
        "Here is the summary:\n{\"title\":\"周会\",\"key_points\":[\"a\",\"b\"]}\nHope this helps!"

      assert {:ok, s} = M.parse_summary(raw)
      assert s["title"] == "周会"
      assert s["key_points"] == ["a", "b"]
    end

    test "normalizes bare-string action items" do
      assert {:ok, s} = M.parse_summary(~s|{"action_items":["纯字符串任务"]}|)
      assert hd(s["action_items"])["description"] == "纯字符串任务"
    end

    test "non-JSON content returns error" do
      assert {:error, _} = M.parse_summary("hello, this is not json")
    end
  end

  describe "with_chat/2 (fold in-meeting chat into the transcript)" do
    test "appends incoming chat and excludes the bot's own outgoing chat" do
      chats = [
        %{"direction" => "incoming", "sender" => "luoan chen", "text" => "记一下明天要交房租"},
        %{"direction" => "outgoing", "sender" => "Cirno", "text" => "📋 已记：明天要交房租。"}
      ]

      t = M.with_chat("[00:00] Alice: 你好。", chats)
      assert String.starts_with?(t, "[00:00] Alice: 你好。")
      assert String.contains?(t, "In-meeting chat:\nluoan chen: 记一下明天要交房租")
      refute String.contains?(t, "已记")
    end

    test "chat-only meeting becomes the transcript and clears the evidence gate" do
      chats = [
        %{"direction" => "incoming", "sender" => "luoan chen", "text" => "@Cirno 在吗"},
        %{"direction" => "incoming", "sender" => "luoan chen", "text" => "记一下明天要交房租和健康保险税"}
      ]

      t = M.with_chat("", chats)
      assert String.starts_with?(t, "In-meeting chat:")
      assert String.contains?(t, "luoan chen: 记一下明天要交房租和健康保险税")
      assert M.sufficient_evidence?(t) == true
    end

    test "no chat leaves the transcript unchanged" do
      assert M.with_chat("[00:00] A: hi.", []) == "[00:00] A: hi."
      assert M.with_chat("[00:00] A: hi.", nil) == "[00:00] A: hi."
    end

    test "blank sender falls back to Unknown; empty-text lines are dropped" do
      chats = [
        %{"direction" => "incoming", "sender" => "", "text" => "有内容"},
        %{"direction" => "incoming", "sender" => "X", "text" => ""}
      ]

      t = M.with_chat("", chats)
      assert String.contains?(t, "Unknown: 有内容")
      refute String.contains?(t, "X: ")
    end
  end

  defp canonical_asr_fixture do
    captions = [
      %{
        "speaker" => "Alice",
        "text" => "captions preserve the raw speaker evidence.",
        "timestamp" => 1_001
      },
      %{
        "speaker" => "Bob",
        "text" => "captions keep the independent closing evidence.",
        "timestamp" => 1_010
      }
    ]

    state = %{
      "meeting_id" => "canonical-asr-production-wiring",
      "meeting_agent_id" => "agent-1",
      "joined_at" => 1_000,
      "captions" => captions
    }

    captions_transcript = M.build_transcript(captions, state["joined_at"])

    asr =
      "[00:00:01] Unknown: preserve the complete audio transcript.\n" <>
        "[00:09:58] Unknown: keep the final follow-up too."

    asr_result = %{
      transcript: asr,
      duration_seconds: 600,
      chunks: [
        %{index: 0, offset_seconds: 0, transcript: asr}
      ]
    }

    {state, captions_transcript, asr, asr_result}
  end

  defp prepare_canonical_asr_context(state, captions_transcript, asr_result, calibration) do
    M.prepare_context(
      state,
      fn received_state ->
        assert received_state == state
        {:ok, asr_result}
      end,
      fn received_state, received_captions, received_caption_transcript, received_asr_result ->
        assert received_state == state
        assert received_captions == state["captions"]
        assert received_caption_transcript == captions_transcript
        assert received_asr_result == asr_result
        calibration
      end
    )
  end

  defp capture_replay_logs(fun) do
    # 仅隔离零日志断言；外层仍捕获所有进程，用于敏感文本检测。
    # Scope silence to the caller; keep all-process evidence for privacy checks.
    with_log(fn ->
      capture_log([formatter: {ReplayProcessLogFormatter, self()}], fun)
    end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp long_window_captions do
    [
      %{
        "speaker" => "Alice",
        "text" => "opening caption evidence " <> String.duplicate("alpha ", 1_200),
        "timestamp" => 1_010
      },
      %{
        "speaker" => "Bob",
        "text" => "middle caption evidence " <> String.duplicate("beta ", 1_200),
        "timestamp" => 1_310
      },
      %{
        "speaker" => "Carol",
        "text" => "final caption evidence " <> String.duplicate("gamma ", 1_200),
        "timestamp" => 1_610
      }
    ]
  end

  defp long_window_asr do
    [
      "[00:00:10] Unknown: opening ASR evidence " <> String.duplicate("alpha ", 1_200),
      "[00:05:10] Unknown: middle ASR evidence " <> String.duplicate("beta ", 1_200),
      "[00:10:10] Unknown: final ASR evidence " <> String.duplicate("gamma ", 1_200)
    ]
    |> Enum.join("\n")
  end

  defp long_asr_metadata(asr) do
    [opening, middle, final] = String.split(asr, "\n")

    %{
      transcript: asr,
      duration_seconds: 900,
      chunks: [
        %{index: 0, offset_seconds: 0, transcript: opening},
        %{index: 1, offset_seconds: 300, transcript: middle},
        %{index: 2, offset_seconds: 600, transcript: final}
      ]
    }
  end
end
