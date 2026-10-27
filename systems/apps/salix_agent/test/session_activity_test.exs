defmodule SalixAgent.SessionActivityTest do
  use SystemsClock.Case, async: true

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

  test "a funding stop carries what the member can fix, and nothing else" do
    internal =
      internal("idle", "failed")
      |> Map.put("issue", "provider_quota_exhausted")
      |> Map.put("funding", %{
        "source" => "anthropic",
        "profile_id" => "prof_1",
        "profile_name" => "Team Claude key",
        "api_key" => "sk-ant-secret"
      })

    assert %{
             "issue" => "provider_quota_exhausted",
             "issue_detail" =>
               %{
                 "source" => "anthropic",
                 "profile_id" => "prof_1",
                 "profile_name" => "Team Claude key"
               } = detail
           } = SessionActivity.project(internal)

    refute Map.has_key?(detail, "api_key")

    assert %{"issue_detail" => %{"source" => "claude", "reset_at" => 1_790_000_000}} =
             internal("idle", "failed")
             |> Map.merge(%{
               "issue" => "quota_exhausted",
               "message" => "Claude account usage quota is exhausted.",
               "runtime_provider" => "claude",
               "reset_at" => 1_790_000_000
             })
             |> SessionActivity.project()

    # A Comma-run Agent's own plan at its limit names that plan and its refill.
    assert %{
             "issue_detail" => %{
               "source" => "codex",
               "profile_id" => "prof_2",
               "profile_name" => "ChatGPT Plus",
               "reset_at" => 1_790_000_000
             }
           } =
             internal("idle", "failed")
             |> Map.merge(%{
               "issue" => "quota_exhausted",
               "funding" => %{
                 "source" => "codex",
                 "profile_id" => "prof_2",
                 "profile_name" => "ChatGPT Plus",
                 "reset_at" => 1_790_000_000
               }
             })
             |> SessionActivity.project()

    refute Map.has_key?(
             internal("idle", "failed")
             |> Map.put("issue", "insufficient_credits")
             |> Map.put("funding", %{"source" => "anthropic"})
             |> SessionActivity.project(),
             "issue_detail"
           )
  end

  test "a wait names the tool whose call runs and says when it began" do
    tool_wait =
      SalixAgent.Waits.build("async tool call still running: cloud_vm.start", 20, "auto_wait", %{
        "tool_call_id" => "call_1",
        "tool_name" => "cloud_vm.start"
      })

    assert %{"state" => "active", "wait" => wait} =
             SessionActivity.project(Map.put(internal("active", "waiting"), "wait", tool_wait))

    assert wait["tool_name"] == "cloud_vm.start"
    assert wait["started_at_ms"] == tool_wait["deadline_ms"] - 20_000

    task_wait = SalixAgent.Waits.build("waiting for the report", 300, "wait_for")

    assert %{"wait" => wait} =
             SessionActivity.project(Map.put(internal("active", "waiting"), "wait", task_wait))

    refute Map.has_key?(wait, "tool_name")
    assert wait["started_at_ms"] == task_wait["deadline_ms"] - 300_000
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
end
