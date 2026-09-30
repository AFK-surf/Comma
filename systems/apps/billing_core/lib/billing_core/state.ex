defmodule BillingCore.State do
  @moduledoc "In-memory storage shape used by the pure billing core."

  defstruct pricing_catalog: [],
            meter_aliases: %{},
            balances: %{},
            grants: [],
            grant_events: [],
            credit_ledger: [],
            charged_events: %{},
            rounding_remainders: %{},
            pending_meter_charges: %{},
            fee_control_cache: %{}

  @type t :: %__MODULE__{
          pricing_catalog: [map()],
          meter_aliases: map(),
          balances: map(),
          grants: [map()],
          grant_events: [map()],
          credit_ledger: [map()],
          charged_events: map(),
          rounding_remainders: map(),
          pending_meter_charges: map(),
          fee_control_cache: map()
        }

  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    struct!(__MODULE__, attrs)
  end
end
