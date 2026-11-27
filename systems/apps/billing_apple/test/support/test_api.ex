defmodule BillingApple.TestAPI do
  @moduledoc "App Store Server API stand-in. Tests put transactions and statuses in the env."
  @behaviour BillingApple.API

  @doc "Encodes a payload as an unsigned compact JWS, as Apple's values are shaped."
  def jws(payload) do
    part = &Base.url_encode64(Jason.encode!(&1), padding: false)
    part.(%{"alg" => "ES256"}) <> "." <> part.(payload) <> ".sig"
  end

  @impl true
  def get_transaction(environment, id, _config) do
    record(:transaction, environment, id)

    case SystemsRuntime.get_env(:billing_apple, :test_transactions, %{}) do
      %{^id => %{environment: ^environment, tx: tx}} -> {:ok, jws(tx)}
      %{^id => {:error, _reason} = error} -> error
      _ -> {:error, :not_found}
    end
  end

  @impl true
  def get_subscription_statuses(environment, original, _config) do
    record(:statuses, environment, original)

    case SystemsRuntime.get_env(:billing_apple, :test_statuses, %{}) do
      %{^original => body} -> {:ok, body}
      _ -> {:error, :not_found}
    end
  end

  defp record(kind, environment, id) do
    calls = SystemsRuntime.get_env(:billing_apple, :test_calls, [])
    SystemsRuntime.put_env(:billing_apple, :test_calls, calls ++ [{kind, environment, id}])
  end
end
