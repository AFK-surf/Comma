defmodule BillingApple.API do
  @moduledoc """
  App Store Server API reads. The App Store is the authority for transactions.

  `environment` is `:production` or `:sandbox`. Responses keep Apple's signed
  values; `BillingApple.JWS` decodes them after a read over TLS from Apple.
  """

  @type environment :: :production | :sandbox

  @doc "Reads one transaction. Answers `{:ok, signed_transaction_info}`."
  @callback get_transaction(environment(), transaction_id :: String.t(), config :: map()) ::
              {:ok, String.t()} | {:error, :not_found | term()}

  @doc "Reads the subscription statuses of the transaction's subscription."
  @callback get_subscription_statuses(environment(), transaction_id :: String.t(), map()) ::
              {:ok, map()} | {:error, :not_found | term()}
end
