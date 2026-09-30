defmodule SalixAgent.SessionKernelNumberTest do
  use ExUnit.Case, async: true
  alias SalixAgent.InternalSession.State
  alias SalixVerifiedKernel.Session

  test "Lean string conversion matches finite IEEE values across the exponent range" do
    values =
      for n <- 1..256 do
        bits = rem(n * 6_364_136_223_846_793_005, 18_446_744_073_709_551_616)
        <<value::float-64>> = <<bits::unsigned-64>>
        value
      end

    values = [0.0, -0.0, 1.0e-4, 1.0e-5, 1.0e15, 1.0e16, 1.0e20, 1.25 | values]
    state = %State{status: :active, activity_status: :thinking}

    for value <- values do
      event = %{"type" => "visible_reply_intent", "scope" => %{value => "value"}}
      assert {:done, next} = Session.step(state, event)
      assert next.visible_reply_intent["scope"] == %{Float.to_string(value) => "value"}
    end
  end

  test "business output compares nested numeric values but keeps map keys exact" do
    state = %State{status: :active, activity_status: :thinking, live_context_bytes: 0}

    for {content, output, same} <- [
          {[1, %{value: 2}], [1.0, %{value: 2.0}], true},
          {%{1 => 2}, %{1.0 => 2}, false}
        ] do
      event = %{
        "type" => "tool_result",
        "tool_name" => "test",
        "input" => %{},
        "status" => "completed",
        "content" => content,
        "output" => output
      }

      assert {:done, next} = Session.step(state, event)
      business = if same, do: content, else: {content, output}

      expected =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(
            {"test", %{}, "completed", nil, nil, business},
            [:deterministic]
          )
        )
        |> Base.encode16(case: :lower)

      assert next.repeated_tool_result_streak["fingerprint"] == expected
    end
  end
end
