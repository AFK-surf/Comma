defmodule SalixAgent.ExternalSessionLifecycleObservation do
  @moduledoc false

  require Logger

  @sources ~w(connector_event server_dispatch_failure)
  @mappings ~w(
    applied
    ignored_dispatch_mismatch
    ignored_execution_mismatch
    ignored_stale_watermark
    ignored_missing_identity
    ignored_invalid_work_state
    ignored_non_terminal
    ignored_projection_target_mismatch
    ignored_execution_already_started
    target_write_failed
    projection_read_failed
    projection_failed
    other
  )
  @work_states ~w(running settled failed none other)
  @statuses ~w(idle starting running waiting failed unknown none other)
  @issues ~w(
    quota_exhausted
    rate_limited
    authentication_required
    model_unavailable
    recovery_exhausted
    runtime_failed
    runtime_status_unknown
    native_start_unconfirmed
    runtime_observation_lost
    none
    other
  )

  @doc false
  def lifecycle(fields, level \\ :info) when is_map(fields) do
    metadata =
      fields
      |> identifiers()
      |> Map.put(:event, "external_session_lifecycle_observation")
      |> Map.put(:source, finite(fields[:source], @sources))
      |> Map.put(:mapping, finite(fields[:mapping], @mappings))
      |> Map.put(:work_state, finite_or_none(fields[:work_state], @work_states))
      |> Map.put(:status, finite_or_none(fields[:status], @statuses))
      |> Map.put(:issue, finite_or_none(fields[:issue], @issues))
      |> maybe_put_boolean(:terminal, fields[:terminal])

    safe_log(level, "external session lifecycle observation", metadata)
  end

  @doc false
  def runtime_failure(reason, fields) when is_map(fields) do
    metadata =
      fields
      |> identifiers()
      |> Map.put(:event, "external_runtime_dispatch_failed")
      |> Map.put(:source, "server_dispatch")
      |> Map.put(:reason_class, reason_class(reason))
      |> maybe_put_boolean(:terminal, fields[:terminal])

    safe_log(:warning, "external runtime dispatch failed", metadata)
  end

  defp identifiers(fields) do
    Map.new(
      ~w(agent_id session_id connector_run_id dispatch_id execution_id record_id)a,
      fn key -> {key, present_identifier(fields[key])} end
    )
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp present_identifier(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      identifier -> identifier
    end
  end

  defp present_identifier(_value), do: nil

  defp finite_or_none(nil, _allowed), do: "none"
  defp finite_or_none("", _allowed), do: "none"
  defp finite_or_none(value, allowed), do: finite(value, allowed)

  defp finite(value, allowed) when is_atom(value), do: finite(Atom.to_string(value), allowed)

  defp finite(value, allowed) when is_binary(value),
    do: if(value in allowed, do: value, else: "other")

  defp finite(_value, _allowed), do: "other"

  defp maybe_put_boolean(metadata, key, value) when is_boolean(value),
    do: Map.put(metadata, key, value)

  defp maybe_put_boolean(metadata, _key, _value), do: metadata

  defp reason_class(reason) when reason in [:timeout, :request_timeout], do: "timeout"

  defp reason_class(reason) when reason in [:disconnected, :closed], do: "disconnected"

  defp reason_class(:invalid_external_runtime_binding), do: "invalid_binding"
  defp reason_class({:invalid_external_runtime_input_response, _}), do: "invalid_response"
  defp reason_class(:unsupported_external_runtime), do: "unsupported"
  defp reason_class(:external_runtime_driver_not_configured), do: "not_configured"
  defp reason_class(_reason), do: "other"

  defp safe_log(level, message, metadata) do
    Logger.log(level, message, Map.to_list(metadata))
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
