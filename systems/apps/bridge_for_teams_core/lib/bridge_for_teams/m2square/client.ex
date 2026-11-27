defmodule BridgeForTeams.M2square.Client do
  @moduledoc """
  Behaviour for M2square payment gateway operations.
  """

  @type pay_result :: %{
          order_id: String.t(),
          checkout_url: String.t(),
          currency: String.t() | nil,
          raw_item: map()
        }

  @type pay_error ::
          {:uncertain, term()}
          | {:rejected, String.t(), String.t() | nil}
          | term()

  @callback pay(payload :: map(), config :: map()) ::
              {:ok, pay_result()} | {:error, pay_error()}

  @callback verify_status(provider_order_id :: String.t(), config :: map()) ::
              {:ok, [map()]} | {:error, term()}
end
