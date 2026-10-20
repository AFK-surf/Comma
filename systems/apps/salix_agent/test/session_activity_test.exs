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

    refute Map.has_key?(
             internal("idle", "failed")
             |> Map.put("issue", "insufficient_credits")
             |> Map.put("funding", %{"source" => "anthropic"})
             |> SessionActivity.project(),
             "issue_detail"
           )
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
