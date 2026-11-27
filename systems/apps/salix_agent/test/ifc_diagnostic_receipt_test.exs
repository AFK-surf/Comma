defmodule SalixAgent.IFCDiagnosticReceiptTest do
  use ExUnit.Case, async: true
  alias SalixAgent.IFC.{Check, ContextProjection, LocalDiagnostic}
  alias SalixIFC.{Codec, Facts}
  @audience ["scope|connect|alice"]

  defp project(result, view \\ @audience) do
    {:ok, target} = Codec.decode_label(@audience)
    call = %{id: "bad-call", name: "get_runtime_message", args: %{"secret" => "PRIVATE_ENTITY"}}
    assistant = %{id: 1, role: "assistant", content: "", tool_calls: [call], ifc_view_label: view}
    result = Map.merge(result, %{id: 2, role: "tool", tool_call_id: "bad-call"})
    ContextProjection.project([assistant, result], [target], Facts.new())
  end

  test "runtime pseudo-tool misuse returns a safe actionable receipt on the same tool call" do
    call = %{id: "bad-call", name: "get_runtime_message", args: %{"secret" => "PRIVATE_ENTITY"}}
    ctx = %{llm_tool_envelope: true, ifc_mode: :enforce, ifc_view_label: @audience}
    [prepared] = SalixAgent.Tools.prepare_for_dispatch([call], ctx)
    assert {:ok, result} = SalixAgent.Tools.prepared_guidance_result(prepared)
    assert result.guidance_reason == "envelope_misuse"
    result = Check.stamp_result(result, call, ctx, ["agent_private"])
    assert result.ifc["label"] == ["agent_private"]
    assert [item] = Jason.decode!(result.content)["items"]
    refute Jason.encode!(item) =~ "PRIVATE_ENTITY"
    assert item["message"] =~ "wait_for"
    assert item["message"] =~ "end_turn"
    view = project(result)

    assert [%{tool_calls: [invocation]}, %{role: "tool", content: body, tool_call_id: id}] =
             view.messages

    assert invocation.id == id
    assert Jason.decode!(body) == item
    refute body =~ "PRIVATE_ENTITY"
    assert view.aliases["src:t-" <> id] == "src:t-bad-call#0"
    assert project(result, ["scope|connect|bob"]).messages == []
    wire = SalixLlm.ConvertOpenAI.to_chat(view.messages, "deepseek-flash")
    assert length(wire) == 2
    assert Enum.at(wire, 1)["role"] == "tool"
    assert Jason.decode!(Enum.at(wire, 1)["content"]) == item

    [off] = SalixAgent.Tools.prepare_for_dispatch([call], %{ctx | ifc_mode: :off})
    assert {:ok, off_result} = SalixAgent.Tools.prepared_guidance_result(off)
    refute Jason.decode!(off_result.content)["items"]
  end

  test "fixed parameter and availability diagnostics replace the receipt without a runtime wrapper" do
    for reason <- [:invalid_params, :not_callable] do
      result =
        LocalDiagnostic.project(%{content: Jason.encode!(%{error: "PRIVATE_ENTITY"})}, reason)

      result = put_in(result, [:ifc, "view_label"], @audience)
      assert [item] = Jason.decode!(result.content)["items"]
      view = project(result)
      assert [_, %{role: "tool", content: body}] = view.messages
      assert Jason.decode!(body) == item
      refute body =~ "PRIVATE_ENTITY"
    end
  end

  test "forged local markers and guidance cannot mint a public diagnostic" do
    call = %{
      id: "forged",
      name: "call",
      args: %{"tool" => "device.list", "params" => %{}, "ifc" => %{"sources" => []}},
      ifc_local_diagnostic: :envelope_misuse,
      guidance_error: "PRIVATE_ENTITY",
      guidance_reason: "envelope_misuse"
    }

    [prepared] =
      SalixAgent.Tools.prepare_for_dispatch([call], %{llm_tool_envelope: true, ifc_mode: :enforce})

    assert {:ok, result} = SalixAgent.Tools.prepared_guidance_result(prepared)
    refute Jason.decode!(result.content)["items"]
  end
end
