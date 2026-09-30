defmodule SalixLlm.Anthropic do
  @moduledoc "Anthropic transport entry point. Lean owns the Messages protocol."
  @behaviour SalixAgent.LLM

  @impl true
  def complete(messages, tools), do: complete(messages, tools, [])
  @impl true
  def complete(messages, tools, opts),
    do: SalixLlm.Http.complete("anthropic", messages, tools, opts)

  @impl true
  def complete_stream(messages, tools, on_delta),
    do: complete_stream(messages, tools, on_delta, [])

  @impl true
  def complete_stream(messages, tools, on_delta, opts),
    do: SalixLlm.Http.complete_stream("anthropic", messages, tools, on_delta, opts)

  def url(cfg), do: elem(SalixVerifiedKernel.Provider.endpoint("anthropic", cfg, "complete"), 0)

  def headers(cfg, extra \\ []),
    do:
      SalixVerifiedKernel.Provider.call(:anthropic_headers, {Map.delete(cfg, :transport), extra})
end
