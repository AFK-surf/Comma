defmodule SalixLlm.SSE do
  @moduledoc false
  def parse_data_line(line), do: SalixVerifiedKernel.Provider.call(:data_line, line)
end
