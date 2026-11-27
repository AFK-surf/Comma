defmodule BillingApple do
  @moduledoc """
  App Store in-app purchases for Comma. Contract:
  `docs/architecture/DOMAIN_CONCEPTS.md#store-purchases`.
  """

  alias BillingApple.{JWS, Transactions}

  @provider "apple"

  @doc "True when the App Store Server API key and bundle id are configured."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _}, config(fn _owner -> nil end))

  @doc """
  The email domains whose Billing Account owners may record sandbox transactions.
  App Review and TestFlight pay nothing in the sandbox, so other owners get no credits from it.
  """
  @spec sandbox_email_domains() :: [String.t()]
  def sandbox_email_domains, do: ~w(cue.surf comma.surf)

  @doc """
  Reads one transaction from the App Store and records it.

  `owner_email` gives the email of a Billing Account owner (`%{product_owner_type,
  product_owner_id}`), or nil. A sandbox transaction is recorded only for an
  owner whose email is at a sandbox domain (`sandbox_email_domains/0`).
  """
  @spec sync_transaction(String.t(), (map() -> String.t() | nil)) ::
          {:ok, map()} | {:error, term()}
  def sync_transaction(transaction_id, owner_email) do
    with {:ok, config} <- config(owner_email), do: Transactions.sync(transaction_id, config)
  end

  @doc """
  Handles an App Store Server Notification V2 body (`signedPayload`).

  The notification only names a transaction. The transaction is read again
  from the App Store before anything is recorded.
  """
  @spec handle_notification(map(), (map() -> String.t() | nil)) ::
          {:ok, map()} | {:error, term()}
  def handle_notification(%{"signedPayload" => signed}, owner_email) do
    with {:ok, config} <- config(owner_email),
         {:ok, payload} <- JWS.payload(signed) do
      data = payload["data"] || %{}

      cond do
        data["bundleId"] != config.bundle_id ->
          {:ok, %{ignored: true, reason: :other_bundle}}

        is_binary(data["signedTransactionInfo"]) ->
          with {:ok, tx} <- JWS.payload(data["signedTransactionInfo"]),
               do: Transactions.sync(to_string(tx["transactionId"]), config)

        true ->
          {:ok, %{ignored: true, reason: :no_transaction}}
      end
    end
  end

  def handle_notification(_body, _owner_email), do: {:error, :invalid_apple_notification}

  @doc """
  Returns the `appAccountToken` of a Billing Account: its `apple` Provider
  Customer id, a lowercase UUID made on first use.
  """
  @spec account_token(map()) :: {:ok, String.t()} | {:error, term()}
  def account_token(owner) do
    account = Map.fetch!(owner, :billing_account_id)
    lookup = %{billing_account_id: account, provider: @provider}

    case BillingCommerce.get_active_provider_customer(lookup) do
      {:ok, customer} ->
        {:ok, customer.provider_customer_id}

      {:error, :not_found} ->
        owner
        |> Map.merge(%{
          provider: @provider,
          provider_customer_id: SystemsRuntime.Proc.uuid(),
          source_type: "apple_account_token"
        })
        |> BillingCommerce.bind_provider_customer()
        |> case do
          {:ok, customer} ->
            {:ok, customer.provider_customer_id}

          # A concurrent request bound the account first.
          {:error, _} ->
            with {:ok, customer} <- BillingCommerce.get_active_provider_customer(lookup),
                 do: {:ok, customer.provider_customer_id}
        end
    end
  end

  defp config(owner_email) do
    values = %{
      owner_email: owner_email,
      api: SystemsRuntime.get_env(:billing_apple, :api, BillingApple.ServerAPI),
      issuer_id: SystemsRuntime.get_env(:billing_apple, :issuer_id),
      key_id: SystemsRuntime.get_env(:billing_apple, :key_id),
      private_key: SystemsRuntime.get_env(:billing_apple, :private_key),
      bundle_id: SystemsRuntime.get_env(:billing_apple, :bundle_id)
    }

    if Enum.all?([:issuer_id, :key_id, :private_key, :bundle_id], &present?(values[&1])),
      do: {:ok, values},
      else: {:error, :apple_not_configured}
  end

  defp present?(value), do: is_binary(value) and value != ""
end
