defmodule BillingStripe.Ownership do
  @moduledoc "Resolve shared-account Stripe event ownership from local mappings and provider catalog keys."

  def resolve(event) do
    object = get_in(event, ["data", "object"]) || %{}
    metadata = BillingStripe.Events.billing_metadata(object)
    local = local_surfaces(object, event["type"])
    surfaces = Enum.uniq(local ++ Enum.reject([metadata["surface"]], &is_nil/1))

    cond do
      "comma" in surfaces and Enum.any?(surfaces, &(&1 != "comma")) ->
        {:error, :stripe_event_owner_conflict}

      surfaces == ["comma"] ->
        {:ok, :comma}

      surfaces != [] ->
        {:ok, :foreign}

      true ->
        provider_owner(event["type"], object)
    end
  end

  defp local_surfaces(object, type) do
    repo = Application.fetch_env!(:billing_stripe, :repo)
    customer = id(object["customer"])
    pi = id(object["payment_intent"])

    subscription =
      id(object["subscription"]) ||
        get_in(object, ["parent", "subscription_details", "subscription"])

    subscription =
      if String.starts_with?(type, "customer.subscription."), do: object["id"], else: subscription

    prices = price_ids(object)

    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT surface FROM billing_provider_customers WHERE provider = 'stripe' AND provider_customer_id = $1
      UNION SELECT surface FROM billing_subscriptions WHERE source_type = 'stripe_subscription' AND source_id = $2
      UNION SELECT surface FROM billing_one_time_purchases WHERE provider_payment_intent_id = $3
      UNION SELECT p.surface FROM billing_provider_prices pp JOIN billing_packages p ON p.code = pp.package_code
        WHERE pp.provider = 'stripe' AND pp.provider_price_id = ANY($4::text[])
      UNION SELECT ba.surface FROM credit_grants g JOIN billing_accounts ba ON ba.id = g.billing_account_id
        WHERE g.metadata->>'stripe_payment_intent_id' = $3
      """,
      [customer, subscription, pi, prices]
    ).rows
    |> List.flatten()
  end

  defp provider_owner(type, object)
       when type in [
              "charge.refunded",
              "charge.dispute.created",
              "charge.dispute.updated",
              "charge.dispute.closed"
            ] do
    with {:ok, charge} <- charge(object),
         pi when is_binary(pi) <- id(charge["payment_intent"]),
         {:ok, intent} <- api().retrieve_payment_intent(pi, %{expand: ["latest_charge"]}, opts()) do
      surface = get_in(intent, ["metadata", "surface"])

      cond do
        surface == "comma" -> {:ok, :comma}
        is_binary(surface) -> {:ok, :foreign}
        true -> payment_owner(pi)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :stripe_event_ownership_unknown}
    end
  end

  defp provider_owner("checkout.session." <> _, object) do
    with {:ok, session} <-
           api().retrieve_checkout_session(
             object["id"],
             %{expand: ["line_items.data.price"]},
             opts()
           ) do
      if get_in(session, ["line_items", "has_more"]),
        do: {:error, :stripe_event_catalog_incomplete},
        else: catalog_owner(get_in(session, ["line_items", "data"]) || [])
    end
  end

  defp provider_owner(_type, object), do: object_catalog_owner(object)

  defp object_catalog_owner(object) do
    if get_in(object, ["lines", "has_more"]) == true or
         get_in(object, ["items", "has_more"]) == true,
       do: {:error, :stripe_event_catalog_incomplete},
       else: catalog_owner(lines(object))
  end

  defp payment_owner(pi) do
    with {:ok, page} <-
           api().list_invoice_payments(
             %{payment: %{type: "payment_intent", payment_intent: pi}, limit: 100},
             opts()
           ) do
      cond do
        page["has_more"] ->
          {:error, :stripe_event_payment_links_incomplete}

        length(page["data"] || []) == 1 ->
          invoice_owner(hd(page["data"])["invoice"])

        page["data"] not in [[], nil] ->
          {:error, :stripe_event_payment_links_ambiguous}

        true ->
          with {:ok, sessions} <-
                 api().list_checkout_sessions(%{payment_intent: pi, limit: 100}, opts()) do
            case {sessions["has_more"], sessions["data"] || []} do
              {false, [session]} ->
                case get_in(session, ["metadata", "surface"]) do
                  "comma" -> {:ok, :comma}
                  surface when is_binary(surface) -> {:ok, :foreign}
                  _ -> provider_owner("checkout.session.completed", session)
                end

              _ ->
                {:error, :stripe_event_ownership_unknown}
            end
          end
      end
    end
  end

  defp invoice_owner(value) do
    case id(value) do
      nil ->
        {:error, :stripe_event_ownership_unknown}

      invoice ->
        with {:ok, object} <- api().retrieve_invoice(invoice, %{}, opts()) do
          case BillingStripe.Events.billing_metadata(object)["surface"] do
            "comma" -> {:ok, :comma}
            surface when is_binary(surface) -> {:ok, :foreign}
            _ -> object_catalog_owner(object)
          end
        end
    end
  end

  defp catalog_owner(lines) do
    if length(lines) > 100 do
      {:error, :stripe_event_catalog_incomplete}
    else
      owners =
        Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
          case price_id(line) do
            nil ->
              {:cont, {:ok, acc}}

            price ->
              case api().retrieve_price(price, %{expand: ["product"]}, opts()) do
                {:ok, result} ->
                  surface = get_in(result, ["product", "metadata", "surface"])
                  key = result["lookup_key"]

                  owner =
                    cond do
                      surface == "comma" ->
                        :comma

                      is_binary(surface) ->
                        :foreign

                      is_binary(key) and
                          (String.starts_with?(key, "comma_") or String.starts_with?(key, "cue_")) ->
                        :comma

                      is_binary(key) and key != "" ->
                        :foreign

                      true ->
                        :unknown
                    end

                  {:cont, {:ok, [owner | acc]}}

                {:error, reason} ->
                  {:halt, {:error, reason}}
              end
          end
        end)

      case owners do
        {:ok, [:comma | _] = values} ->
          if Enum.all?(values, &(&1 == :comma)),
            do: {:ok, :comma},
            else: {:error, :stripe_event_owner_conflict}

        {:ok, values} when values != [] ->
          cond do
            Enum.all?(values, &(&1 == :foreign)) -> {:ok, :foreign}
            :comma in values -> {:error, :stripe_event_owner_conflict}
            true -> {:error, :stripe_event_ownership_unknown}
          end

        {:ok, []} ->
          {:error, :stripe_event_ownership_unknown}

        error ->
          error
      end
    end
  end

  def charge(%{"charge" => value}) when is_binary(value),
    do: api().retrieve_charge(value, %{}, opts())

  def charge(%{"charge" => %{} = value}), do: {:ok, value}
  def charge(object), do: {:ok, object}
  defp price_ids(object), do: lines(object) |> Enum.map(&price_id/1) |> Enum.reject(&is_nil/1)

  defp lines(object),
    do: get_in(object, ["lines", "data"]) || get_in(object, ["items", "data"]) || []

  defp price_id(line),
    do: id(line["price"]) || get_in(line, ["pricing", "price_details", "price"])

  defp id(value) when is_binary(value), do: value
  defp id(%{"id" => value}), do: value
  defp id(_), do: nil
  defp api, do: Application.get_env(:billing_stripe, :stripe_api, BillingStripe.StripityAPI)

  defp opts,
    do: [api_key: Application.fetch_env!(:billing_stripe, :secret_key), response_as: :map]
end
