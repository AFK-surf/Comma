defmodule BridgeForTeams.Observability.AdapterDiagnostic do
  @moduledoc """
  Helpers for adapter diagnostic sinks that write into BFT Operations.

  Adapter-specific sinks still own tenant/resource resolution and domain
  mapping. This module keeps the shared mechanics allowlist-driven: read
  atom/string diagnostic keys, build bounded evidence maps, and persist events
  without leaking the full diagnostic into logs on failure.
  """
  require Logger

  alias BridgeForTeams.Observability

  @common_correlation_keys [
    :correlation_id,
    :request_id,
    :client_request_id,
    :invocation_id,
    :run_id,
    :external_run_id,
    :provider_event_id,
    :reply_message_id,
    :source_message_id,
    :message_id,
    :message_ts
  ]

  @doc "Fetch a diagnostic key whether the producer used atoms or strings."
  @spec value(map(), atom()) :: term()
  def value(%{} = diagnostic, key) when is_atom(key) do
    if Map.has_key?(diagnostic, key) do
      Map.get(diagnostic, key)
    else
      Map.get(diagnostic, Atom.to_string(key))
    end
  end

  @doc "Return the first nonblank value for the given diagnostic keys."
  @spec first_value(map(), [atom()]) :: term()
  def first_value(%{} = diagnostic, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      diagnostic
      |> value(key)
      |> blank_to_nil()
    end)
  end

  @doc "Return the first common adapter correlation id, with an optional fallback."
  @spec correlation_id(map(), term()) :: term() | nil
  def correlation_id(%{} = diagnostic, fallback \\ nil) do
    first_value(diagnostic, @common_correlation_keys) || blank_to_nil(fallback)
  end

  @doc "Build a string-keyed evidence map from an explicit allowlist."
  @spec take_evidence(map(), [atom()]) :: map()
  def take_evidence(%{} = diagnostic, keys) when is_list(keys) do
    keys
    |> Enum.reduce(%{}, fn key, evidence ->
      case value(diagnostic, key) do
        value when value in [nil, ""] -> evidence
        value -> Map.put(evidence, Atom.to_string(key), value)
      end
    end)
  end

  @doc "Drop nil and blank-string values from a string-keyed evidence map."
  @spec drop_blank_values(map()) :: map()
  def drop_blank_values(%{} = evidence) do
    evidence
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  @doc "Normalize a value intended for required event string fields."
  @spec string_value(term(), String.t()) :: String.t()
  def string_value(value, default) when is_binary(default) do
    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      value when is_atom(value) ->
        Atom.to_string(value)

      _ ->
        default
    end
  end

  @doc "Normalize optional scalar values while preserving nonblank primitives."
  @spec blank_to_nil(term()) :: term() | nil
  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(value) when is_boolean(value), do: value
  def blank_to_nil(value) when is_atom(value), do: Atom.to_string(value)
  def blank_to_nil(value), do: value

  @doc "Persist one Operations event, logging only sanitized failure context."
  @spec persist_event(map(), String.t()) :: :ok
  def persist_event(attrs, label) when is_map(attrs) and is_binary(label) do
    case Observability.create_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to persist #{label}: #{safe_reason(reason)}")
        :ok
    end
  end

  @doc "Run sink code defensively so adapter diagnostics never break callers."
  @spec safe_record(String.t(), (-> :ok)) :: :ok
  def safe_record(label, fun) when is_binary(label) and is_function(fun, 0) do
    fun.()
  rescue
    error ->
      Logger.warning("failed to handle #{label}: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("failed to handle #{label}: #{inspect({kind, safe_reason(reason)})}")
      :ok
  end

  defp safe_reason(%Ecto.Changeset{} = changeset), do: inspect(changeset.errors)
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp safe_reason(reason) do
    inspect(reason, limit: 10, printable_limit: 200)
  end
end
