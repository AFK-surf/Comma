defmodule BillingCommerce.SubscriptionCheckout do
  @moduledoc "The Billing Account owns its single pending subscription Checkout."

  def create(attrs, create_session, retrieve_session) do
    repo = Application.fetch_env!(:billing_commerce, :repo)
    account_id = attrs[:billing_account_id] || attrs["billing_account_id"]

    with {:ok, pending} <- reserve(repo, account_id, attrs),
         {:ok, session} <- resolve(pending, attrs, create_session, retrieve_session),
         {:ok, result} <- store(repo, account_id, pending, session) do
      result
    end
  end

  defp reserve(repo, account_id, attrs) do
    repo.transaction(fn ->
      pending = lock(repo, account_id)

      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          """
          SELECT id FROM billing_subscriptions
          WHERE billing_account_id = $1 AND source_type = 'stripe_subscription'
            AND status IN ('active', 'trialing', 'past_due', 'unpaid', 'paused') LIMIT 1
          """,
          [account_id]
        )

      if rows != [], do: repo.rollback(:subscription_already_exists)
      pending || new_pending(repo, account_id, attrs)
    end)
  end

  defp new_pending(repo, account_id, attrs) do
    key =
      "comma:subscription-checkout:" <>
        Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    request =
      attrs
      |> Map.put(:idempotency_key, key)
      |> Map.put(:expires_at, DateTime.to_unix(DateTime.utc_now()) + 86_400)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    pending = %{
      "key" => key,
      "plan" => attrs[:provider_price_id] || attrs["provider_price_id"],
      "request" => request,
      "stage" => "creating"
    }

    save(repo, account_id, pending)
    pending
  end

  defp resolve(%{"session" => session} = pending, attrs, _create, retrieve) do
    with {:ok, current} <- retrieve.(session["id"]) do
      cond do
        current["status"] == "expired" ->
          {:ok, Map.put(current, "expired", true)}

        pending["plan"] != (attrs[:provider_price_id] || attrs["provider_price_id"]) ->
          {:error, :subscription_checkout_pending}

        true ->
          {:ok, Map.merge(session, current)}
      end
    end
  end

  defp resolve(pending, attrs, create, _retrieve) do
    if pending["plan"] == (attrs[:provider_price_id] || attrs["provider_price_id"]) do
      create.(pending["request"])
    else
      {:error, :subscription_checkout_pending}
    end
  end

  defp store(repo, account_id, pending, session) do
    repo.transaction(fn ->
      current = lock(repo, account_id)

      cond do
        current == nil ->
          {:error, :subscription_already_exists}

        current["key"] != pending["key"] ->
          {:error, :subscription_checkout_pending}

        session["expired"] ->
          save(repo, account_id, nil)
          {:error, :subscription_checkout_expired}

        true ->
          save(
            repo,
            account_id,
            Map.merge(current, %{"session" => session, "stage" => session["status"] || "open"})
          )

          {:ok, session}
      end
    end)
  end

  defp lock(repo, account_id) do
    case Ecto.Adapters.SQL.query!(
           repo,
           "SELECT subscription_checkout FROM billing_accounts WHERE id = $1 FOR UPDATE",
           [account_id]
         ).rows do
      [[pending]] -> pending
      [] -> repo.rollback(:billing_account_not_found)
    end
  end

  defp save(repo, account_id, pending) do
    Ecto.Adapters.SQL.query!(
      repo,
      "UPDATE billing_accounts SET subscription_checkout = $2::jsonb, updated_at = now() WHERE id = $1",
      [account_id, pending]
    )
  end
end
