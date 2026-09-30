defmodule SalixLlm.Streaming do
  @moduledoc "Anthropic streaming network entry point."

  def complete_stream(messages, tools, on_delta, opts \\ []),
    do: SalixLlm.Http.complete_stream("anthropic", messages, tools, on_delta, opts[:llm], opts)
end
