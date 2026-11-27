defmodule BridgeForTeams.CftAnalytics do
  @moduledoc """
  Comma for Teams paid-signup funnel events, sent to the product analytics
  PostHog project through `ProductAnalytics`.

  A buyer has no account before payment, so every event of one purchase is
  attributed to its `purchase_id` (the session's Teams purchase, which becomes
  the Organization id when payment converges). The funnel, in order:

    * `cft_signup_opened`: the seat form opened a new purchase (crawlers
      excluded), with its `entry` (the website page that linked to it, else
      `direct`), `country` and `locale`.
    * `cft_checkout_created`: a submission answered by a provider checkout,
      once per checkout (a reused session or order repeats its event).
    * `cft_checkout_failed`: a submission refused with a bounded
      `failure_kind`, once per purchase and kind a day.
    * `cft_payment_returned`: the buyer came back from the provider (`state`).
    * `cft_checkout_completed`: the first payment of a signup converged and its
      Organization exists. Renewals are outside this funnel.

  An abandoned checkout is a created one without a completion within the
  provider window (24 hours for Stripe, 1 hour for a local M2square order).
  Events carry the provider, seat count and whether the signup email is an
  internal one, never an email, name, amount, payer field or provider id.
  A request with DNT records nothing, and a checkout requested with DNT also
  hides its completion; a reused Stripe session or open M2square order keeps
  its first request's choice. Observation never changes a checkout or payment result.
  Events are no persons in PostHog. The queue is volatile: a completion whose
  node stops before export is lost, as the converged checkout is gone.
  """

  alias ProductAnalytics.Queue

  @queue BridgeForTeams.CftAnalytics.Queue
  @events ~w(cft_signup_opened cft_checkout_created cft_checkout_failed cft_payment_returned cft_checkout_completed)
  @entries ~w(pricing enterprise personal dashboard direct)
  @providers ~w(stripe m2square)
  @failure_kinds ~w(quote_expired quote_unavailable seats_invalid details_invalid payer_invalid
                    amount_out_of_bounds local_unavailable checkout_pending checkout_expired
                    already_subscribed payment_uncertain signin_unavailable provider_unavailable
                    provider_error other)

  def config, do: SystemsRuntime.get_env(:bridge_for_teams_core, :cft_analytics, [])

  def configured? do
    config = config()

    is_binary(config[:api_key]) and config[:api_key] != "" and is_binary(config[:host]) and
      config[:host] != ""
  end

  @doc "The export queue when an analytics project is configured."
  def children(opts \\ []) do
    if configured?(),
      do: [
        Queue.child_spec(
          Keyword.merge(
            [
              name: @queue,
              export: &export/1,
              telemetry: [:bridge_for_teams, :cft_analytics, :export]
            ],
            opts
          )
        )
      ],
      else: []
  end

  @doc "The website page a `from` parameter names, else `direct`."
  def entry(from) when from in @entries, do: from
  def entry(_from), do: "direct"

  @doc "Whether a signup email belongs to a configured internal domain (one domain or a list)."
  def internal_email?(email) when is_binary(email) do
    domain = email |> String.downcase() |> String.split("@") |> List.last()

    config()
    |> Keyword.get(:internal_email_domains, ~w(cue.surf comma.surf))
    |> List.wrap()
    |> Enum.any?(&(is_binary(&1) and String.downcase(String.trim(&1)) == domain))
  rescue
    _ -> false
  end

  def internal_email?(_email), do: false

  @doc """
  Runs `fun`, which builds and captures funnel events. Building an event's
  properties happens outside `capture/5`, so this boundary keeps any failure
  there from changing a checkout or payment answer.
  """
  def observe(fun) do
    fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Admits one funnel event of `purchase_id`. `source_id` names the source fact
  and, with the event and purchase, makes the event's deduplication key;
  `occurred_at` must be that fact's own time, so a retry repeats the event.
  """
  def capture(purchase_id, event, source_id, properties, occurred_at \\ SystemsClock.utc_now()) do
    if configured?() and event in @events and uuid?(purchase_id) and is_binary(source_id) and
         source_id != "" do
      Queue.enqueue(@queue, %{
        purchase_id: purchase_id,
        event: event,
        source_id: source_id,
        properties: allowed_properties(properties),
        occurred_at: occurred_at
      })
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "The bounded `failure_kind` of a checkout start error."
  def failure_kind(reason) do
    case reason do
      r when r in [:quote_expired, :invalid_quote_token] ->
        "quote_expired"

      :quote_signing_unconfigured ->
        "quote_unavailable"

      {r, _} when r in [:invalid_seats_min] ->
        "seats_invalid"

      {:invalid_seats_range, _, _} ->
        "seats_invalid"

      :invalid_seats ->
        "seats_invalid"

      :invalid_teams_signup ->
        "details_invalid"

      {:payer_invalid, _} ->
        "payer_invalid"

      :amount_out_of_bounds ->
        "amount_out_of_bounds"

      r when r in [:m2square_country_unavailable, :unsupported_country, :fx_rate_unavailable] ->
        "local_unavailable"

      :subscription_checkout_pending ->
        "checkout_pending"

      :subscription_checkout_expired ->
        "checkout_expired"

      r when r in [:subscription_already_exists, :subscription_active_elsewhere] ->
        "already_subscribed"

      :m2square_pay_uncertain ->
        "payment_uncertain"

      :teams_signin_unavailable ->
        "signin_unavailable"

      r when r in [:stripe_not_configured, :m2square_unavailable, :teams_price_not_configured] ->
        "provider_unavailable"

      :m2square_pay_rejected ->
        "provider_error"

      %{__struct__: Stripe.Error, source: :network} ->
        "provider_unavailable"

      %{__struct__: Stripe.Error} ->
        "provider_error"

      _ ->
        "other"
    end
  end

  @doc false
  def export([]), do: :ok

  def export(entries) do
    config = config()

    events =
      Enum.map(entries, fn entry ->
        %{
          event: entry.event,
          distinct_id: entry.purchase_id,
          uuid:
            ProductAnalytics.event_uuid(
              {"cft.analytics.v1", entry.event, entry.purchase_id, entry.source_id}
            ),
          timestamp: DateTime.to_iso8601(entry.occurred_at),
          properties:
            Map.merge(entry.properties, %{
              "producer" => "cft_server",
              "environment" => config[:environment],
              "schema_version" => 1,
              "$geoip_disable" => true,
              # A purchase is no person: anonymous visits must not create one each.
              "$process_person_profile" => false
            })
        }
      end)

    if configured?(),
      do:
        ProductAnalytics.PostHog.send_batch(
          events,
          config[:api_key],
          config[:host],
          [:bridge_for_teams, :cft_analytics, :batch]
        ),
      else: {:error, :rejected}
  end

  defp allowed_properties(properties) do
    properties
    |> Enum.filter(fn {key, value} -> valid_property?(key, value) end)
    |> Map.new()
  end

  defp valid_property?("entry", value), do: value in @entries
  defp valid_property?("provider", value), do: value in @providers
  defp valid_property?("failure_kind", value), do: value in @failure_kinds
  defp valid_property?("state", value), do: value in ~w(success cancel)
  defp valid_property?("is_internal", value), do: is_boolean(value)
  defp valid_property?("seats", value), do: is_integer(value) and value in 1..100_000

  defp valid_property?("locale", value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z]{2}(_[A-Za-z]{2,4})?\z/, value)

  defp valid_property?("country", value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Z]{2}\z/, value)

  defp valid_property?(_key, _value), do: false

  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value || ""))
end
