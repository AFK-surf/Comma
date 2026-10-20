defmodule SalixMeetNative.ASR.Provider do
  @moduledoc false

  @type result :: %{
          text: String.t(),
          start_ms: non_neg_integer(),
          end_ms: non_neg_integer(),
          final: boolean()
        }

  @callback name() :: String.t()

  @callback recognize(
              audio :: Enumerable.t(binary()),
              emit :: (result() -> any()),
              config :: map()
            ) ::
              :ok | {:error, term()}

  @callback retryable?(reason :: term()) :: boolean()
end
