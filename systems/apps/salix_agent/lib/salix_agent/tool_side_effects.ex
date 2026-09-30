defmodule SalixAgent.ToolSideEffects do
  @moduledoc false

  @spec validate_events([map()]) :: :ok | {:error, term()}
  def validate_events([]), do: :ok
  def validate_events(events) when is_list(events), do: validate(:validate_tool_events, events)
  def validate_events(_events), do: {:error, {:invalid_tool_side_effect_event, :not_a_list}}

  @spec validate_results([map()]) :: :ok | {:error, term()}
  def validate_results(results) when is_list(results) do
    Enum.reduce_while(results, :ok, fn result, :ok ->
      result
      |> result_events()
      |> validate_events()
      |> case do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  def validate_results(_results), do: {:error, {:invalid_tool_side_effect_event, :not_a_list}}

  defp result_events(result) when is_map(result), do: result[:events] || result["events"] || []
  defp result_events(_result), do: []

  defp validate(operation, payload) do
    case SalixVerifiedKernel.invoke(:agent_loop, operation, payload) do
      {:ok, result} -> result
      {:error, owner, code} -> {:error, {:invalid_tool_side_effect_event, {owner, code}}}
    end
  end
end
