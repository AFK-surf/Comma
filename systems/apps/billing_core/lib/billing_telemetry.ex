defmodule BillingTelemetry do
  @moduledoc "Shared Billing-owned telemetry metrics and bounded emitters."
  import Telemetry.Metrics

  @buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
  @outcomes ~w(ok error timeout unavailable conflict rejected cancelled other)
  @operation_providers %{
    charge: "other",
    fee_control: "other",
    pending_charge: "other",
    cycle: "other",
    stripe_checkout: "stripe",
    stripe_customer: "stripe",
    stripe_portal: "stripe",
    stripe_catalog_sync: "stripe",
    stripe_webhook: "stripe",
    billable_insert: "clickhouse",
    other: "other"
  }
  @operations @operation_providers |> Map.keys() |> Enum.map(&Atom.to_string/1)
  @providers @operation_providers |> Map.values() |> Enum.uniq() |> Kernel.++(["other"])

  def metrics do
    operation_options = [
      event_name: [:billing, :operation, :stop],
      tags: [:surface, :operation, :provider, :outcome],
      tag_values: &operation_tags/1
    ]

    [
      counter("billing.operations.total", operation_options),
      distribution(
        "billing.operations.duration.seconds",
        operation_options ++
          [
            measurement: :duration,
            unit: {:native, :second},
            reporter_options: [buckets: @buckets]
          ]
      ),
      counter("billing.stripe.rate.limits.total",
        event_name: [:billing, :stripe, :rate_limit],
        tags: [:surface],
        tag_values: &surface_tags/1
      )
    ]
  end

  def emit_operation(operation, surface, outcome, duration, metadata \\ %{}) do
    :telemetry.execute(
      [:billing, :operation, :stop],
      %{duration: duration},
      Map.merge(metadata, %{
        surface: normalize_surface(surface),
        operation: operation,
        provider: Map.get(@operation_providers, operation, "other"),
        outcome: outcome
      })
    )
  end

  defp normalize_surface(value) when value in [:bridge, "bridge", :bft, "bft"], do: "bft"
  defp normalize_surface(value) when value in [:comma, "comma"], do: "comma"
  defp normalize_surface(value) when value in [:salix, "salix"], do: "salix"
  defp normalize_surface(value) when value in [:system, "system"], do: "system"
  defp normalize_surface(_value), do: "other"

  defp operation_tags(metadata) do
    %{
      surface: normalize_surface(metadata[:surface]),
      operation: finite(metadata[:operation], @operations),
      provider: finite(metadata[:provider], @providers),
      outcome: finite(metadata[:outcome], @outcomes)
    }
  end

  defp surface_tags(metadata), do: %{surface: normalize_surface(metadata[:surface])}

  defp finite(value, allowed) when is_atom(value), do: finite(Atom.to_string(value), allowed)

  defp finite(value, allowed) when is_binary(value),
    do: if(value in allowed, do: value, else: "other")

  defp finite(_value, _allowed), do: "other"
end
