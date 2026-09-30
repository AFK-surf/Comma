defmodule BillingStripe.Payments do
  @moduledoc "Resolve actual Stripe payments and the billed Comma subscription line."

  def invoice_payment(invoice) do
    if invoice["paid_out_of_band"] == true or (invoice["amount_paid"] || 0) <= 0 do
      {:ok, :not_stripe_payment}
    else
      with {:ok, current} <- read_invoice(invoice),
           {:ok, id} <- invoice_intent(current),
           {:ok, payment} <- intent(id),
           true <- payment.amount >= invoice["amount_paid"],
           paid_at when is_integer(paid_at) <- get_in(invoice, ["status_transitions", "paid_at"]) do
        {:ok, Map.put(payment, :paid_at, DateTime.from_unix!(paid_at))}
      else
        false -> {:error, :stripe_invoice_payment_amount_mismatch}
        {:error, _} = error -> error
        _ -> {:error, :stripe_invoice_payment_time_missing}
      end
    end
  end

  def intent(id) when is_binary(id) do
    with {:ok, value} <- api().retrieve_payment_intent(id, %{expand: ["latest_charge"]}, opts()),
         "succeeded" <- value["status"],
         amount when is_integer(amount) and amount > 0 <- value["amount_received"],
         %{"paid" => true, "created" => timestamp} = charge <- value["latest_charge"],
         {:ok, disputes} <- disputes(charge, id) do
      {:ok,
       %{
         payment_intent_id: id,
         amount: amount,
         paid_at: DateTime.from_unix!(timestamp),
         metadata: value["metadata"] || %{},
         refunded_amount: charge["amount_refunded"] || 0,
         fully_refunded: charge["refunded"] == true,
         disputes: disputes
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :stripe_payment_not_confirmed}
    end
  end

  def intent(_), do: {:error, :stripe_payment_intent_missing}

  defp disputes(%{"disputed" => true}, id) do
    with {:ok, page} <- api().list_disputes(%{payment_intent: id, limit: 100}, opts()) do
      if page["has_more"],
        do: {:error, :stripe_payment_disputes_incomplete},
        else: {:ok, Map.new(page["data"] || [], &{&1["id"], &1["status"]})}
    end
  end

  defp disputes(_, _), do: {:ok, %{}}

  def compensate_initial(payment, event_id) do
    actions =
      if(payment.refunded_amount > 0,
        do: [%{type: :refund, full: payment.fully_refunded, amount: payment.refunded_amount}],
        else: []
      ) ++
        Enum.map(payment.disputes, fn {id, status} ->
          %{type: :dispute, id: id, status: status}
        end)

    Enum.reduce_while(actions, :ok, fn action, :ok ->
      case BillingCommerce.PaymentRights.apply(payment.payment_intent_id, event_id, fn ->
             {:ok, action}
           end) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def subscription_line(invoice) do
    if get_in(invoice, ["lines", "has_more"]) do
      {:error, :stripe_invoice_lines_incomplete}
    else
      lines = get_in(invoice, ["lines", "data"]) || []

      candidates =
        Enum.flat_map(lines, fn line ->
          price = price_id(line)

          if (line["amount"] || 0) > 0 and is_binary(price) do
            case BillingCommerce.get_provider_plan(%{
                   surface: "comma",
                   provider: "stripe",
                   provider_price_id: price
                 }) do
              {:ok, %{kind: "subscription"} = plan} -> [{line, plan}]
              _ -> []
            end
          else
            []
          end
        end)

      case Enum.uniq_by(candidates, fn {_line, plan} -> plan.provider_price_id end) do
        [{line, plan}] -> {:ok, line, plan}
        [] -> {:error, :stripe_paid_subscription_line_missing}
        _ -> {:error, :stripe_paid_subscription_line_ambiguous}
      end
    end
  end

  def prior_tier(invoice) do
    prior =
      for line <- get_in(invoice, ["lines", "data"]) || [],
          (line["amount"] || 0) < 0,
          {:ok, plan} <- [
            BillingCommerce.get_provider_plan(%{
              surface: "comma",
              provider: "stripe",
              provider_price_id: price_id(line)
            })
          ],
          plan.kind == "subscription",
          do: plan.grant_credits

    case Enum.uniq(prior) do
      [] -> {:ok, nil}
      [credits] -> {:ok, credits}
      _ -> {:error, :stripe_prior_subscription_line_ambiguous}
    end
  end

  def prior_invoice(invoice) do
    for line <- get_in(invoice, ["lines", "data"]) || [], (line["amount"] || 0) < 0 do
      get_in(line, [
        "parent",
        "subscription_item_details",
        "proration_details",
        "credited_items",
        "invoice"
      ]) ||
        get_in(line, ["proration_details", "credited_items", "invoice"])
    end
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> {:ok, nil}
      [id] -> {:ok, id}
      _ -> {:error, :stripe_prior_payment_ambiguous}
    end
  end

  defp read_invoice(%{"payment_intent" => id} = invoice) when not is_nil(id), do: {:ok, invoice}
  defp read_invoice(%{"payments" => _} = invoice), do: {:ok, invoice}

  defp read_invoice(invoice),
    do: api().retrieve_invoice(invoice["id"], %{expand: ["payments"]}, opts())

  defp invoice_intent(%{"payment_intent" => id}) when is_binary(id), do: {:ok, id}
  defp invoice_intent(%{"payment_intent" => %{"id" => id}}), do: {:ok, id}

  defp invoice_intent(invoice) do
    if get_in(invoice, ["payments", "has_more"]) do
      {:error, :stripe_invoice_payments_incomplete}
    else
      ids =
        for payment <- get_in(invoice, ["payments", "data"]) || [],
            payment["status"] == "paid",
            get_in(payment, ["payment", "type"]) == "payment_intent",
            do: get_in(payment, ["payment", "payment_intent"])

      case ids do
        [id] when is_binary(id) -> {:ok, id}
        [%{"id" => id}] -> {:ok, id}
        _ -> {:error, :stripe_invoice_payment_missing}
      end
    end
  end

  defp price_id(line),
    do:
      get_in(line, ["pricing", "price_details", "price"]) ||
        get_in(line, ["price", "id"]) || if(is_binary(line["price"]), do: line["price"])

  defp api, do: Application.get_env(:billing_stripe, :stripe_api, BillingStripe.StripityAPI)

  defp opts,
    do: [api_key: Application.fetch_env!(:billing_stripe, :secret_key), response_as: :map]
end
