defmodule SalixVerifiedKernel.ProgressTest do
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.Session

  test "public progress preserves terminals and applies selected pure data after one clock read" do
    for status <- ["running", "completed", "failed", "cancelled", nil],
        progress <- [nil, false, %{}, %{"text" => "你好"}, [1, 2], 1.5],
        timestamp <- [nil, false, 0, -1, 123, "opaque"],
        id <- ["a", "missing"] do
      state = %{
        __struct__: SalixAgent.InternalSession.State,
        session_id: "s",
        status: :active,
        activity_status: :thinking,
        async_tool_calls: %{"a" => %{"status" => status, "keep" => "value"}},
        untouched: {1, ["data"]}
      }

      event = %{
        "type" => "async_tool_call_progress",
        "session_id" => "s",
        "tool_call_id" => id,
        "progress" => progress,
        "updated_at" => timestamp
      }

      result = Session.step(state, event)

      if id == "missing" or status in ["completed", "failed", "cancelled"] do
        assert result == {:done, state}
      else
        expected =
          put_in(state, [Access.key!(:async_tool_calls), id], %{
            "status" => status,
            "keep" => "value",
            "progress" => progress || %{},
            "updated_at" => timestamp || 456
          })

        if timestamp in [nil, false] do
          assert {:observe_time, token} = result
          assert Session.step(token, {:observed_time, 456}) == {:done, expected}
        else
          assert result == {:done, expected}
        end
      end
    end
  end
end
