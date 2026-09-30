defmodule SalixLlm.CacheBreakpoints do
  @moduledoc "Lean places the frozen-prefix and durable-tail cache breakpoints."

  def place(system, tools, messages, enabled? \\ true, trailing_context \\ 0),
    do:
      SalixVerifiedKernel.Provider.call(
        :cache,
        {system, tools, messages, enabled?, trailing_context}
      )
end
