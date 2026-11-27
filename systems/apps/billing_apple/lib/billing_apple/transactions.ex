defmodule BillingApple.Transactions do
  @moduledoc """
  Records one App Store transaction after reading it from the App Store Server API.

  A notification or a client report gives only a transaction id. This module
  reads the transaction from Apple, then records it through the provider-neutral
  billing commands. Every step is idempotent, so a repeated id records nothing new.

  - The Apple product id is the Comma plan key. The plan selects the package.
  - `appAccountToken` is the `apple` Provider Customer id of the Billing Account
    (`BillingApple.account_token/1`). A renewal of a recorded subscription uses
    the subscription's account.
  - A subscription payment covers `[purchaseDate, expiresDate)`. Sandbox periods
    last minutes, so the period length cannot be derived from the plan. A
    non-renewal payment that starts before an earlier payment of the subscription
    ends is an upgrade or an immediate change. It replaces that payment
    (`PaidCycles` `replaces`). A renewal replaces nothing.
  - An upgraded transaction (`isUpgraded`) records nothing. Its successor does.
  - A revoked transaction is a full refund through `PaymentRights`.
  - Free offers (price 0) grant nothing, because no cash is confirmed.
  - A sandbox transaction pays nothing. It records only for a Billing Account
    whose owner's email is at `BillingApple.sandbox_email_domains/0` (App Review
    and team accounts). Others answer `apple_sandbox_not_allowed`.
  """

  alias BillingCommerce.{PackageCatalog, PaidCycles, PaymentRights, Subscriptions}

  @subscription "Auto-Renewable Subscription"
  @consumable "Consumable"

  @spec sync(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def sync(transaction_id, config) do
    with :ok <- valid_id(transaction_id),
         {:ok, environment, tx} <- fetch(transaction_id, config),
         :ok <- same_bundle(tx, config),
         :ok <- purchaser_owned(tx),
         {:ok, package} <- package(tx["productId"]) do
      cond do
        tx["isUpgraded"] == true ->
          {:ok, %{ignored: true, reason: :upgraded, transaction_id: transaction_id}}

        tx["type"] == @subscription and package.kind == "subscription" ->
          subscription(tx, environment, package, config)

        tx["type"] == @consumable and package.kind != "subscription" ->
          purchase(tx, environment, package, config)

        true ->
          {:error, :apple_product_type_mismatch}
      end
    end
  end

  defp subscription(tx, environment, package, config) do
    original = Map.fetch!(tx, "originalTransactionId")
    payment_id = payment_id(tx)
    expires = ms!(tx["expiresDate"])
    starts = ms!(tx["purchaseDate"])

    with :ok <- paid(tx),
         {:ok, owner} <- subscription_owner(original, tx),
         :ok <- sandbox_allowed(environment, owner, config),
         {:ok, %{subscription: subscription, cycles: cycles}} <-
           Subscriptions.create_subscription(
             Map.merge(owner, %{
               package_code: package.package_code,
               package_version: package.version,
               source_type: "apple_subscription",
               source_id: original,
               source_event_id: payment_id,
               idempotency_key: "apple:subscription:#{original}",
               source_metadata: %{"apple_environment" => environment},
               periods:
                 periods(starts, expires, package.billing_period, payment_id, tx["transactionId"])
             })
           ),
         {:ok, _} <-
           PaidCycles.record_invoice(
             subscription,
             package,
             payment_id,
             %{
               provider: "apple",
               payment_id: payment_id,
               valid_from: starts,
               expires_at: expires,
               disputes: %{},
               fully_refunded: is_integer(tx["revocationDate"]),
               cycle_ids: Enum.map(cycles, & &1.id),
               replaces:
                 if(tx["transactionReason"] == "RENEWAL",
                   do: nil,
                   else: %{at: starts, provider: "apple"}
                 )
             },
             SystemsClock.utc_now()
           ),
         :ok <- revoke(tx),
         {:ok, status} <- reconcile(original, environment, payment_id, config) do
      {:ok,
       %{
         recorded: :subscription,
         transaction_id: tx["transactionId"],
         billing_account_id: owner.billing_account_id,
         status: status
       }
       |> Map.merge(bought(tx, starts))}
    end
  end

  defp purchase(tx, environment, package, config) do
    payment_id = payment_id(tx)
    paid_at = ms!(tx["purchaseDate"])
    month = Date.new!(paid_at.year, paid_at.month, 1) |> Date.shift(month: 1)

    with :ok <- paid(tx),
         {:ok, owner} <- token_owner(tx),
         :ok <- sandbox_allowed(environment, owner, config) do
      if is_integer(tx["revocationDate"]) do
        case PaymentRights.apply(payment_id, "apple:revocation:#{tx["transactionId"]}", fn ->
               {:ok, %{type: :refund, amount: div(tx["price"], 10), full: true}}
             end) do
          {:ok, _} ->
            {:ok,
             %{
               recorded: :purchase,
               transaction_id: tx["transactionId"],
               billing_account_id: owner.billing_account_id
             }}

          {:error, :stripe_payment_not_recorded} ->
            {:ok, %{ignored: true, reason: :revoked, transaction_id: tx["transactionId"]}}

          {:error, reason} ->
            {:error, reason}
        end
      else
        with {:ok, _} <-
               Subscriptions.issue_one_time_purchase(
                 Map.merge(owner, %{
                   package_code: package.package_code,
                   package_version: package.version,
                   source_type: "apple_purchase",
                   source_id: tx["transactionId"],
                   source_event_id: payment_id,
                   idempotency_key: "apple:purchase:#{tx["transactionId"]}",
                   source_metadata: %{"apple_environment" => environment},
                   metadata: %{"provider" => "apple", "provider_payment_id" => payment_id},
                   provider_payment_intent_id: payment_id,
                   valid_from: paid_at,
                   expires_at: DateTime.new!(month, ~T[00:00:00], "Etc/UTC")
                 })
               ) do
          {:ok,
           %{
             recorded: :purchase,
             transaction_id: tx["transactionId"],
             billing_account_id: owner.billing_account_id
           }
           |> Map.merge(bought(tx, paid_at))}
        end
      end
    end
  end

  # What the person bought, for a payment they made themselves: a renewal is
  # Apple's charge and a revoked transaction is a refund, so neither has one.
  defp bought(tx, at) do
    if tx["transactionReason"] == "RENEWAL" or is_integer(tx["revocationDate"]),
      do: %{},
      else: %{bought: %{product_id: tx["productId"], at: at}}
  end

  # Apple answers 4040010 when the id belongs to the other environment.
  # App Review buys in the sandbox against the production server.
  defp fetch(id, config) do
    case config.api.get_transaction(:production, id, config) do
      {:error, :not_found} -> fetch_in(:sandbox, id, config)
      {:error, reason} -> {:error, error(reason)}
      {:ok, signed} -> decoded(:production, signed)
    end
  end

  defp fetch_in(environment, id, config) do
    case config.api.get_transaction(environment, id, config) do
      {:ok, signed} -> decoded(environment, signed)
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp decoded(environment, signed) do
    with {:ok, tx} <- BillingApple.JWS.payload(signed),
         do: {:ok, Atom.to_string(environment), tx}
  end

  defp error(:not_found), do: :apple_transaction_not_found
  defp error(reason), do: reason

  defp sandbox_allowed("sandbox", owner, config) do
    email = config.owner_email.(owner)

    allowed? =
      is_binary(email) and
        Enum.any?(
          BillingApple.sandbox_email_domains(),
          &String.ends_with?(String.downcase(email), "@" <> &1)
        )

    if allowed?, do: :ok, else: {:error, :apple_sandbox_not_allowed}
  end

  defp sandbox_allowed(_production, _owner, _config), do: :ok

  defp same_bundle(%{"bundleId" => bundle}, %{bundle_id: bundle}), do: :ok
  defp same_bundle(_tx, _config), do: {:error, :apple_bundle_mismatch}

  defp purchaser_owned(%{"inAppOwnershipType" => "FAMILY_SHARED"}),
    do: {:error, :apple_family_shared_not_allowed}

  defp purchaser_owned(_tx), do: :ok

  defp paid(%{"price" => price}) when is_integer(price) and price > 0, do: :ok
  defp paid(_tx), do: {:error, :apple_unpaid_transaction}

  defp package(product_id) when is_binary(product_id) do
    with {:ok, plan} <-
           BillingCommerce.get_provider_plan(%{
             surface: "comma",
             provider: "stripe",
             provider_lookup_key: product_id
           }) do
      PackageCatalog.get_package_version(%{
        package_code: plan.package_code,
        version: plan.package_version
      })
    else
      {:error, :not_found} -> {:error, :apple_product_unknown}
    end
  end

  defp package(_product_id), do: {:error, :apple_product_unknown}

  defp subscription_owner(original, tx) do
    case Ecto.Adapters.SQL.query!(
           repo(),
           """
           SELECT billing_account_id, surface, product_owner_type, product_owner_id
           FROM billing_subscriptions
           WHERE source_type = 'apple_subscription' AND source_id = $1
           """,
           [original]
         ).rows do
      [[account, surface, owner_type, owner_id]] ->
        {:ok, owner(account, surface, owner_type, owner_id)}

      [] ->
        token_owner(tx)
    end
  end

  defp token_owner(%{"appAccountToken" => token}) when is_binary(token) do
    case BillingCommerce.get_provider_customer_by_id(%{
           provider: "apple",
           provider_customer_id: String.downcase(token)
         }) do
      {:ok, customer} ->
        {:ok,
         owner(
           customer.billing_account_id,
           customer.surface,
           customer.product_owner_type,
           customer.product_owner_id
         )}

      {:error, :not_found} ->
        {:error, :apple_account_unknown}
    end
  end

  defp token_owner(_tx), do: {:error, :apple_account_unknown}

  defp owner(account, surface, owner_type, owner_id) do
    %{
      billing_account_id: account,
      surface: surface,
      product_owner_type: owner_type,
      product_owner_id: owner_id
    }
  end

  # An annual payment allocates one cycle per month, as Stripe annual plans do.
  # Keys include the transaction id and start time so a new payment never collides
  # with an earlier or replaced cycle.
  defp periods(starts, expires, "year", payment_id, tx_id) do
    full_month? = DateTime.compare(DateTime.shift(starts, month: 1), expires) != :gt

    0..11
    |> Enum.map(&DateTime.shift(starts, month: &1))
    # A sandbox year lasts one hour, so it has one cycle.
    |> Enum.filter(&(DateTime.compare(&1, expires) == :lt))
    |> Enum.map(fn from ->
      to = DateTime.shift(from, month: 1)

      period = %{
        cycle_key: "#{tx_id}:#{key(from)}",
        valid_from: from,
        expires_at: if(DateTime.compare(to, expires) == :gt, do: expires, else: to),
        source_event_id: payment_id
      }

      if full_month?,
        do: Map.put(period, :source_metadata, %{"nominal_end" => DateTime.to_iso8601(to)}),
        else: period
    end)
  end

  defp periods(starts, expires, _month, payment_id, tx_id) do
    [
      %{
        cycle_key: "#{tx_id}:#{key(starts)}",
        valid_from: starts,
        expires_at: expires,
        source_event_id: payment_id
      }
    ]
  end

  defp revoke(%{"revocationDate" => revoked} = tx) when is_integer(revoked) do
    case PaymentRights.apply(payment_id(tx), "apple:revocation:#{tx["transactionId"]}", fn ->
           {:ok, %{type: :refund, amount: div(tx["price"], 10), full: true}}
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp revoke(_tx), do: :ok

  # Status and renewal follow the subscription's latest transaction, read under
  # the subscription row lock (tla/billing/SubscriptionReconcile.tla).
  defp reconcile(original, environment, payment_id, config) do
    env = String.to_existing_atom(environment)

    Subscriptions.reconcile_provider_subscription(
      original,
      fn ->
        with {:ok, body} <- config.api.get_subscription_statuses(env, original, config),
             {:ok, last} <- last_transaction(body, original),
             {:ok, tx} <- BillingApple.JWS.payload(last["signedTransactionInfo"]),
             {:ok, renewal} <- renewal(last["signedRenewalInfo"]),
             {:ok, current} <- package(tx["productId"]) do
          {:ok,
           %{
             source_event_id: payment_id,
             status: status(last["status"]),
             package_code: current.package_code,
             package_version: current.version,
             source_metadata: %{
               "cancel_at_period_end" => renewal["autoRenewStatus"] == 0,
               "current_period_end" => div(tx["expiresDate"], 1000),
               "scheduled_plan" => scheduled_plan(renewal, tx),
               "provider_status" => last["status"]
             }
           }}
        end
      end,
      "apple_subscription"
    )
    |> case do
      {:ok, %{status: status}} -> {:ok, status}
      {:ok, other} -> {:ok, other}
      error -> error
    end
  end

  defp last_transaction(%{"data" => groups}, original) when is_list(groups) do
    groups
    |> Enum.flat_map(&(&1["lastTransactions"] || []))
    |> Enum.find(&(&1["originalTransactionId"] == original))
    |> case do
      nil -> {:error, :apple_subscription_status_missing}
      last -> {:ok, last}
    end
  end

  defp last_transaction(_body, _original), do: {:error, :apple_subscription_status_missing}

  defp renewal(signed) when is_binary(signed), do: BillingApple.JWS.payload(signed)
  defp renewal(_signed), do: {:ok, %{}}

  # 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked.
  defp status(1), do: "active"
  defp status(3), do: "past_due"
  defp status(4), do: "active"
  defp status(_expired_or_revoked), do: "canceled"

  defp scheduled_plan(%{"autoRenewProductId" => next} = renewal, %{"productId" => current} = tx)
       when is_binary(next) and next != current do
    renews? = renewal["autoRenewStatus"] != 0

    case package(next) do
      {:ok, package} when renews? ->
        %{
          "package_code" => package.package_code,
          "package_version" => package.version,
          "effective_at" => div(tx["expiresDate"], 1000)
        }

      _ ->
        nil
    end
  end

  defp scheduled_plan(_renewal, _tx), do: nil

  defp payment_id(tx), do: "apple:" <> Map.fetch!(tx, "transactionId")

  defp valid_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[0-9]{1,32}\z/, id), do: :ok, else: {:error, :invalid_transaction_id}
  end

  defp valid_id(_id), do: {:error, :invalid_transaction_id}

  defp key(at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp ms!(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)

  defp repo, do: SystemsRuntime.fetch_env!(:billing_commerce, :repo)
end
