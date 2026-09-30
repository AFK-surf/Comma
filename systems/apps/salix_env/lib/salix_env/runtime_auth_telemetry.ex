defmodule SalixEnv.RuntimeAuthTelemetry do
  @moduledoc false

  @operations %{
    read: "runtime_auth_read",
    status: "runtime_auth_status",
    verify: "runtime_auth_verify",
    login_start: "runtime_auth_login_start",
    login_cancel: "runtime_auth_login_cancel",
    input_begin: "runtime_auth_input_begin",
    input_submit: "runtime_auth_input_submit",
    input_cancel: "runtime_auth_input_cancel",
    quiet: "runtime_workload_quiet"
  }

  @spec emit(atom(), term(), integer()) :: :ok
  def emit(operation, result, started_at) do
    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: max(System.monotonic_time() - started_at, 0)},
      %{
        component: "salix_env",
        operation: Map.fetch!(@operations, operation),
        surface: SystemsObservability.Context.current_surface(),
        outcome: outcome(result)
      }
    )

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp outcome({:ok, _result}), do: "ok"

  defp outcome({:error, reason}) when reason in [:timeout, :runtime_auth_timeout],
    do: "timeout"

  defp outcome({:error, reason}) when reason in [:unavailable, :connector_disconnected],
    do: "unavailable"

  defp outcome({:error, reason})
       when reason in [
              :not_found,
              :runtime_auth_unsupported,
              :runtime_auth_conflict,
              :runtime_auth_target_changed,
              :invalid_runtime_auth_request,
              :invalid_runtime_auth_flow,
              :invalid_runtime_auth_attempt_id
            ],
       do: "rejected"

  defp outcome(_result), do: "error"
end
