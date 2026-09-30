defmodule CommaTUI do
  @moduledoc "Transport-independent terminal application contract. Effects belong to the host runtime."
  @callback init(map()) :: {term(), [term()]}
  @callback update(term(), term()) :: {term(), [term()]}
  @callback view(term()) :: map()
end
