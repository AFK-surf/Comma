defmodule BillingStripe.Events do
  @moduledoc """
  Maps Stripe events into BillingCommerce source commands.

  Payment and provider replay safety are modeled in
  `tla/billing/StripeCredits.tla`.
  """

  alias BillingCommerce.{PackageCatalog, Subscriptions}

  @spec process(map()) :: {:ok, map()} | {:error, term()}
  def process(%{"id" => event_id, "type" => "invoice.paid", "data" => %{"object" => invoice}}) do
    metadata = billing_metadata_with_provider_plan(invoice)
    period = period_from(invoice)
    subscription_id = subscription_id(invoice)
    invoice_cycle_key = cycle_key(period.valid_from)

    with {:ok, package} <-
           PackageCatalog.get_package_version(%{
             package_code: required(metadata, "package_code"),
             version: required(metadata, "package_version")
           }),
         periods <- paid_periods(invoice, period, package.billing_period),
         :ok <- sync_provider_customer(metadata, invoice),
         {:ok, result} <-
           Subscriptions.create_subscription(
             subscription_attrs(metadata, %{
               source_type: "stripe_subscription",
               source_id: subscription_id,
               source_event_id: required(invoice, "id"),
               idempotency_key: "stripe:subscription:#{subscription_id}",
               source_metadata: %{"stripe_invoice_id" => required(invoice, "id")},
               periods: periods
             })
           ),
         {:ok, cycle} <- find_cycle(result.cycles, invoice_cycle_key),
         {:ok, issued} <-
           Subscriptions.run_due_cycles(%{at: period.valid_from, limit: 1, cycle_ids: [cycle.id]}),
         {:ok, _subscription} <-
           reconcile_subscription(subscription_id, event_id, %{
             "stripe_invoice_id" => required(invoice, "id")
           }) do
      {:ok, issued}
    end
  end

  def process(%{
        "id" => event_id,
        "type" => "checkout.session.completed",
        "data" => %{"object" => session}
      }) do
    process_checkout_payment(event_id, session)
  end

  def process(%{
        "id" => event_id,
        "type" => "checkout.session.async_payment_succeeded",
        "data" => %{"object" => session}
      }) do
    process_checkout_payment(event_id, Map.put(session, "payment_status", "paid"))
  end

  def process(%{"id" => event_id, "type" => "charge.refunded", "data" => %{"object" => charge}}) do
    Subscriptions.refund_one_time_purchase(%{
      provider_payment_intent_id: required_payment_intent(charge),
      refunded_amount_minor: required(charge, "amount_refunded"),
      payment_amount_minor: required(charge, "amount"),
      source_type: "stripe_refund",
      source_id: required(charge, "id"),
      source_event_id: event_id,
      reason: "provider_refund"
    })
  end

  def process(%{
        "id" => event_id,
        "type" => "charge.dispute.created",
        "data" => %{"object" => dispute}
      }) do
    payment_intent_id = required_payment_intent(dispute)

    with {:ok, payment_amount_minor} <- payment_intent_amount(payment_intent_id) do
      Subscriptions.refund_one_time_purchase(%{
        provider_payment_intent_id: payment_intent_id,
        refunded_amount_minor: required(dispute, "amount"),
        payment_amount_minor: payment_amount_minor,
        source_type: "stripe_dispute",
        source_id: required(dispute, "id"),
        source_event_id: event_id,
        reason: "provider_dispute"
      })
    end
  end

  def process(%{
        "id" => event_id,
        "type" => "invoice.payment_failed",
        "data" => %{"object" => invoice}
      }) do
    reconcile_subscription(subscription_id(invoice), event_id, %{
      "stripe_invoice_id" => required(invoice, "id")
    })
  end

  def process(%{"id" => event_id, "type" => type, "data" => %{"object" => subscription}})
      when type in [
             "customer.subscription.created",
             "customer.subscription.updated",
             "customer.subscription.deleted",
             "customer.subscription.paused",
             "customer.subscription.resumed"
           ] do
    reconcile_subscription(required(subscription, "id"), event_id)
  end

  def process(_event), do: {:ok, %{ignored: true}}

  # Stripe does not order deliveries. Read the authoritative current object
  # after taking the PG subscription lock, including on invoice delivery.
  # This is one provider read per recorded subscription/event, never a scan.
  # TLA: tla/billing/SubscriptionReconcile.tla.
  defp reconcile_subscription(source_id, event_id, source_metadata \\ %{}) do
    Subscriptions.reconcile_provider_subscription(source_id, fn ->
      with {:ok, config} <- stripe_config(),
           {:ok, subscription} <-
             config.api.retrieve_subscription(source_id, %{},
               api_key: config.secret_key,
               response_as: :map
             ) do
        {:ok,
         Map.merge(
           %{
             source_event_id: event_id,
             status: provider_subscription_status(subscription),
             source_metadata:
               Map.merge(source_metadata, %{
                 "cancel_at_period_end" => subscription["cancel_at_period_end"] == true,
                 "provider_price_id" => provider_price_id(subscription),
                 "provider_status" => subscription["status"]
               })
           },
           provider_plan_attrs(subscription, billing_metadata(subscription))
         )}
      end
    end)
  end

  defp process_checkout_payment(event_id, session) do
    metadata = billing_metadata(session)

    case {session["mode"], session["payment_status"]} do
      {"payment", status} when status in ["paid", "no_payment_required"] ->
        period = period_from(session)
        payment_intent_id = payment_intent_id(session["payment_intent"])

        with :ok <- sync_provider_customer(metadata, session) do
          Subscriptions.issue_one_time_purchase(
            subscription_attrs(metadata, %{
              source_type: "stripe_checkout",
              source_id: required(session, "id"),
              source_event_id: event_id,
              idempotency_key: "stripe:checkout:#{required(session, "id")}",
              source_metadata: %{
                "stripe_checkout_session_id" => required(session, "id"),
                "stripe_payment_intent_id" => payment_intent_id,
                "payment_status" => status
              },
              provider_payment_intent_id: payment_intent_id,
              valid_from: period.valid_from,
              expires_at: period.expires_at
            })
          )
        end

      {"payment", _pending_or_missing} ->
        {:ok, %{ignored: true, reason: :payment_not_complete}}

      _ ->
        {:ok, %{ignored: true, reason: :not_one_time_payment}}
    end
  end

  @spec billing_metadata(map()) :: map()
  def billing_metadata(object) when is_map(object) do
    subscription_metadata =
      get_in(object, ["parent", "subscription_details", "metadata"]) ||
        get_in(object, ["subscription_details", "metadata"]) ||
        %{}

    if map_size(subscription_metadata) > 0 do
      subscription_metadata
    else
      object["metadata"] || %{}
    end
  end

  defp billing_metadata_with_provider_plan(object) do
    metadata = billing_metadata(object)
    Map.merge(metadata, stringify_plan_attrs(provider_plan_attrs(object, metadata)))
  end

  defp provider_plan_attrs(object, metadata) do
    case provider_price_id(object) do
      price_id when is_binary(price_id) and price_id != "" ->
        case BillingCommerce.get_provider_plan(%{
               provider: "stripe",
               provider_price_id: price_id,
               surface: metadata["surface"] || "comma",
               synced_only: true
             }) do
          {:ok, plan} ->
            %{package_code: plan.package_code, package_version: plan.package_version}

          {:error, :not_found} ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp stringify_plan_attrs(%{package_code: package_code, package_version: package_version}) do
    %{"package_code" => package_code, "package_version" => package_version}
  end

  defp stringify_plan_attrs(_attrs), do: %{}

  defp provider_price_id(object) do
    price =
      get_in(object, ["items", "data", Access.at(0), "price"]) ||
        get_in(object, ["lines", "data", Access.at(0), "price"]) ||
        get_in(object, ["lines", "data", Access.at(0), "pricing", "price_details", "price"])

    case price do
      id when is_binary(id) -> id
      %{"id" => id} -> id
      %{id: id} -> id
      _ -> nil
    end
  end

  defp subscription_id(object) do
    object["subscription"] ||
      get_in(object, ["parent", "subscription_details", "subscription"]) ||
      get_in(object, ["subscription_details", "subscription"]) ||
      required(object, "subscription")
  end

  defp find_cycle(cycles, cycle_key) do
    case Enum.find(cycles, &(&1.cycle_key == cycle_key)) do
      nil -> {:error, :stripe_invoice_cycle_not_found}
      cycle -> {:ok, cycle}
    end
  end

  defp subscription_attrs(metadata, attrs) do
    Map.merge(
      %{
        billing_account_id: required(metadata, "billing_account_id"),
        surface: required(metadata, "surface"),
        product_owner_type: required(metadata, "product_owner_type"),
        product_owner_id: required(metadata, "product_owner_id"),
        package_code: required(metadata, "package_code"),
        package_version: required(metadata, "package_version")
      },
      attrs
    )
  end

  defp sync_provider_customer(metadata, object) do
    customer_id = stripe_customer_id(object["customer"])

    cond do
      is_nil(customer_id) or customer_id == "" ->
        :ok

      true ->
        attrs = %{
          billing_account_id: required(metadata, "billing_account_id"),
          surface: required(metadata, "surface"),
          product_owner_type: required(metadata, "product_owner_type"),
          product_owner_id: required(metadata, "product_owner_id"),
          provider: "stripe",
          provider_context: "default",
          provider_customer_id: customer_id,
          source_type: "stripe_webhook",
          source_event_id: object["id"],
          metadata: %{"object_id" => object["id"], "object_type" => object["object"]}
        }

        case BillingCommerce.get_active_provider_customer(attrs) do
          {:ok, %{provider_customer_id: ^customer_id}} ->
            :ok

          {:ok, _customer} ->
            {:error, :stripe_customer_mismatch}

          {:error, :not_found} ->
            case BillingCommerce.upsert_provider_customer_from_event(attrs) do
              {:ok, _customer} -> :ok
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  defp stripe_customer_id(nil), do: nil
  defp stripe_customer_id(customer) when is_binary(customer), do: customer
  defp stripe_customer_id(%{"id" => id}), do: id
  defp stripe_customer_id(%{id: id}), do: id
  defp stripe_customer_id(_customer), do: nil

  defp period_from(object) do
    metadata = billing_metadata(object)
    line_period = get_in(object, ["lines", "data", Access.at(0), "period"]) || %{}

    %{
      valid_from:
        from_unix!(
          line_period["start"] || object["period_start"] || object["current_period_start"] ||
            required(metadata, "period_start")
        ),
      expires_at:
        from_unix!(
          line_period["end"] || object["period_end"] || object["current_period_end"] ||
            required(metadata, "period_end")
        )
    }
  end

  defp monthly_periods(start_at, end_at) do
    boundaries =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&DateTime.shift(start_at, month: &1))
      |> Enum.take_while(&(DateTime.compare(&1, end_at) == :lt))
      |> Kernel.++([end_at])

    boundaries
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [valid_from, expires_at] ->
      %{
        cycle_key: cycle_key(valid_from),
        valid_from: valid_from,
        expires_at: expires_at,
        source_event_id: cycle_key(valid_from)
      }
    end)
  end

  defp paid_periods(invoice, period, billing_period) do
    # Clover invoice lines contain a price id under pricing.price_details,
    # not an expanded recurring Price. Cadence is already owned by our catalog.
    if billing_period == "year" do
      monthly_periods(period.valid_from, period.expires_at)
    else
      [
        %{
          cycle_key: cycle_key(period.valid_from),
          valid_from: period.valid_from,
          expires_at: period.expires_at,
          source_event_id: required(invoice, "id")
        }
      ]
    end
  end

  defp provider_subscription_status(subscription) do
    case subscription["status"] do
      status when status in ["active", "trialing", "past_due", "unpaid", "paused", "canceled"] ->
        status

      _ ->
        "inactive"
    end
  end

  defp required_payment_intent(object) do
    value =
      object["payment_intent"] ||
        get_in(object, ["charge", "payment_intent"]) ||
        raise(ArgumentError, "missing Stripe field payment_intent")

    payment_intent_id(value)
  end

  defp payment_intent_id(nil), do: nil
  defp payment_intent_id(value) when is_binary(value), do: value
  defp payment_intent_id(%{"id" => id}), do: id
  defp payment_intent_id(%{id: id}), do: id

  defp payment_intent_amount(payment_intent_id) do
    with {:ok, config} <- stripe_config(),
         {:ok, payment_intent} <-
           config.api.retrieve_payment_intent(
             payment_intent_id,
             %{},
             api_key: config.secret_key
           ),
         amount when is_integer(amount) and amount > 0 <-
           map_value(payment_intent, :amount) do
      {:ok, amount}
    else
      {:error, reason} -> {:error, reason}
      _invalid_response -> {:error, :invalid_stripe_payment_intent_amount}
    end
  end

  defp stripe_config do
    case Application.get_env(:billing_stripe, :secret_key) do
      key when is_binary(key) and key != "" ->
        {:ok,
         %{
           secret_key: key,
           api: Application.get_env(:billing_stripe, :stripe_api, BillingStripe.StripityAPI)
         }}

      _ ->
        {:error, :stripe_not_configured}
    end
  end

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp cycle_key(%DateTime{} = at) do
    date = DateTime.to_date(at)
    "#{date.year}-#{String.pad_leading(Integer.to_string(date.month), 2, "0")}"
  end

  defp from_unix!(value) when is_integer(value), do: DateTime.from_unix!(value)

  defp from_unix!(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> DateTime.from_unix!(int)
      _ -> raise ArgumentError, "invalid stripe unix timestamp #{value}"
    end
  end

  defp required(map, key), do: map[key] || raise(ArgumentError, "missing Stripe field #{key}")
end
