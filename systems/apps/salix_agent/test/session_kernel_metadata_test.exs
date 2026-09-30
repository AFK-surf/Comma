defmodule SalixAgent.SessionKernelMetadataTest do
  use ExUnit.Case, async: true

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

  test "creation treats only nil and false as fallback and only booleans as hidden values" do
    before = state()

    for value <- [nil, false] do
      fields =
        Map.new(
          [
            "name",
            "platform",
            "billing_context",
            "task_origin",
            "source_session_id",
            "source_schedule_id"
          ],
          &{&1, value}
        )

      assert Driver.step(before, event("session_created", fields)) === {:done, before}

      empty = %State{before | name: value, billing_context: value}

      assert Driver.step(empty, event("session_created", fields)) ===
               {:done, %State{empty | name: "Default", billing_context: %{}}}
    end

    for hidden <- [true, false] do
      assert Driver.step(before, event("session_created", %{"hidden" => hidden})) ===
               {:done, %State{before | hidden: hidden}}
    end
  end

  test "creation fills falsey timestamps but preserves zero and empty native values" do
    before = state()

    for old <- [nil, false], supplied <- [nil, false, 0, "", []] do
      empty = %State{
        before
        | created_at: old,
          last_activity_at: old,
          activity_status_updated_at: old
      }

      expected = %State{
        empty
        | created_at: supplied,
          last_activity_at: supplied,
          activity_status_updated_at: supplied
      }

      assert Driver.step(empty, event("session_created", %{"created_at" => supplied})) ===
               {:done, expected}
    end

    for old <- [0, "", []] do
      sticky = %State{
        before
        | created_at: old,
          last_activity_at: old,
          activity_status_updated_at: old
      }

      assert Driver.step(sticky, event("session_created", %{"created_at" => 99})) ===
               {:done, sticky}
    end
  end

  test "system prompt uses primary then fallback without retaining the old prompt" do
    before = state()

    for primary <- [0, "", [], %{}, "primary"] do
      ev = event("session_system_prompt", %{"system_prompt" => primary, "prompt" => "fallback"})

      assert Driver.step(before, ev) === {:done, %State{before | system_prompt: primary}}
    end

    for primary <- [nil, false], fallback <- [0, "", [], %{}, "fallback"] do
      ev = event("session_system_prompt", %{"system_prompt" => primary, "prompt" => fallback})

      assert Driver.step(before, ev) === {:done, %State{before | system_prompt: fallback}}
    end

    for fields <- [%{}, %{"system_prompt" => false, "prompt" => nil}] do
      assert Driver.step(before, event("session_system_prompt", fields)) ===
               {:done, %State{before | system_prompt: ""}}
    end
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
