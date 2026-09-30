defmodule SalixAgent.SessionActivityTest do
  use ExUnit.Case, async: true

  alias SalixAgent.SessionActivity

  test "projects internal lifecycle into exactly active, stopped, and error" do
    assert %{
             "state" => "active",
             "status" => "is thinking...",
             "version" => "activity-revision-test"
           } =
             SessionActivity.project(internal("active", "thinking"))

    assert %{"state" => "stopped", "status" => ""} =
             SessionActivity.project(internal("idle", "paused"))

    assert %{"state" => "error", "status" => "error: runtime failed"} =
             SessionActivity.project(internal("idle", "failed"))
  end

  test "waiting remains active and includes current wait facts" do
    deadline_ms = System.system_time(:millisecond) + 30_000

    activity =
      SessionActivity.project(
        internal("idle", "waiting")
        |> Map.put("wait", %{
          "reason" => "user approval",
          "deadline_ms" => deadline_ms
        })
      )

    assert activity["state"] == "active"
    assert activity["status"] == "is waiting: user approval"
    assert activity["wait"]["reason"] == "user approval"
    assert activity["wait"]["remaining_seconds"] in 29..30
  end

  test "invalid internal lifecycle combinations are explicit errors" do
    activity = SessionActivity.project(internal("active", "paused"))

    assert activity["state"] == "error"
    assert activity["status"] == "error: session activity is unknown"
    refute activity["state"] in ["idle", "completed", "complete", "queued"]
  end

  test "waiting without details retains a structured wait marker for both runtimes" do
    for session <- [internal("idle", "waiting"), external("waiting")] do
      assert %{"state" => "active", "wait" => %{} = wait} = SessionActivity.project(session)
      assert wait == %{}
    end
  end

  test "projects external lifecycle without exposing provider states" do
    assert %{"state" => "active", "status" => "is starting..."} =
             SessionActivity.project(external("starting"))

    assert %{"state" => "active", "status" => "is working..."} =
             SessionActivity.project(external("running"))

    assert %{"state" => "stopped", "status" => ""} =
             SessionActivity.project(external("idle"))

    assert %{"state" => "error", "status" => "error: runtime observation was lost"} =
             external("unknown")
             |> Map.put("issue", "runtime_observation_lost")
             |> SessionActivity.project()
  end

  test "uses normalized external terminal detail as display text" do
    assert %{
             "state" => "error",
             "issue" => "quota_exhausted",
             "status" => "error: Codex account usage quota is exhausted."
           } =
             external("failed")
             |> Map.put("issue", "quota_exhausted")
             |> Map.put("message", "Codex account usage quota is exhausted.")
             |> SessionActivity.project()
  end

  test "omits a missing activity revision instead of treating display time as a fence" do
    activity =
      internal("idle", "paused")
      |> Map.delete("activity_revision")
      |> SessionActivity.project()

    assert activity["state"] == "stopped"
    assert activity["updated_at"] == 123
    refute Map.has_key?(activity, "version")
  end

  defp internal(status, activity_status) do
    %{
      "runtime_kind" => "internal",
      "session_id" => "ses1_test",
      "status" => status,
      "activity_status" => activity_status,
      "activity_status_updated_at" => 123,
      "activity_revision" => "activity-revision-test"
    }
  end

  defp external(status) do
    %{
      "runtime_kind" => "external",
      "session_id" => "ses1_test",
      "status" => status,
      "status_updated_at" => 123,
      "activity_revision" => "activity-revision-test"
    }
  end
end
