defmodule CommaWeb.TelegramTelemetry do
  @moduledoc "Content-free observation of authenticated Comma Telegram work."

  def observe(operation, fun) when operation in [:telegram_webhook, :telegram_send_message] do
    observe(operation, fun, System.monotonic_time())
  end

  defp observe(operation, fun, started) do
    result = fun.()
    emit(operation, outcome(result), started)
    result
  rescue
    exception ->
      emit(operation, :error, started)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      emit(operation, :error, started)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp outcome(:ok), do: :ok
  defp outcome({:ok, _result}), do: :ok
  defp outcome({:error, {:telegram_http_error, 403}}), do: :rejected
  defp outcome({:error, {:telegram_http_error, 429}}), do: :rate_limited
  defp outcome({:error, :telegram_link_busy}), do: :conflict
  defp outcome({:error, :invalid_telegram_update}), do: :rejected
  defp outcome({:error, :telegram_unavailable}), do: :unavailable
  defp outcome({:error, :timeout}), do: :timeout
  defp outcome(_result), do: :error

  defp emit(operation, outcome, started) do
    CommaProduct.Telemetry.emit_operation(operation, outcome, System.monotonic_time() - started)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
