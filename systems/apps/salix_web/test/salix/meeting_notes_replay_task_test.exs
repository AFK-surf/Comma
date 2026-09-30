defmodule Mix.Tasks.Salix.MeetingNotes.ReplayTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Salix.MeetingNotes.Replay

  defmodule AcceptingReplayProvider do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      system = get_in(request, ["messages", Access.at(0), "content"]) || ""
      user = get_in(request, ["messages", Access.at(1), "content"]) || ""

      {kind, content} =
        if String.contains?(system, "You are a transcript editor") do
          {:calibration, live_caption_section(user)}
        else
          {:summary, Jason.encode!(grounded_summary(user))}
        end

      if pid = :persistent_term.get({__MODULE__, :test_pid}, nil) do
        send(pid, {:replay_provider_call, kind})

        if kind == :summary do
          send(pid, {:summary_chunk_checkpoint_visible, String.contains?(user, "REPLAY_CHUNK_")})
        end
      end

      response = %{
        "choices" => [
          %{
            "message" => %{"content" => content},
            "finish_reason" => "stop",
            "index" => 0
          }
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end

    match _ do
      Plug.Conn.send_resp(conn, 404, "not found")
    end

    defp live_caption_section(user) do
      prefix = "## Live Captions (speaker labels are unverified)\n"
      [_before, rest] = String.split(user, prefix, parts: 2)
      [captions, _asr] = String.split(rest, "\n\n## ASR Transcript", parts: 2)
      String.trim(captions)
    end

    defp grounded_summary(user) do
      %{
        "title" => "Replay",
        "attendees" => [],
        "duration_minutes" => 15,
        "timeline" => [
          %{"time" => "00:01:30", "summary" => "head"},
          %{"time" => "00:05:30", "summary" => "middle"},
          %{"time" => "00:10:30", "summary" => "middle"},
          %{"time" => "00:13:30", "summary" => "tail"}
        ],
        "key_points" => [],
        "action_items" => [
          %{
            "description" => "Complete #{marker(user, "REPLAY_MIDDLE_ACTION_")}",
            "owner" => "REPLAY_OWNER_ID",
            "deadline" => "2099-12-31T17:00:00Z"
          },
          %{
            "description" => "Complete #{marker(user, "REPLAY_LATE_ACTION_")}",
            "owner" => "REPLAY_OWNER_ID",
            "deadline" => "2099-12-31T17:00:00Z"
          },
          %{
            "description" => "Complete #{marker(user, "REPLAY_REPLACEMENT_ACTION_")}",
            "owner" => "REPLAY_OWNER_ID",
            "deadline" => "2099-12-31T17:00:00Z"
          }
        ],
        "decisions" => [
          "Approved #{marker(user, "REPLAY_HEAD_DECISION_")} for REPLAY_SCOPE_BLUE_ONLY",
          "#{marker(user, "REPLAY_NEGATIVE_DECISION_")} REPLAY_SCOPE_DISABLED " <>
            "REPLAY_POLARITY_REJECT"
        ],
        "open_questions" => [],
        "blockers" => []
      }
    end

    defp marker(user, prefix) do
      [marker] = Regex.run(~r/#{prefix}[0-9a-f]{12}/, user)
      marker
    end
  end

  defmodule EchoFailureProvider do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"echoed_private_request" => body}))
    end

    match _ do
      Plug.Conn.send_resp(conn, 404, "not found")
    end
  end

  test "plan-only treats an omitted run-model flag as false and prints no raw input" do
    sentinel = "PRIVATE_TASK_SENTINEL_MUST_NOT_BE_PRINTED"

    input =
      Jason.encode!(%{
        "transcript" =>
          "[00:00] A: first #{sentinel}.\n" <>
            "[00:10] B: second substantive sentence.\n" <>
            "[00:20] A: third substantive sentence.",
        "duration_seconds" => 30
      })

    output = capture_io(input, fn -> Replay.run([]) end)
    report = Jason.decode!(output)

    assert report["mode"] == "plan_only"
    assert length(report["replay"]["probe_ids"]) == 11
    assert report["slicing"]["passed"]
    refute output =~ sentinel
  end

  test "model replay forces all calibration slices before evaluating the summary" do
    :persistent_term.put({AcceptingReplayProvider, :test_pid}, self())
    on_exit(fn -> :persistent_term.erase({AcceptingReplayProvider, :test_pid}) end)

    port = start_provider!(AcceptingReplayProvider, __MODULE__.AcceptingReplayServer)
    config_path = write_config!(port)
    on_exit(fn -> File.rm(config_path) end)
    sentinel = "PRIVATE_MODEL_REPLAY_SENTINEL"
    input = replay_input(sentinel)

    output =
      capture_io(input, fn ->
        Replay.run([
          "--run-model",
          "--agent-id",
          "isolated-replay-agent",
          "--llm-config",
          config_path
        ])
      end)

    report = Jason.decode!(output)
    assert report["passed"]
    assert report["calibration_evaluation"]["passed"]
    assert report["calibration_evaluation"]["mode"] == "chunked"
    assert report["calibration_evaluation"]["planned_chunks"] == 3
    assert report["calibration_evaluation"]["calibrated_chunks"] == 3
    assert report["summary_evaluation"]["passed"]
    refute output =~ sentinel

    assert_receive {:replay_provider_call, :calibration}
    assert_receive {:replay_provider_call, :calibration}
    assert_receive {:replay_provider_call, :calibration}
    assert_receive {:replay_provider_call, :summary}
    assert_receive {:summary_chunk_checkpoint_visible, false}
    refute_receive {:replay_provider_call, _kind}
  end

  test "provider failure prints a safe report before exiting nonzero" do
    port = start_provider!(EchoFailureProvider, __MODULE__.EchoFailureServer)
    config_path = write_config!(port)
    on_exit(fn -> File.rm(config_path) end)
    sentinel = "PRIVATE_PROVIDER_ECHO_SENTINEL"

    output =
      capture_io(replay_input(sentinel), fn ->
        assert_raise Mix.Error, ~r/chunk-calibration acceptance checks/, fn ->
          Replay.run([
            "--run-model",
            "--agent-id",
            "isolated-replay-agent",
            "--llm-config",
            config_path
          ])
        end
      end)

    report = Jason.decode!(output)
    refute report["passed"]
    refute report["calibration_evaluation"]["passed"]
    refute output =~ sentinel
    refute output =~ "echoed_private_request"
  end

  defp start_provider!(plug, name) do
    start_supervised!(
      {Bandit,
       plug: plug,
       port: 0,
       startup_log: false,
       thousand_island_options: [supervisor_options: [name: name]]}
    )

    {:ok, {_address, port}} = ThousandIsland.listener_info(name)
    port
  end

  defp write_config!(port) do
    path =
      Path.join(
        System.tmp_dir!(),
        "meeting-replay-llm-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      Jason.encode!(%{
        "base_url" => "http://127.0.0.1:#{port}",
        "model" => "replay-test-model",
        "api_key" => "test-only-key",
        "max_tokens" => 65_536
      })
    )

    path
  end

  defp replay_input(sentinel) do
    transcript =
      0..59
      |> Enum.map_join("\n", fn index ->
        seconds = index * 15
        minutes = div(seconds, 60) |> Integer.to_string() |> String.pad_leading(2, "0")
        seconds = rem(seconds, 60) |> Integer.to_string() |> String.pad_leading(2, "0")
        "[00:#{minutes}:#{seconds}] Speaker #{rem(index, 3) + 1}: line #{index} #{sentinel}"
      end)

    Jason.encode!(%{"transcript" => transcript, "duration_seconds" => 900})
  end
end
