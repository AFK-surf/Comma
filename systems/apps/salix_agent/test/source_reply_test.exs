defmodule SalixAgent.SourceReplyTest do
  use ExUnit.Case, async: true

  alias SalixAgent.{SendMessageDraftStream, Tools}

  test "the removed reply alias cannot dispatch or own a visible draft, including during repair" do
    call = %{id: "retired-reply", name: "reply", args: %{"text" => "not a message"}}
    scope = %{"conversation_id" => "source"}

    for phase <- [:clean, {:repair_required, 1}] do
      [prepared] =
        Tools.prepare_for_dispatch([call], %{
          llm_tool_envelope: true,
          tool_disclosure: %{"tools" => []},
          visible_reply_scope: scope,
          visible_reply_phase: phase
        })

      assert prepared[:name] == "call"
      assert prepared[:guidance_reason] == "envelope_misuse"
      refute SendMessageDraftStream.exact_source_send?([call], scope, phase)
    end

    assert {_state, :noop} =
             SendMessageDraftStream.consume(
               SendMessageDraftStream.new(),
               %{name: "reply", index: 0, fragment: Jason.encode!(call.args)},
               scope
             )
  end
end
