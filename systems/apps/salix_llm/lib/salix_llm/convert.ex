defmodule SalixLlm.Convert do
  @moduledoc "Anthropic message projections owned by the Lean provider kernel."
  alias SalixVerifiedKernel.Provider, as: Kernel

  def to_anthropic(messages, model \\ nil) do
    {system, messages, _trailing} = to_anthropic_parts(messages, model)
    {system, messages}
  end

  def to_anthropic_parts(messages, model), do: Kernel.call(:anthropic_parts, {messages, model})
  def tools(specs), do: Kernel.call(:tools, {"anthropic", specs})
  def parse_response(response, model \\ nil), do: Kernel.call(:parse_anthropic, {response, model})
end
