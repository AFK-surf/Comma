defmodule SalixLlm.Stream do
  @moduledoc "Anthropic stream decoding through the Lean provider kernel."

  def decode(body, model \\ nil),
    do: SalixVerifiedKernel.Provider.call(:decode_stream, {"anthropic", body, model})

  def parse_events(body), do: SalixVerifiedKernel.Provider.call(:events, body)
end
