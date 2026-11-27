defmodule BillingCommerce.SubscriptionCheckout do
  @moduledoc "The Billing Account owns its single pending subscription Checkout."

  def create(attrs, create_session, retrieve_session) do
    repo = SystemsRuntime.fetch_env!(:billing_commerce, :repo)
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
      now = SystemsClock.utc_now()

      if quote_expires_at = attrs[:quote_expires_at] || attrs["quote_expires_at"] do
        if is_integer(quote_expires_at) and DateTime.to_unix(now, :second) >= quote_expires_at do
          repo.rollback(:quote_expired)
        end
      end

      # One payment channel owns the account's subscription at a time.
      # A cancelled subscription keeps its status until its paid period ends.
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          """
          SELECT source_type FROM billing_subscriptions
          WHERE billing_account_id = $1
            AND source_type IN ('stripe_subscription', 'apple_subscription', 'google_subscription')
            AND status IN ('active', 'trialing', 'past_due', 'unpaid', 'paused') LIMIT 1
          """,
          [account_id]
        )

      case rows do
        [] -> :ok
        [["stripe_subscription"]] -> repo.rollback(:subscription_already_exists)
        [[_store]] -> repo.rollback(:subscription_active_elsewhere)
      end

      %{rows: m2_paid_rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          """
          SELECT c.id
          FROM billing_subscription_cycles c
          JOIN billing_subscriptions s ON s.id = c.subscription_id
          CROSS JOIN LATERAL jsonb_each(COALESCE(c.source_metadata->'payment_sources', '{}'::jsonb)) p
          WHERE c.billing_account_id = $1
            AND s.source_type = 'm2square_term'
            AND c.period_end > $2
            AND p.value->>'state' = 'paid'
          LIMIT 1
          """,
          [account_id, now]
        )

      if m2_paid_rows != [], do: repo.rollback(:subscription_already_exists)

      %{rows: m2_pending_rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          """
          SELECT mch_order_id
          FROM billing_m2square_orders
          WHERE billing_account_id = $1
            AND status IN ('creating', 'open')
            AND inserted_at > $2
          LIMIT 1
          """,
          [account_id, DateTime.add(now, -3600, :second)]
        )

      if m2_pending_rows != [], do: repo.rollback(:subscription_checkout_pending)

      pending || new_pending(repo, account_id, attrs)
    end)
  end

  defp new_pending(repo, account_id, attrs) do
    key =
      "comma:subscription-checkout:" <>
        Base.url_encode64(SystemsRuntime.Proc.random_bytes(24), padding: false)

    request =
      attrs
      |> Map.drop([:quote_expires_at, "quote_expires_at"])
      |> Map.put(:idempotency_key, key)
      |> Map.put(:expires_at, DateTime.to_unix(SystemsClock.utc_now()) + 86_400)
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

        not same_purchase?(pending, attrs) ->
          {:error, :subscription_checkout_pending}

        true ->
          {:ok, Map.merge(session, current)}
      end
    end
  end

  defp resolve(pending, attrs, create, _retrieve) do
    if same_purchase?(pending, attrs) do
      create.(pending["request"])
    else
      {:error, :subscription_checkout_pending}
    end
  end

  defp same_purchase?(pending, attrs) do
    request = pending["request"]

    pending["plan"] == (attrs[:provider_price_id] || attrs["provider_price_id"]) and
      (request["quantity"] || 1) == (attrs[:quantity] || attrs["quantity"] || 1) and
      request["teams_signup"] == (attrs[:teams_signup] || attrs["teams_signup"])
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
