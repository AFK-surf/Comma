defmodule AlertRouter.Telemetry do
  @moduledoc "Finite-cardinality telemetry for Alert Router ingress and provider calls."

  import Telemetry.Metrics

  @buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
  # Progress ingress outcome and latency show whether thread reports reach the card owner.
  @operations ~w(ingest progress runtime_log root_post root_update timeline_post root_reconcile timeline_reconcile permalink)
  @providers ~w(gcp_monitoring salix_runtime grafana posthog slack other)
  @outcomes ~w(ok accepted duplicate stale ignored rejected unavailable conflict rate_limited retryable ambiguous incomplete negative other)

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    options = [
      event_name: [:alert_router, :operation, :stop],
      tags: [:operation, :provider, :outcome],
      tag_values: &operation_tags/1
    ]

    [
      counter("alert.router.operations.total", options),
      distribution(
        "alert.router.operations.duration.seconds",
        options ++
          [
            measurement: :duration,
            unit: {:native, :second},
            reporter_options: [buckets: @buckets]
          ]
      )
    ]
  end

  @spec observe(atom(), atom() | String.t(), (-> result)) :: result when result: term()
  def observe(operation, provider, fun) when is_function(fun, 0) do
    started_at = System.monotonic_time()

    try do
      result = fun.()
      emit(operation, provider, outcome(result), System.monotonic_time() - started_at)
      result
    rescue
      exception ->
        emit(operation, provider, :other, System.monotonic_time() - started_at)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        emit(operation, provider, :other, System.monotonic_time() - started_at)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @spec emit(atom(), atom() | String.t(), atom() | String.t(), integer()) :: :ok
  def emit(operation, provider, outcome, duration) when is_integer(duration) do
    :telemetry.execute(
      [:alert_router, :operation, :stop],
      %{duration: duration},
      %{operation: operation, provider: provider, outcome: outcome}
    )
  end

  defp operation_tags(metadata) do
    %{
      operation: finite(metadata[:operation], @operations),
      provider: finite(metadata[:provider], @providers),
      outcome: finite(metadata[:outcome], @outcomes)
    }
  end

  defp outcome({:ok, %{complete?: false}}), do: "incomplete"
  defp outcome({:ok, %{complete?: true, matches: []}}), do: "negative"
  defp outcome({:ok, %{complete?: true, matches: [_match]}}), do: "ok"
  defp outcome({:ok, %{complete?: true, matches: _matches}}), do: "conflict"
  defp outcome({:ok, %{disposition: disposition}}), do: disposition

  defp outcome({:ok, disposition}) when disposition in [:accepted, :stale, :ignored],
    do: disposition

  defp outcome({:ok, disposition}) when disposition in [:stale_card, :already_owned, :not_owner],
    do: "conflict"

  defp outcome({:ok, _value}), do: "ok"
  defp outcome({:error, {:rate_limited, _seconds}}), do: "rate_limited"
  defp outcome({:error, {:retryable, _reason}}), do: "retryable"
  defp outcome({:error, {:ambiguous, _reason}}), do: "ambiguous"
  defp outcome({:error, {:permanent, _reason}}), do: "rejected"
  defp outcome({:error, :router_disabled}), do: "unavailable"
  defp outcome({:error, {:route_not_configured, _route}}), do: "unavailable"
  defp outcome({:error, {:route_change_requires_drain, _current, _incoming}}), do: "conflict"
  defp outcome({:error, {:event_contract_conflict, _event_id}}), do: "conflict"
  defp outcome({:error, _reason}), do: "rejected"
  defp outcome(_result), do: "other"

  defp finite(value, allowed) when is_atom(value), do: finite(Atom.to_string(value), allowed)

  defp finite(value, allowed) when is_binary(value),
    do: if(value in allowed, do: value, else: "other")

  defp finite(_value, _allowed), do: "other"
end
