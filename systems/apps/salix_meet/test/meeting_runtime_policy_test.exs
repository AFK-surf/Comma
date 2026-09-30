defmodule SalixMeet.MeetingRuntimePolicyTest do
  use ExUnit.Case, async: true

  alias SalixMeet.MeetingRuntimePolicy

  test "requires one explicit runtime source" do
    assert {:error, :meeting_runtime_source_required} = MeetingRuntimePolicy.select(%{})

    assert {:ok, "connected_runtime"} =
             MeetingRuntimePolicy.select(%{"runtime_source" => "connected_runtime"})

    assert {:ok, "compute_workload"} =
             MeetingRuntimePolicy.select(%{
               "runtime_policy" => %{"source" => "compute_workload"}
             })
  end

  test "rejects dual selectors and source conflicts" do
    assert {:error, :dual_meeting_runtime_selector} =
             MeetingRuntimePolicy.select(%{
               "runtime_source" => "connected_runtime",
               "connected_runtime" => true,
               "compute_workload" => true
             })

    assert {:error, :meeting_runtime_policy_conflict} =
             MeetingRuntimePolicy.select(%{
               "runtime_source" => "compute_workload",
               "connected_runtime" => true
             })
  end

  test "terminal statuses are owned by the meeting actor" do
    assert MeetingRuntimePolicy.terminal?("done")
    assert MeetingRuntimePolicy.terminal?("failed")
    refute MeetingRuntimePolicy.terminal?("active")
  end
end
