defmodule SalixAnalytics.BillingSourceEvent do
  @moduledoc """
  Builds typed ClickHouse rows for billing source lifecycle projections.
  """

  alias SalixAnalytics.TypedEvent

  @required ~w(
    source_key
    occurred_at
    surface
    billing_account_id
    product_owner_type
    product_owner_id
    event_kind
    source_type
    source_id
    status
  )a

  def build(attrs) when is_map(attrs) do
    attrs = TypedEvent.atomize(attrs)
    require_fields!(attrs)

    occurred_at = get(attrs, :occurred_at) || get(attrs, :created_at) || DateTime.utc_now()

    %{
      resource_kind: "billing_source",
      source: get(attrs, :source) || "billing_source",
      source_key: get(attrs, :source_key),
      version: get(attrs, :version) || 1,
      event_date: date(occurred_at),
      occurred_at: timestamp(occurred_at),
      created_at: timestamp(get(attrs, :created_at) || DateTime.utc_now()),
      surface: get(attrs, :surface),
      billing_account_id: get(attrs, :billing_account_id),
      product_owner_type: get(attrs, :product_owner_type),
      product_owner_id: get(attrs, :product_owner_id),
      event_kind: get(attrs, :event_kind),
      source_type: get(attrs, :source_type),
      source_id: get(attrs, :source_id),
      source_event_id: get(attrs, :source_event_id),
      idempotency_key: get(attrs, :idempotency_key),
      package_code: get(attrs, :package_code),
      package_version: get(attrs, :package_version),
      credit_grant_id: get(attrs, :credit_grant_id),
      status: get(attrs, :status),
      reason: get(attrs, :reason),
      provider: get(attrs, :provider),
      provider_event_id: get(attrs, :provider_event_id),
      metadata_json: Jason.encode!(get(attrs, :metadata) || %{}),
      trace_id: get(attrs, :trace_id),
      log_correlation_id: get(attrs, :log_correlation_id)
    }
    |> stringify()
  end

  defp require_fields!(attrs) do
    missing =
      Enum.reject(@required, fn key ->
        value = get(attrs, key)
        not is_nil(value) and value != ""
      end)

    if missing != [] do
      raise ArgumentError,
            "missing billing source event fields: #{Enum.join(Enum.map(missing, &to_string/1), ", ")}"
    end
  end

  defp stringify(row) do
    Map.new(row, fn
      {key, %DateTime{} = value} -> {to_string(key), DateTime.to_iso8601(value)}
      {key, %NaiveDateTime{} = value} -> {to_string(key), NaiveDateTime.to_iso8601(value)}
      {key, %Date{} = value} -> {to_string(key), Date.to_iso8601(value)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp date(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()
  defp date(%NaiveDateTime{} = dt), do: dt |> NaiveDateTime.to_date() |> Date.to_iso8601()
  defp date(value) when is_binary(value), do: String.slice(value, 0, 10)
  defp date(_), do: Date.utc_today() |> Date.to_iso8601()

  defp timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp timestamp(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp timestamp(value) when is_binary(value), do: value
  defp timestamp(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp get(attrs, key), do: attrs[key] || attrs[to_string(key)]
end
