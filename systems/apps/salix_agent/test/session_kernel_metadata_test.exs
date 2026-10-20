defmodule SalixAgent.SessionKernelMetadataTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.InternalSession.State

  defp state do
    %State{
      agent_id: "agent-metadata",
      session_id: "session-metadata",
      name: "Existing",
      hidden: true,
      status: :active,
      activity_status: :execution,
      created_at: 11,
      last_activity_at: 12,
      activity_status_updated_at: 13,
      platform: "existing-platform",
      billing_context: %{"existing" => 1.25},
      task_origin: %{"existing" => true},
      source_session_id: "existing-source",
      source_schedule_id: "existing-schedule",
      system_prompt: "existing prompt",
      messages: [%{id: 1, role: "user", content: "retained", payload: [1.25 | false]}],
      storage_revision: "metadata-revision"
    }
  end

  defp event(type, fields) do
    Map.merge(%{"type" => type, "session_id" => "session-metadata"}, fields)
  end

  test "creation keeps sticky timestamps and unrelated fields while selecting native payloads" do
    before = state()

    for value <- [0, "", [], %{}, 1.25] do
      ev =
        event("session_created", %{
          "name" => value,
          "platform" => value,
          "billing_context" => value,
          "task_origin" => value,
          "source_session_id" => value,
          "source_schedule_id" => value,
          "created_at" => 99,
          "status" => "idle",
          "hidden" => value
        })

      expected = %State{
        before
        | name: value,
          platform: value,
          billing_context: value,
          task_origin: value,
          source_session_id: value,
          source_schedule_id: value
      }

      assert Driver.step(before, ev) === {:done, expected}
    end
  end

  test "a Session's model is set at creation, replaced or cleared by an update, and otherwise kept" do
    before = state()
    choice = %{"kind" => "catalog", "model" => "gpt-5.5", "reasoning_effort" => "high"}
    other = %{"kind" => "catalog", "model" => "claude-sonnet-5-5"}

    assert Driver.step(before, event("session_created", %{"model" => choice})) ===
             {:done, %State{before | model: choice}}

    chosen = %State{before | model: choice}

    # Creation never clears an existing choice; a non-map is no choice.
    for value <- [nil, "gpt-5.5", []] do
      assert Driver.step(chosen, event("session_created", %{"model" => value})) ===
               {:done, chosen}
    end

    assert Driver.step(chosen, event("session_update", %{"model" => other})) ===
             {:done, %State{chosen | model: other}}

    assert Driver.step(chosen, event("session_update", %{"model" => nil})) ===
             {:done, %State{chosen | model: nil}}

    assert Driver.step(chosen, event("session_update", %{"name" => "Renamed"})) ===
             {:done, %State{chosen | name: "Renamed"}}
  end

  test "real State wrapper preserves active activity and delegates both metadata events" do
    before = state()

    created =
      event("session_created", %{"name" => "Renamed", "hidden" => false, "created_at" => 99})

    expected = %State{before | name: "Renamed", hidden: false}
    assert SessionData.apply_event(before, created) === expected

    prompt =
      event("session_system_prompt", %{"system_prompt" => "new prompt", "created_at" => 100})

    assert SessionData.apply_event(expected, prompt) ===
             %State{expected | system_prompt: "new prompt"}

    # Session filtering and activity derivation remain wrapper responsibilities.
    assert SessionData.apply_event(
             before,
             Map.put(created, "session_id", "different-session")
           ) ===
             before
  end
end
