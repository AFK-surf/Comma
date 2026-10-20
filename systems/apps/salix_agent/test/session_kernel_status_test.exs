defmodule SalixAgent.SessionKernelStatusTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.InternalSession.State

  defp state do
    %State{
      agent_id: "agent-status",
      session_id: "session-status",
      status: :active,
      activity_status: :execution,
      activity_status_updated_at: 10,
      messages: [%{"payload" => [1.25, false]}],
      async_tool_calls: %{"retained" => %{"status" => "running"}},
      storage_revision: "revision-status"
    }
  end

  defp event(type, fields) do
    Map.merge(%{"type" => type, "session_id" => "session-status"}, fields)
  end

  test "active status resets activity and the kernel owns the transition timestamp" do
    before = state()

    for status <- [:active, "active"] do
      ev = event("status", %{"status" => status, "created_at" => 40})
      reduced = %State{before | status: :active, activity_status: :thinking}

      assert SessionData.apply_event(before, ev) ===
               %State{reduced | activity_status_updated_at: 40}
    end
  end

  test "idle status composes with paused activity and its transition timestamp" do
    before = state()

    for status <- [:idle, "idle", nil] do
      ev = event("status", %{"status" => status, "updated_at" => 41})
      reduced = %State{before | status: :idle}

      assert SessionData.apply_event(before, ev) ===
               %State{reduced | activity_status: :paused, activity_status_updated_at: 41}
    end
  end

  test "active activity accepts native atom and binary spellings without changing other fields" do
    before = state()

    for activity <- [:thinking, :execution, :messaging],
        supplied <- [activity, Atom.to_string(activity)] do
      ev = event("activity_status", %{"activity_status" => supplied, "created_at" => 42})
      reduced = %State{before | activity_status: activity}
      timestamp = if activity == :execution, do: 10, else: 42

      assert SessionData.apply_event(before, ev) ===
               %State{reduced | activity_status_updated_at: timestamp}
    end
  end

  test "inactive activity ignores malformed values without parsing them" do
    before = %State{state() | status: :idle, activity_status: :paused}

    for value <- [nil, false, [], "unknown", 1.25, %{"arbitrary" => true}] do
      ev = event("activity_status", %{"activity_status" => value, "created_at" => 43})
      assert SessionData.apply_event(before, ev) === before
    end
  end
end
