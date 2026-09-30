defmodule SalixLlm.OpenAIResponses do
  @moduledoc "OpenAI Responses transport entry point. Lean owns the protocol."

  def complete(messages, tools, opts \\ nil),
    do: SalixLlm.Http.complete("responses", messages, tools, opts)

  def complete_stream(messages, tools, on_delta, opts \\ nil),
    do: SalixLlm.Http.complete_stream("responses", messages, tools, on_delta, opts)

  def compact_context(messages, tools, opts \\ nil),
    do: SalixLlm.Http.complete("responses", messages, tools, opts, "compact")
end
