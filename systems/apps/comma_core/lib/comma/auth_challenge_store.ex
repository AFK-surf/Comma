defmodule Comma.AuthChallengeStore do
  @moduledoc """
  Storage boundary for passwordless email login challenges and abuse controls.

  Implementations must keep challenges short-lived and make verification
  one-time. Request limits, verification-failure windows, and the provider
  circuit breaker must be atomic within the selected store. Production uses
  Redis; tests can use the in-memory implementation.
  """

  @type retry_after_seconds :: pos_integer()

  @callback reserve_attempt(map(), pos_integer(), map()) ::
              :ok
              | {:error, :rate_limited, retry_after_seconds()}
              | {:error, term()}

  @callback verify(String.t(), String.t(), pos_integer()) ::
              {:ok, map()} | {:error, :not_found | :invalid_code | :too_many_attempts | term()}

  @callback reserve(map(), pos_integer(), map()) ::
              :ok
              | {:error, :rate_limited, retry_after_seconds()}
              | {:error, :provider_unavailable, retry_after_seconds()}
              | {:error, term()}

  @callback verify(String.t(), String.t(), pos_integer(), map()) ::
              {:ok, map()}
              | {:error, :not_found | :invalid_code | :too_many_attempts | term()}
              | {:error, :rate_limited, retry_after_seconds()}

  @callback record_delivery(:ok | :error, map()) ::
              :ok | {:ok, :circuit_open} | {:error, term()}

  @callback delete(String.t()) :: :ok | {:error, term()}
end
