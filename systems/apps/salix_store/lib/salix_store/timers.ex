defmodule SalixStore.Timers do
  @moduledoc false

  # Historical identity migrations preserve old timer keys. Online deadlines
  # use the owning Session or CapabilityRequest row.
  def minute_bucket(ms), do: div(div(ms, 1000), 60)
end
