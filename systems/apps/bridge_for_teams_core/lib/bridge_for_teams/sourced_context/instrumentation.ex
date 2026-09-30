defmodule BridgeForTeams.SourcedContext.Instrumentation do
  @moduledoc "Bounded, content-free audit and telemetry helpers for sourced context."

  require Logger

  alias BridgeForTeams.{Observability, Telemetry}

  @spec measure(atom(), (-> result)) :: result when result: var
  def measure(operation, fun) when is_atom(operation) and is_function(fun, 0) do
    started_at = System.monotonic_time()

    try do
      result = fun.()
      Telemetry.emit_operation(operation, outcome(result), System.monotonic_time() - started_at)
      result
    rescue
      error ->
        Telemetry.emit_operation(operation, "error", System.monotonic_time() - started_at)
        reraise(error, __STACKTRACE__)
    catch
      kind, reason ->
        Telemetry.emit_operation(operation, "error", System.monotonic_time() - started_at)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @spec record_audit(String.t(), map(), Ecto.UUID.t() | nil, String.t(), map()) :: :ok
  def record_audit(action, scope, actor_user_id, correlation_id, metadata \\ %{}) do
    attrs = %{
      org_id: value(scope, :org_id),
      project_id: value(scope, :project_id),
      actor_user_id: actor_user_id,
      actor_label: actor_user_id,
      action: action,
      resource_type: value(scope, :resource_type, "sourced_context"),
      resource_id: value(scope, :resource_id),
      resource_label: value(scope, :resource_label, "Sourced context"),
      result: "ok",
      request_id: correlation_id,
      metadata: content_free_metadata(metadata)
    }

    case Observability.record_audit(attrs) do
      {:ok, _audit} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "sourced_context_audit_failed action=#{action} reason_class=#{audit_error_class(reason)}"
        )

        :ok
    end
  end

  defp outcome({:ok, _result}), do: "ok"
  defp outcome(:none), do: "ok"

  defp outcome({:error, reason}) do
    text = inspect(reason)

    cond do
      String.contains?(text, "timeout") -> "timeout"
      String.contains?(text, "unavailable") -> "unavailable"
      String.contains?(text, "conflict") or String.contains?(text, "stale") -> "conflict"
      String.contains?(text, "forbidden") or String.contains?(text, "invalid") -> "rejected"
      true -> "error"
    end
  end

  defp outcome(_result), do: "other"

  defp content_free_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      if is_binary(key) and byte_size(key) <= 64 and safe_metadata_value?(value) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp content_free_metadata(_metadata), do: %{}

  defp safe_metadata_value?(value)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: true

  defp safe_metadata_value?(values) when is_list(values) and length(values) <= 100,
    do: Enum.all?(values, &safe_metadata_value?/1)

  defp safe_metadata_value?(_value), do: false

  defp audit_error_class(%Ecto.Changeset{}), do: "changeset"
  defp audit_error_class(_reason), do: "other"

  defp value(map, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end
end
