defmodule SalixAgent.SessionKernelNumberTest do
  use SystemsClock.Case, async: true
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
end
