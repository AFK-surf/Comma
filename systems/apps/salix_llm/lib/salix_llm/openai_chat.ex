defmodule SalixLlm.OpenAIChat do
  @moduledoc "OpenAI Chat transport entry point. Lean owns the protocol."

  def complete(messages, tools, opts \\ nil),
    do: SalixLlm.Http.complete("chat", messages, tools, opts)

  def complete_stream(messages, tools, on_delta, opts \\ nil),
    do: SalixLlm.Http.complete_stream("chat", messages, tools, on_delta, opts)
end
