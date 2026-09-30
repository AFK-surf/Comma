defmodule BillingStripe.Events do
  @moduledoc """
  Maps Stripe events into BillingCommerce source commands.

  Payment and provider replay safety are modeled in
  `tla/billing/StripeCredits.tla`.
  """

  alias BillingCommerce.{PackageCatalog, Subscriptions}

  @supported_events ~w(invoice.paid invoice.payment_failed checkout.session.completed checkout.session.async_payment_succeeded charge.refunded charge.dispute.created charge.dispute.updated charge.dispute.closed customer.subscription.created customer.subscription.updated customer.subscription.deleted customer.subscription.paused customer.subscription.resumed customer.subscription.pending_update_applied customer.subscription.pending_update_expired subscription_schedule.created subscription_schedule.updated subscription_schedule.released subscription_schedule.canceled subscription_schedule.completed)

  def process(%{"type" => type} = event) when type in @supported_events do
    with {:ok, owner} <- BillingStripe.Ownership.resolve(event) do
      case owner do
        :comma -> do_process(event)
        :foreign -> {:ok, %{ignored: true, reason: :foreign_product}}
      end
    end
  end

  def process(_), do: {:ok, %{ignored: true}}

  defp do_process(%{"id" => event_id, "type" => "invoice.paid", "data" => %{"object" => invoice}}) do
    with {:ok, payment} <- BillingStripe.Payments.invoice_payment(invoice) do
      case payment do
        :not_stripe_payment ->
          if invoice["paid_out_of_band"] == true,
            do: {:ok, %{ignored: true, reason: :not_stripe_payment}},
            else: reconcile_subscription(subscription_id(invoice), event_id)

        payment ->
          process_paid_invoice(event_id, invoice, payment)
      end
    end
  end

  defp do_process(%{
         "id" => event_id,
         "type" => "checkout.session.completed",
         "created" => created,
         "data" => %{"object" => session}
       }) do
    process_checkout_payment(event_id, session, from_unix!(created))
  end

  defp do_process(%{
         "id" => event_id,
         "type" => "checkout.session.async_payment_succeeded",
         "created" => created,
         "data" => %{"object" => session}
       }) do
    process_checkout_payment(
      event_id,
      Map.put(session, "payment_status", "paid"),
      from_unix!(created)
    )
  end

  defp do_process(%{
         "id" => event_id,
         "type" => "charge.refunded",
         "data" => %{"object" => charge}
       }) do
    BillingCommerce.PaymentRights.apply(required_payment_intent(charge), event_id, fn ->
      with {:ok, config} <- stripe_config(),
           {:ok, current} <-
             config.api.retrieve_charge(required(charge, "id"), %{},
               api_key: config.secret_key,
               response_as: :map
             ) do
        {:ok,
         %{
           type: :refund,
           amount: current["amount_refunded"],
           full: current["amount_refunded"] == current["amount"]
         }}
      end
    end)
  end

  defp do_process(%{"id" => event_id, "type" => type, "data" => %{"object" => dispute}})
       when type in ["charge.dispute.created", "charge.dispute.updated", "charge.dispute.closed"] do
    with {:ok, charge} <- BillingStripe.Ownership.charge(dispute),
         pi <- dispute["payment_intent"] || required_payment_intent(charge) do
      BillingCommerce.PaymentRights.apply(payment_intent_id(pi), event_id, fn ->
        with {:ok, config} <- stripe_config(),
             {:ok, current} <-
               config.api.retrieve_dispute(required(dispute, "id"), %{},
                 api_key: config.secret_key,
                 response_as: :map
               ) do
          {:ok, %{type: :dispute, id: current["id"], status: current["status"]}}
        end
      end)
    end
  end

  defp do_process(%{
         "id" => event_id,
         "type" => "invoice.payment_failed",
         "data" => %{"object" => invoice}
       }) do
    reconcile_subscription(subscription_id(invoice), event_id, %{
      "stripe_invoice_id" => required(invoice, "id")
    })
  end

  defp do_process(%{"id" => event_id, "type" => type, "data" => %{"object" => subscription}})
       when type in [
              "customer.subscription.created",
              "customer.subscription.updated",
              "customer.subscription.deleted",
              "customer.subscription.paused",
              "customer.subscription.resumed",
              "customer.subscription.pending_update_applied",
              "customer.subscription.pending_update_expired"
            ] do
    reconcile_subscription(required(subscription, "id"), event_id)
  end

  defp do_process(%{
         "id" => event_id,
         "type" => "subscription_schedule." <> _,
         "data" => %{"object" => schedule}
       }) do
    id =
      schedule["subscription"] || schedule["released_subscription"] ||
        get_in(schedule, ["metadata", "comma_subscription_id"])

    if is_binary(id),
      do: reconcile_subscription(id, event_id),
      else: {:error, :stripe_schedule_subscription_missing}
  end

  defp do_process(_event), do: {:ok, %{ignored: true}}

  defp process_paid_invoice(event_id, invoice, payment) do
    with {:ok, line, plan} <- BillingStripe.Payments.subscription_line(invoice),
         metadata <-
           Map.merge(billing_metadata(invoice), %{
             "package_code" => plan.package_code,
             "package_version" => plan.package_version
           }),
         period <- period_from(Map.put(invoice, "lines", %{"data" => [line]})),
         {:ok, package} <-
           PackageCatalog.get_package_version(%{
             package_code: plan.package_code,
             version: plan.package_version
           }),
         {:ok, prior_tier} <- BillingStripe.Payments.prior_tier(invoice),
         {:ok, prior_invoice} <- BillingStripe.Payments.prior_invoice(invoice),
         periods <- paid_periods(invoice, period, package.billing_period, prior_tier),
         :ok <- sync_provider_customer(metadata, invoice),
         subscription_id <- subscription_id(invoice),
         {:ok, result} <-
           Subscriptions.create_subscription(
             subscription_attrs(metadata, %{
               source_type: "stripe_subscription",
               subscription_checkout_key: metadata["subscription_checkout_key"],
               source_id: subscription_id,
               source_event_id: required(invoice, "id"),
               idempotency_key: "stripe:subscription:#{subscription_id}",
               source_metadata: %{"stripe_invoice_id" => required(invoice, "id")},
               periods: periods
             })
           ),
         {:ok, issued} <-
           BillingCommerce.PaidCycles.record_invoice(
             result.subscription,
             package,
             required(invoice, "id"),
             payment
             |> Map.merge(period)
             |> Map.put(:prior_tier, prior_tier)
             |> Map.put(:prior_invoice, prior_invoice),
             payment.paid_at
           ),
         {:ok, _} <- reconcile_subscription(subscription_id, event_id) do
      {:ok, issued}
    end
  end

  # Stripe does not order deliveries. Read the authoritative current object
  # after taking the PG subscription lock, including on invoice delivery.
  # This is one provider read per recorded subscription/event, never a scan.
  # TLA: tla/billing/SubscriptionReconcile.tla.
  defp reconcile_subscription(source_id, event_id, source_metadata \\ %{}) do
    Subscriptions.reconcile_provider_subscription(source_id, fn ->
      with {:ok, config} <- stripe_config(),
           {:ok, subscription} <-
             config.api.retrieve_subscription(source_id, %{expand: ["schedule"]},
               api_key: config.secret_key,
               response_as: :map
             ),
           {:ok, subscription} <-
             BillingStripe.SubscriptionChanges.reconcile(source_id, subscription) do
        {:ok,
         Map.merge(
           %{
             source_event_id: event_id,
             status: provider_subscription_status(subscription),
             source_metadata:
               Map.merge(source_metadata, %{
                 "cancel_at_period_end" =>
                   subscription["cancel_at_period_end"] == true or
                     get_in(subscription, ["schedule", "end_behavior"]) == "cancel",
                 "scheduled_plan" => scheduled_plan(subscription),
                 "current_period_end" =>
                   subscription["current_period_end"] ||
                     get_in(subscription, ["items", "data", Access.at(0), "current_period_end"]),
                 "provider_price_id" => provider_price_id(subscription),
                 "provider_status" => subscription["status"]
               })
           },
           provider_plan_attrs(subscription, billing_metadata(subscription))
         )}
      end
    end)
  end

  defp process_checkout_payment(event_id, session, paid_at) do
    metadata = billing_metadata(session)

    case {session["mode"], session["payment_status"]} do
      {"payment", "paid"} ->
        payment_intent_id = payment_intent_id(session["payment_intent"])

        with {:ok, payment} <- BillingStripe.Payments.intent(payment_intent_id),
             period <- paid_month(paid_at),
             :ok <- sync_provider_customer(metadata, session) do
          with {:ok, result} <-
                 Subscriptions.issue_one_time_purchase(
                   subscription_attrs(metadata, %{
                     source_type: "stripe_checkout",
                     source_id: required(session, "id"),
                     source_event_id: event_id,
                     idempotency_key: "stripe:checkout:#{required(session, "id")}",
                     source_metadata: %{
                       "stripe_checkout_session_id" => required(session, "id"),
                       "stripe_payment_intent_id" => payment_intent_id,
                       "payment_status" => "paid"
                     },
                     metadata: %{"stripe_payment_intent_id" => payment_intent_id},
                     provider_payment_intent_id: payment_intent_id,
                     valid_from: period.valid_from,
                     expires_at: period.expires_at
                   })
                 ),
               :ok <- BillingStripe.Payments.compensate_initial(payment, event_id) do
            {:ok, result}
          end
        end

      {"payment", _pending_or_missing} ->
        {:ok, %{ignored: true, reason: :payment_not_complete}}

      _ ->
        {:ok, %{ignored: true, reason: :not_one_time_payment}}
    end
  end

  defp paid_month(at) do
    start = Date.new!(at.year, at.month, 1)
    next = Date.shift(start, month: 1)
    %{valid_from: at, expires_at: DateTime.new!(next, ~T[00:00:00], "Etc/UTC")}
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
    |> Enum.with_index()
    |> Enum.map(fn {[valid_from, expires_at], offset} ->
      %{
        cycle_key: cycle_key(valid_from),
        valid_from: valid_from,
        expires_at: expires_at,
        source_event_id: cycle_key(valid_from),
        source_metadata: %{
          "nominal_end" => DateTime.to_iso8601(DateTime.shift(start_at, month: offset + 1))
        }
      }
    end)
  end

  defp paid_periods(invoice, period, _billing_period, prior_tier) when is_integer(prior_tier) do
    # A paid upgrade allocates within existing paid cycles. Rebuilding from a
    # proration date shifts monthly anchors and can duplicate annual cycles.
    repo = Application.fetch_env!(:billing_stripe, :repo)

    rows =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT c.cycle_key, c.period_start, c.period_end
        FROM billing_subscription_cycles c
        JOIN billing_subscriptions s ON s.id = c.subscription_id
        WHERE s.source_type = 'stripe_subscription' AND s.source_id = $1
          AND c.period_start < $3 AND c.period_end > $2
        ORDER BY c.period_start LIMIT 13
        """,
        [subscription_id(invoice), period.valid_from, period.expires_at]
      ).rows

    if rows == [] or length(rows) > 12, do: repo.rollback(:stripe_paid_cycle_missing)

    Enum.map(rows, fn [key, starts, ends] ->
      %{
        cycle_key: key,
        valid_from: starts,
        expires_at: ends,
        source_event_id: required(invoice, "id")
      }
    end)
  end

  defp paid_periods(invoice, period, billing_period, nil) do
    # Clover invoice lines contain a price id under pricing.price_details,
    # not an expanded recurring Price. Cadence is already owned by our catalog.
    if billing_period == "year" do
      monthly_periods(period.valid_from, period.expires_at)
      |> Enum.map(&Map.put(&1, :source_event_id, required(invoice, "id")))
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

  defp scheduled_plan(subscription) do
    schedule = subscription["schedule"]

    if is_map(schedule) and schedule["end_behavior"] != "cancel" do
      current_start = get_in(schedule, ["current_phase", "start_date"])
      next_phase = Enum.find(schedule["phases"] || [], &(&1["start_date"] > current_start))

      if next_phase do
        price = get_in(next_phase, ["items", Access.at(0), "price"])
        id = if is_map(price), do: price["id"], else: price

        case BillingCommerce.get_provider_plan(%{
               surface: "comma",
               provider: "stripe",
               provider_price_id: id
             }) do
          {:ok, plan} ->
            %{
              package_code: plan.package_code,
              package_version: plan.package_version,
              effective_at: next_phase["start_date"]
            }

          _ ->
            nil
        end
      end
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
