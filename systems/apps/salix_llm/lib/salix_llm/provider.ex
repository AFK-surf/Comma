defmodule SalixLlm.Provider do
  @moduledoc """
  Protocol dispatcher — the production `SalixAgent.LLM` implementation
  (mirrors willow's `marshalRequest` switch in `internal/llm/client.go`).

  Resolves the per-agent provider config (`SalixLlm.ProviderConfig`, sourced
  entirely from the per-call `llm_opts` — no cluster-wide fallback) and routes
  by `protocol`:

    * `"anthropic"` → `SalixLlm.Anthropic` (+ SSE streaming)
    * `"responses"` → `SalixLlm.OpenAIResponses` (+ SSE streaming)
    * anything else (incl. `""`/`"chat_completions"`) → `SalixLlm.OpenAIChat`
      (+ SSE streaming) — willow's default protocol

  Wire as `config :salix_agent, llm: SalixLlm.Provider`.
  """
  @behaviour SalixAgent.LLM

  alias SalixLlm.{ProviderConfig, Anthropic, OpenAIChat, OpenAIResponses}

  @impl true
  def complete(messages, tools), do: complete(messages, tools, [])

  @impl true
  def complete(messages, tools, llm_opts) do
    case protocol(llm_opts) do
      "anthropic" -> Anthropic.complete(messages, tools, llm_opts)
      "responses" -> OpenAIResponses.complete(messages, tools, llm_opts)
      _ -> OpenAIChat.complete(messages, tools, llm_opts)
    end
  end

  @impl true
  def complete_stream(messages, tools, on_delta),
    do: complete_stream(messages, tools, on_delta, [])

  @impl true
  def complete_stream(messages, tools, on_delta, llm_opts) when is_function(on_delta, 1) do
    case protocol(llm_opts) do
      "anthropic" -> Anthropic.complete_stream(messages, tools, on_delta, llm_opts)
      "responses" -> OpenAIResponses.complete_stream(messages, tools, on_delta, llm_opts)
      _ -> OpenAIChat.complete_stream(messages, tools, on_delta, llm_opts)
    end
  end

  @impl true
  def compact_context(messages, tools, llm_opts) do
    case protocol(llm_opts) do
      "responses" ->
        if native_compaction?(llm_opts),
          do: OpenAIResponses.compact_context(messages, tools, llm_opts),
          else: {:unsupported, :route}

      other ->
        {:unsupported, {:protocol, other}}
    end
  end

  # A route can speak Responses without a compact endpoint (a Grok
  # subscription); the caller then uses summary compaction.
  defp native_compaction?(opts) when is_map(opts),
    do: Map.get(opts, "native_compaction", Map.get(opts, :native_compaction)) != false

  defp native_compaction?(opts) when is_list(opts),
    do: not (Keyword.keyword?(opts) and Keyword.get(opts, :native_compaction) == false)

  defp native_compaction?(_), do: true

  defp protocol(llm_opts), do: ProviderConfig.resolve(llm_opts).protocol

  @impl true
  def request_config(llm_opts) do
    cfg = ProviderConfig.resolve(llm_opts)

    protocol =
      if cfg.protocol in ["anthropic", "responses"], do: cfg.protocol, else: "chat"

    {protocol, Map.delete(cfg, :transport)}
  end
end
