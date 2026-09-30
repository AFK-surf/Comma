defmodule Mix.Tasks.Salix.SessionWork.AuditTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Salix.SessionWork.Audit

  alias SalixStore.{
    Repo,
    SessionWorkBackfillExpectedCandidates,
    SessionWorkBackfillState,
    SessionWorkCandidates
  }

  setup do
    Repo.query!(
      "TRUNCATE session_work_candidates, session_work_backfill_expected_candidates, " <>
        "session_work_backfill_state"
    )

    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'session_work_candidates_v1'")
    :ok
  end

  test "reports durable progress and terminal verification without mutation" do
    assert {:ok, _state} = SessionWorkBackfillState.load()

    assert {:ok, _state} =
             SessionWorkBackfillState.put(%{
               phase: "verify",
               agent_start_after: "ctl/agents/agent-a.json",
               current_agent_key: "ctl/agents/agent-b.json",
               marker_start_after: "agents/agent-b/session_work_index/internal/session-a.json",
               processed: 7,
               uncovered_authoritative_work: 0,
               projection_gaps: 0
             })

    assert :ok = SessionWorkCandidates.insert(candidate("candidate-a"))

    assert :ok =
             SessionWorkBackfillExpectedCandidates.replace_from_authority(
               candidate("candidate-a")
             )

    assert {:ok,
            %{
              phase: "verify",
              processed: 7,
              postgres_candidates: 1,
              expected_candidates: 1,
              verification_complete: false
            }} = Audit.counts()

    output = capture_io(fn -> Audit.run([]) end)
    assert output =~ "phase: verify"
    assert output =~ "candidate address start_after: {nil, nil, nil}"
    assert output =~ "processed in phase: 7"
    assert output =~ "postgres candidate rows: 1"
    assert output =~ "expected candidate rows: 1"
    assert output =~ "projection_gaps: 0"
    assert output =~ "strategy_version: 5"
    assert output =~ "verification complete: false"

    assert :ok =
             SessionWorkBackfillState.mark_terminal(%{
               "uncovered_authoritative_work" => 0,
               "projection_gaps" => 0
             })

    assert {:ok, %{postgres_candidates: 1, verification_complete: true}} = Audit.counts()
  end

  test "fails closed before release progress is initialized" do
    assert {:error, :not_started} = Audit.counts()
  end

  test "strategy v5 restarts an interrupted v4 cursor and clears stale expectations" do
    assert :ok =
             SessionWorkBackfillExpectedCandidates.replace_from_authority(
               candidate("stale-token")
             )

    Repo.query!("""
    INSERT INTO session_work_backfill_state
      (name, phase, agent_start_after, current_agent_key, marker_start_after,
       uncovered_authoritative_work, processed, projection_gaps, updated_at_ms,
       strategy_version)
    VALUES
      ('session_work_candidates_v1', 'verify', 'ctl/agents/old.json',
       'ctl/agents/current.json', 'agents/current/session_work_index/old.json',
       3, 17, 4, 1, 4)
    """)

    assert {:ok,
            %{
              strategy_version: 5,
              phase: "candidate_backfill",
              candidate_agent_start_after: nil,
              candidate_runtime_kind_start_after: nil,
              candidate_session_start_after: nil,
              agent_start_after: nil,
              current_agent_key: nil,
              marker_start_after: nil,
              uncovered_authoritative_work: 0,
              projection_gaps: 0,
              processed: 0
            }} = SessionWorkBackfillState.load()

    assert {:ok, 0} = SessionWorkBackfillExpectedCandidates.count()
  end

  test "starts only the store boundary from a cold umbrella" do
    assert {:ok, _state} = SessionWorkBackfillState.load()

    script = """
    Mix.Task.run("salix.session_work.audit")

    started =
      Application.started_applications()
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    IO.puts("AUDIT_STARTED_APPS=\#{inspect(started)}")
    IO.puts("SESSION_WORK_RECOVERY=\#{inspect(Process.whereis(SalixAgent.SessionWorkRecovery))}")
    IO.puts("CLUSTER_RECOVERY=\#{inspect(Process.whereis(SalixCluster.Recovery))}")
    """

    systems_root = Path.expand("../../..", __DIR__)
    mix = System.find_executable("mix") || flunk("mix executable is unavailable")

    {output, exit_status} =
      System.cmd(mix, ["run", "--no-start", "-e", script],
        cd: systems_root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert exit_status == 0, output

    assert [_, encoded_apps] = Regex.run(~r/^AUDIT_STARTED_APPS=(.+)$/m, output)
    assert {started_apps, []} = Code.eval_string(encoded_apps)
    assert :salix_store in started_apps
    refute :salix_agent in started_apps
    refute :salix_cluster in started_apps
    refute :comma in started_apps
    assert output =~ "SESSION_WORK_RECOVERY=nil"
    assert output =~ "CLUSTER_RECOVERY=nil"
  end

  defp candidate(token) do
    %{
      "token" => token,
      "agent_id" => "agent-a",
      "runtime_kind" => "internal",
      "session_id" => "session-a",
      "base_revision" => "revision-a",
      "reasons" => ["queued_input"],
      "updated_at" => 1_000
    }
  end
end
