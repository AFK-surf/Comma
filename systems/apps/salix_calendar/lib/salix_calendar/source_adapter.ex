defmodule SalixCalendar.SourceAdapter do
  @moduledoc "Normalization contract for read-only Calendar sources."

  @callback adapter_contract_id() :: String.t()
  @callback normalize(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback capabilities() :: map()
  @callback start_sync(map(), map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  @callback continue_sync(map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback exact_refresh(map(), map(), map()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks capabilities: 0, start_sync: 3, continue_sync: 3, exact_refresh: 3
end
