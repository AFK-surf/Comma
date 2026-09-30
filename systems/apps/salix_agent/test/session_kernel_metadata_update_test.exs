defmodule SalixAgent.SessionKernelMetadataUpdateTest do
  use ExUnit.Case, async: true

  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.InternalSession.State

  defp state do
    %State{
      agent_id: "agent-update",
      session_id: "session-update",
      name: "User name",
      hidden: true,
      status: :active,
      activity_status: :execution,
      activity_status_updated_at: 10,
      created_at: 11,
      last_activity_at: 12,
      messages: [%{id: 1, role: "user", content: "retained", payload: [1.25 | false]}],
      storage_revision: "update-revision"
    }
  end

  defp event(fields),
    do: Map.merge(%{"type" => "session_update", "session_id" => "session-update"}, fields)

  test "conditional auto-title preserves a user rename and other fields" do
    before = state()

    ev =
      event(%{
        "name" => "Generated",
        "if_unnamed" => true,
        "hidden" => false,
        "updated_at" => 20,
        "status" => "idle",
        "created_at" => 99
      })

    expected = %State{before | hidden: false, last_activity_at: 20}
    assert Driver.step(before, ev) === {:done, expected}
    assert SessionData.apply_event(before, ev) === expected
  end

  test "all native placeholder fast paths permit conditional renaming" do
    for name <- [
          nil,
          false,
          [],
          "",
          "Chat",
          "Default",
          "Untitled",
          :"",
          :Chat,
          :Default,
          :Untitled
        ] do
      before = %State{state() | name: name}
      ev = event(%{"name" => "Generated", "if_unnamed" => true})

      assert Driver.step(before, ev) === {:done, %State{before | name: "Generated"}}
    end
  end

  test "native conversion remains available outside the executable model profile" do
    for {name, expected_name} <- [
          {[67, 104, 97, 116], "Generated"},
          {[85, 110, 116, 105, 116, 108, 101, 100], "Generated"},
          {123, 123},
          {1.25, 1.25},
          {[78, 97, 109, 101], [78, 97, 109, 101]}
        ] do
      before = %State{state() | name: name}
      ev = event(%{"name" => "Generated", "if_unnamed" => true})

      assert Driver.step(before, ev) === {:done, %State{before | name: expected_name}}
    end
  end

  test "nil supplied name and nontrue condition never visit malformed current-name conversion" do
    before = %State{state() | name: %{"unsupported" => true}}

    for fields <- [%{}, %{"name" => nil, "if_unnamed" => true}] do
      assert Driver.step(before, event(fields)) === {:done, before}
    end

    for conditional <- [nil, false, 0, "true", []], supplied <- [false, 0, "", [], %{}] do
      ev = event(%{"name" => supplied, "if_unnamed" => conditional})

      assert Driver.step(before, ev) === {:done, %State{before | name: supplied}}
    end

    ev = event(%{"name" => "Generated", "if_unnamed" => true})
    assert_raise ArgumentError, ~r/^invalid Session data:/, fn -> Driver.step(before, ev) end

    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      SessionData.apply_event(before, ev)
    end
  end

  test "false supplied name is a rename, while hidden accepts only booleans" do
    before = state()

    for hidden <- [nil, 0, "", [], %{}, 1.25] do
      ev = event(%{"name" => false, "hidden" => hidden})

      assert Driver.step(before, ev) === {:done, %State{before | name: false}}
    end

    for hidden <- [true, false], timestamp <- [nil, false, 0, "", [], 1.25] do
      ev = event(%{"hidden" => hidden, "updated_at" => timestamp})

      expected = %State{
        before
        | hidden: hidden,
          last_activity_at: timestamp || before.last_activity_at
      }

      assert Driver.step(before, ev) === {:done, expected}
    end
  end

  test "the outer State wrapper filters cross-session updates" do
    before = state()
    ev = event(%{"name" => "Other", "session_id" => "other-session"})
    assert SessionData.apply_event(before, ev) === before
  end
end
