defmodule CommaWeb.CheckoutAnalytics do
  @moduledoc """
  Server-side purchase events of a Comma Workspace: the Stripe checkout funnel,
  redeemed codes and App Store purchases.

  `comma_checkout_created` and `comma_checkout_failed` observe one
  `POST /v1/comma/workspaces/:id/billing/checkout` answer for the requesting
  User. A created checkout is keyed by its Stripe session and timed by the
  session's creation, so a request that reuses the account's open session adds
  no second event. A failure is keyed by the request's `client_request_id` and
  names a bounded `failure_kind`.

  `comma_checkout_completed` observes a paid (or free) Stripe Checkout of a
  Comma Workspace from its webhook, keyed by the session and timed by the Stripe
  event, for the Workspace owner. A checkout completed before its payment
  settled is observed when the payment succeeds. A webhook replay repeats the
  event with the same id and time, so it adds no second event. A checkout
  requested with DNT carries `analytics_opt_out` in its Stripe metadata and is
  not observed on completion. A request that reuses an open session keeps the
  opt-out of the request that created it.

  All three events name the same catalog `plan_key` and `checkout_mode`, so
  an abandoned checkout is a created one without a completion of the same plan
  within the 24-hour session. They never carry a provider id, amount, email or
  address. Observation never changes the checkout or webhook answer.
  Subscription changes (`billing.change`) are outside this funnel.

  `comma_code_redeemed` observes a redeem code the requesting User applied to a
  Workspace, keyed by the redemption, with its `package_code` and `redeem_kind`
  (`subscription` or `one_time`). A repeated request answers the first
  redemption and adds no event. A code an operator applies in Admin is not
  observed. A rejected code has no event.

  `comma_store_purchase_started` observes an answered App Store purchase
  intent of the requesting User: the store's payment sheet opens next. It is
  keyed by the Workspace, the plan and the UTC day, so a sheet cancelled and
  opened again that day adds no second start, as a reused Stripe session adds
  no second created checkout.
  `comma_store_purchase_completed` observes a transaction the User's app
  reported and the server recorded for that Workspace, keyed by the transaction
  and timed by its purchase. A transaction reported again adds no second event.
  A renewal, a refund and a transaction recorded for another Workspace have no
  event. A purchase the app never reports (only the App Store notification
  recorded it) has no event until the app starts again. A cancelled payment
  sheet has no event: it is a started purchase without a completion. Both name
  `provider` `apple`, the `plan_key` and the `checkout_mode`.

  A completed checkout, a redeemed code and a completed store purchase also
  refresh the Workspace owner's profile, so its `plan` follows the purchase.
  """

  alias Comma.{Analytics, Repo}
  alias Comma.Billing.PricingV1
  alias Comma.Data.Workspace

  @session_lifetime_s 86_400

  @doc "Observes one checkout request answer. `plan_key` is the requested key; non-catalog keys are dropped."
  def requested(user_id, workspace_id, plan_key, request_id, result) do
    properties =
      %{"workspace_id" => workspace_id}
      |> Map.merge(plan_properties(catalog_version(plan_key)))

    case result do
      {:ok, %{"id" => session_id} = session} when is_binary(session_id) ->
        Analytics.capture(
          user_id,
          "comma_checkout_created",
          session_id,
          properties,
          session_created_at(session)
        )

      {:error, reason} when is_binary(request_id) ->
        Analytics.capture(
          user_id,
          "comma_checkout_failed",
          "checkout-request:" <> request_id,
          Map.put(properties, "failure_kind", failure_kind(reason))
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Observes a verified Stripe webhook event, replays included. Other events and products are ignored."
  def webhook(%{"type" => type, "data" => %{"object" => session}} = event)
      when type in ["checkout.session.completed", "checkout.session.async_payment_succeeded"] and
             is_map(session) do
    status =
      if type == "checkout.session.async_payment_succeeded",
        do: "paid",
        else: session["payment_status"]

    metadata = session["metadata"] || %{}

    with true <- Analytics.configured?(),
         true <- status in ["paid", "no_payment_required"],
         "comma" <- metadata["surface"],
         "workspace" <- metadata["product_owner_type"],
         false <- metadata["analytics_opt_out"] == "true",
         workspace_id when is_binary(workspace_id) <- metadata["product_owner_id"],
         session_id when is_binary(session_id) <- session["id"],
         %Workspace{owner_user_id: owner} when is_binary(owner) <-
           Repo.get(Workspace, workspace_id) do
      version = catalog_version(metadata["package_code"], metadata["package_version"])

      Analytics.capture(
        owner,
        "comma_checkout_completed",
        session_id,
        %{
          "workspace_id" => workspace_id,
          "package_code" => metadata["package_code"],
          "checkout_mode" => session["mode"],
          "payment_status" => status
        }
        |> Map.merge(plan_properties(version)),
        unix_time(event["created"])
      )

      Analytics.identify(owner)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def webhook(_event), do: :ok

  @doc "Observes a redeem answer of `BillingCommerce.apply_redeem_code/1` for the requesting User."
  def redeemed(user_id, workspace, %{redemption: %{id: id}, idempotent: false} = result)
      when is_binary(id) do
    {kind, package} =
      case result do
        %{subscription: %{package_code: _} = subscription} -> {"subscription", subscription}
        %{purchase: %{package_code: _} = purchase} -> {"one_time", purchase}
      end

    version = catalog_version(package.package_code, package.package_version)

    Analytics.capture(
      user_id,
      "comma_code_redeemed",
      id,
      %{
        "workspace_id" => workspace["id"],
        "package_code" => package.package_code,
        "redeem_kind" => kind
      }
      |> Map.merge(Map.take(plan_properties(version), ["plan_key"]))
    )

    Analytics.identify(workspace["owner_user_id"])
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def redeemed(_user_id, _workspace, _result), do: :ok

  @doc "Observes an answered App Store purchase intent. `plan_key` is the plan the store sells."
  def store_started(user_id, workspace, plan_key) do
    Analytics.capture(
      user_id,
      "comma_store_purchase_started",
      "store-intent:#{workspace["id"]}:#{plan_key}:#{DateTime.to_date(SystemsClock.utc_now())}",
      store_properties(workspace, plan_key)
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Observes a store transaction the User's app reported, from the answer of
  `BillingApple.sync_transaction/2`. Only a purchase recorded for `workspace` counts.
  """
  def store_completed(
        user_id,
        %{"billing_account_id" => account} = workspace,
        {:ok,
         %{
           billing_account_id: account,
           transaction_id: transaction_id,
           bought: %{product_id: plan_key, at: %DateTime{} = at}
         }}
      ) do
    Analytics.capture(
      user_id,
      "comma_store_purchase_completed",
      "apple:#{transaction_id}",
      store_properties(workspace, plan_key),
      at
    )

    Analytics.identify(workspace["owner_user_id"])
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def store_completed(_user_id, _workspace, _result), do: :ok

  defp store_properties(workspace, plan_key) do
    version = catalog_version(plan_key)

    %{"workspace_id" => workspace["id"], "provider" => "apple"}
    |> Map.merge(plan_properties(version))
    |> Map.merge(if(version, do: %{"package_code" => version.package_code}, else: %{}))
  end

  @doc false
  def failure_kind(reason) do
    case reason do
      r
      when r in [
             :invalid_plan_selector,
             :plan_not_purchasable,
             :stripe_price_not_synced,
             :not_found
           ] ->
        "plan_unavailable"

      r when r in [:subscription_already_exists, :subscription_active_elsewhere] ->
        "already_subscribed"

      :subscription_checkout_pending ->
        "checkout_pending"

      r when r in [:subscription_checkout_expired, :quote_expired] ->
        "checkout_expired"

      :stripe_not_configured ->
        "provider_unavailable"

      %{__struct__: Stripe.Error, source: :network} ->
        "provider_unavailable"

      %{__struct__: Stripe.Error} ->
        "provider_error"

      :invalid_checkout_request ->
        "invalid_request"

      _ ->
        "other"
    end
  end

  defp catalog_version(plan_key) when is_binary(plan_key),
    do: Enum.find(PricingV1.catalog().versions, &(&1.provider_lookup_key == plan_key))

  defp catalog_version(_plan_key), do: nil

  defp catalog_version(package_code, version),
    do:
      Enum.find(
        PricingV1.catalog().versions,
        &(&1.package_code == package_code and &1.version == version)
      )

  defp plan_properties(%{provider_lookup_key: key, kind: kind}),
    do: %{
      "plan_key" => key,
      "checkout_mode" => if(kind == "one_time", do: "payment", else: "subscription")
    }

  defp plan_properties(_version), do: %{}

  # The Stripe session lasts 24 hours from creation, so a reused session keeps
  # its first creation time and its event deduplicates on any day. Stripe keeps
  # whole seconds: round up, so a created checkout never precedes the client's
  # request for it.
  defp session_created_at(%{"expires_at" => expires_at}) when is_integer(expires_at),
    do: unix_time(expires_at - @session_lifetime_s + 1)

  defp session_created_at(_session), do: SystemsClock.utc_now()

  defp unix_time(seconds) when is_integer(seconds), do: DateTime.from_unix!(seconds)
  defp unix_time(_seconds), do: SystemsClock.utc_now()
end
