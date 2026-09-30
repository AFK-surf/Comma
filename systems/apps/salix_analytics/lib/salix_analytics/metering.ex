defmodule SalixAnalytics.Metering do
  @moduledoc """
  Usage metering helpers. Aggregates billable signals from flattened events —
  user/assistant/tool messages and tool errors — into per-agent counters.
  """

  @type counts :: %{
          deliveries: non_neg_integer(),
          assistant: non_neg_integer(),
          tool_results: non_neg_integer(),
          tool_errors: non_neg_integer()
        }

  @empty %{deliveries: 0, assistant: 0, tool_results: 0, tool_errors: 0}

  @doc "Zero counts."
  def empty, do: @empty

  @doc "Fold events into running counts."
  @spec aggregate([map()], counts()) :: counts()
  def aggregate(events, acc \\ @empty) do
    Enum.reduce(events, acc, fn ev, c ->
      case ev["type"] || ev["kind"] do
        "delivery" -> Map.update!(c, :deliveries, &(&1 + 1))
        "assistant" -> Map.update!(c, :assistant, &(&1 + 1))
        "tool_result" -> bump_tool(c, ev)
        _ -> c
      end
    end)
  end

  defp bump_tool(c, ev) do
    c = Map.update!(c, :tool_results, &(&1 + 1))
    if ev["error"] == true, do: Map.update!(c, :tool_errors, &(&1 + 1)), else: c
  end
end
