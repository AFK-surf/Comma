defmodule BillingStripe.Telemetry do
  @moduledoc false

  def observe(operation, surface, fun) when is_function(fun, 0) do
    started = System.monotonic_time()

    try do
      result = fun.()
      outcome = outcome(result)

      BillingTelemetry.emit_operation(
        operation,
        surface,
        outcome,
        System.monotonic_time() - started
      )

      maybe_emit_rate_limit(result, surface)
      result
    rescue
      exception ->
        BillingTelemetry.emit_operation(
          operation,
          surface,
          "error",
          System.monotonic_time() - started
        )

        reraise exception, __STACKTRACE__
    end
  end

  def surface(attrs, default \\ "other") when is_map(attrs) do
    attrs[:surface] || attrs["surface"] || default
  end

  defp outcome({:error, %Stripe.Error{code: code}}) when code in [:rate_limit, "rate_limit"],
    do: "rejected"

  defp outcome({:error, %Stripe.Error{source: :network}}), do: "unavailable"
  defp outcome({:error, :stripe_not_configured}), do: "unavailable"
  defp outcome({:error, _reason}), do: "error"
  defp outcome(_result), do: "ok"

  defp maybe_emit_rate_limit({:error, %Stripe.Error{code: code}}, surface)
       when code in [:rate_limit, "rate_limit"] do
    :telemetry.execute(
      [:billing, :stripe, :rate_limit],
      %{},
      %{surface: surface}
    )
  end

  defp maybe_emit_rate_limit(_result, _surface), do: :ok
end
