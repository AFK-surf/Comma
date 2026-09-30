defmodule SalixLlm.Usage do
  @moduledoc false
  alias SalixVerifiedKernel.Provider, as: Kernel

  def anthropic(usage), do: Kernel.call(:usage, {:anthropic, usage})
  def openai_chat(response), do: Kernel.call(:usage, {:openai_chat, response})
  def openai(usage), do: Kernel.call(:usage, {:openai, usage})
  def responses(usage), do: Kernel.call(:usage, {:responses, usage})
  def attach(result, usage, model), do: Kernel.call(:attach_usage, {result, usage, model})
end
