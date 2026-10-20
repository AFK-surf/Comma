defmodule Salix.Bindings.MeetingSummaryTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

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
      do: {:ok, SystemsRuntime.fetch_env!(:salix_web, :meeting_summary_test_transcript)}

    @impl true
    def stat_workspace(_agent_id, _path) do
      transcript = SystemsRuntime.fetch_env!(:salix_web, :meeting_summary_test_transcript)
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
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:meeting_audio_transcriber, agent_id, path}
      )

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

  defmodule RaisingPlatformModelsS3 do
    @behaviour SalixStore.S3

    @impl true
    def get("ctl/system/platform_models.json", _opts),
      do: raise("platform model storage crashed")

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

    post("/chat/completions", do: respond(conn))
    # A platform Profile's endpoint ends in /v1.
    post("/v1/chat/completions", do: respond(conn))

    match _ do
      Plug.Conn.send_resp(conn, 404, "mock: not found")
    end

    defp respond(conn) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      if pid = SystemsRuntime.PersistentTerm.get({__MODULE__, :test_pid}, nil) do
        SystemsRuntime.Proc.send(pid, {:summary_provider_request, req})
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
    test "falls back to the current agent/default template and its token budget" do
      prev_template = SystemsRuntime.get_env(:comma_core, :default_agent_template)
      prev_summary_template = SystemsRuntime.get_env(:salix_web, :meeting_summary_template)
      prev_skip_metering = SystemsRuntime.get_env(:salix_web, :meeting_summary_skip_metering)

      SystemsRuntime.PersistentTerm.put(
        {MockSummaryProvider, :test_pid},
        SystemsRuntime.Proc.self()
      )

      SystemsRuntime.delete_env(:salix_web, :meeting_summary_template)

      on_exit(fn ->
        SystemsRuntime.PersistentTerm.erase({MockSummaryProvider, :test_pid})

        if is_nil(prev_template) do
          SystemsRuntime.delete_env(:comma_core, :default_agent_template)
        else
          SystemsRuntime.put_env(:comma_core, :default_agent_template, prev_template)
        end

        restore_env(:salix_web, :meeting_summary_template, prev_summary_template)

        if is_nil(prev_skip_metering) do
          SystemsRuntime.delete_env(:salix_web, :meeting_summary_skip_metering)
        else
          SystemsRuntime.put_env(:salix_web, :meeting_summary_skip_metering, prev_skip_metering)
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

      SystemsRuntime.put_env(:salix_web, :meeting_summary_skip_metering, true)

      SystemsRuntime.put_env(:comma_core, :default_agent_template, %{
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

      settle_receive({:summary_provider_request, req})
      assert req["model"] == "mock-model"
      assert req["max_tokens"] == 65_536
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
  end

  describe "prepare_context/1" do
    test "returns the exact captions-plus-chat transcript used by summarize/2" do
      previous_asr = SystemsRuntime.get_env(:salix_web, :meeting_asr_template)
      SystemsRuntime.delete_env(:salix_web, :meeting_asr_template)

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
  end

  describe "asr_telemetry_outcome/1" do
  end

  describe "prepare_context/3 canonical ASR wiring" do
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
  end

  describe "generic ASR boundary" do
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

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

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
