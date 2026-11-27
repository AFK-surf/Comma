defmodule SalixAgent.IFC.LocalDiagnostic do
  @moduledoc "A fixed diagnostic item separate from the private, original local validation result."

  # Only the local validator calls this constructor. Provider errors and their
  # public_summary fields never enter it. The original result still carries
  # arguments and diagnostic detail. The ordinary result stamp retains its
  # audience; before that stamp the root defaults to agent-private.
  @reasons [:invalid_params, :not_callable, :envelope_misuse]

  def project(result, reason) when reason in @reasons do
    item = item(reason)

    body =
      result.content
      |> Jason.decode!()
      |> Map.put("items", [item])
      |> Map.put(
        "diagnostic_ref",
        "Use item #0 only for the fixed runtime diagnostic; the full result retains its original audience."
      )
      |> Jason.encode!()

    result
    |> Map.put(:content, body)
    |> Map.put(:output, body)
    |> Map.put(:ifc_local_diagnostic, true)
    |> Map.put(:ifc, %{
      "label" => ["agent_private"],
      "items" => [%{"index" => 0, "label" => ["public"]}]
    })
  end

  def project(result, _reason), do: result

  # Match the complete fixed item, never an arbitrary diagnostic message.
  def fixed_item?(body), do: Enum.any?(@reasons, &(body == item(&1)))

  defp item(reason), do: %{"kind" => "runtime_diagnostic", "message" => message(reason)}

  defp message(:envelope_misuse),
    do: "This is not a callable tool. Use wait_for to wait for work, or end_turn to finish."

  defp message(:invalid_params), do: "The tool arguments do not match the local calling contract."
  defp message(:not_callable), do: "This operation is not available in the current runtime."
end
