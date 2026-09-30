defmodule SalixAgent.AnalyzeLLM do
  @moduledoc """
  Resolve the per-agent auxiliary "analyze" model options.

  Prefers the agent template's `analyze_config` (via
  `SalixAgent.MediaResolver`, the same model `salix.analyze` uses), falling
  back to the agent's main runtime LLM config. Shared by post-settle side
  channels that need a small model outside a round — session titles and the
  trajectory eval judge. Never errors: an unresolvable agent yields `{:ok, []}`
  so callers surface the failure at the LLM call, not at resolution.
  """

  @spec resolve(String.t()) :: {:ok, map() | keyword()}
  def resolve(agent_id) do
    case SalixAgent.MediaResolver.resolve(agent_id) do
      {:ok, media} ->
        cfg = (media || %{})["analyze_config"] || %{}

        if configured?(cfg) do
          {:ok,
           cfg
           |> Map.put_new("base_url", cfg["endpoint"])
           |> Map.put_new("protocol", cfg["protocol"] || "chat_completions")}
        else
          resolve_main_llm(agent_id)
        end

      {:error, _} ->
        resolve_main_llm(agent_id)
    end
  end

  defp resolve_main_llm(agent_id) do
    case SalixAgent.LlmResolver.resolve_runtime(agent_id) do
      {:ok, llm} -> {:ok, llm}
      {:error, _} -> {:ok, []}
    end
  end

  defp configured?(%{"endpoint" => e, "model" => m}) do
    String.trim(to_string(e)) != "" and String.trim(to_string(m)) != ""
  end

  defp configured?(_), do: false
end
