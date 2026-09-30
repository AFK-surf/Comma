defmodule BridgeForTeams.MeetingsReplayTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Meetings, Observability, Orgs, Projects}

  defmodule ReplayClient do
    def replay_meeting_summary(group_id, meeting_id, opts) do
      send(Process.get(:meeting_replay_test_pid), {:replay, group_id, meeting_id, opts})

      {:ok,
       %{
         "mode" => if(opts[:run_model], do: "model_replay", else: "plan_only"),
         "passed" => true,
         "source" => %{"fingerprint" => "sha256:privacy-safe"}
       }}
    end
  end

  setup do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, ReplayClient)
    Process.put(:meeting_replay_test_pid, self())

    on_exit(fn ->
      Process.delete(:meeting_replay_test_pid)

      if previous_client do
        Application.put_env(:bridge_for_teams_core, :salix_client, previous_client)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    {:ok, org} = Orgs.create_org(%{name: "Replay Org", slug: "replay-org"})
    {:ok, project} = Projects.create_project(org.id, %{name: "Replay", slug: "replay"})
    {:ok, actor} = Accounts.create_user(%{email: "replay@example.com", name: "Replay Operator"})

    %{org: org, project: project, actor: actor}
  end

  test "runs once, records bounded audit evidence, and replays idempotently", context do
    assert {:ok, first} =
             Meetings.replay_summary(
               context.org,
               context.project,
               context.actor,
               "meeting-123",
               "request-123"
             )

    assert_receive {:replay, group_id, "meeting-123", [run_model: false]}
    assert group_id == context.project.salix_group_id
    assert first["status"] == "ok"
    assert first["passed"]
    refute first["replayed"]
    refute first["delivery_writes"]

    assert {:ok, second} =
             Meetings.replay_summary(
               context.org,
               context.project,
               context.actor,
               "meeting-123",
               "request-123"
             )

    refute_receive {:replay, _, _, _}
    assert second["run_id"] == first["run_id"]
    assert second["replayed"]

    audits = Observability.list_audit_logs(context.org.id, request_id: "request-123")

    assert Enum.map(audits, & &1.action) |> Enum.sort() ==
             ["meeting.summary_replay.completed", "meeting.summary_replay.started"]

    assert Enum.all?(audits, &(&1.metadata["delivery_writes"] == "false"))
    refute inspect(first) =~ "raw transcript"
  end

  test "same request id cannot change meeting or execution mode", context do
    assert {:ok, _first} =
             Meetings.replay_summary(
               context.org,
               context.project,
               context.actor,
               "meeting-123",
               "request-conflict"
             )

    assert_receive {:replay, _, "meeting-123", [run_model: false]}

    assert {:error, :replay_request_conflict} =
             Meetings.replay_summary(
               context.org,
               context.project,
               context.actor,
               "meeting-456",
               "request-conflict"
             )

    assert {:error, :replay_request_conflict} =
             Meetings.replay_summary(
               context.org,
               context.project,
               context.actor,
               "meeting-123",
               "request-conflict",
               run_model: true
             )

    refute_receive {:replay, _, _, _}
  end

  test "same request id cannot cross project boundaries", context do
    assert {:ok, other_project} =
             Projects.create_project(context.org.id, %{name: "Other Replay", slug: "other-replay"})

    assert {:ok, _first} =
             Meetings.replay_summary(
               context.org,
               context.project,
               context.actor,
               "meeting-123",
               "request-project-conflict"
             )

    assert_receive {:replay, _, "meeting-123", [run_model: false]}

    assert {:error, :replay_request_conflict} =
             Meetings.replay_summary(
               context.org,
               other_project,
               context.actor,
               "meeting-123",
               "request-project-conflict"
             )

    refute_receive {:replay, _, _, _}
  end
end
