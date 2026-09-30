defmodule BridgeForTeams.RunChecks.GateContract do
  @moduledoc """
  Canonical Run checks gate normalization and aggregation.

  Run checks are persisted and consumed by several surfaces. This module keeps
  the gate contract scoped to that domain so generic observability payloads do
  not need to reinterpret booleans. Missing `required` and `redacted` fields
  mean `true`; normalized gates always contain JSON booleans for both fields.
  """

  @actionable_statuses ~w(fail needs_manual skipped)

  @spec normalize_result(map()) :: map()
  def normalize_result(%{} = result) do
    result = normalize_value(result)
    Map.update(result, "gates", [], &normalize_gates/1)
  end

  @spec normalize_gates(term()) :: [map()]
  def normalize_gates(gates) when is_list(gates), do: Enum.map(gates, &normalize_gate/1)
  def normalize_gates(_gates), do: []

  @spec normalize_gate(term()) :: map()
  def normalize_gate(%{} = gate) do
    gate = normalize_value(gate)

    gate
    |> Map.put("required", required?(gate))
    |> Map.put("redacted", redacted?(gate))
  end

  def normalize_gate(_gate), do: %{"required" => true, "redacted" => true}

  @spec required?(term()) :: boolean()
  def required?(%{"required" => false}), do: false
  def required?(%{"required" => "false"}), do: false
  def required?(%{required: false}), do: false
  def required?(_gate), do: true

  @spec redacted?(term()) :: boolean()
  def redacted?(%{"redacted" => false}), do: false
  def redacted?(%{"redacted" => "false"}), do: false
  def redacted?(%{redacted: false}), do: false
  def redacted?(_gate), do: true

  @spec aggregate_status(term()) :: String.t()
  def aggregate_status(gates) when is_list(gates) do
    gates = normalize_gates(gates)
    required_gates = Enum.filter(gates, &required?/1)
    statuses = Enum.map(required_gates, &status/1)

    cond do
      "fail" in statuses -> "fail"
      "needs_manual" in statuses -> "needs_manual"
      "skipped" in statuses -> "skipped"
      statuses != [] and Enum.all?(statuses, &(&1 == "ok")) -> "ok"
      gates != [] and required_gates == [] -> "ok"
      true -> "unknown"
    end
  end

  def aggregate_status(_gates), do: "unknown"

  @spec aggregate_reason(term()) :: String.t() | nil
  def aggregate_reason(gates) when is_list(gates) do
    gates = gates |> normalize_gates() |> Enum.filter(&required?/1)

    Enum.find_value(@actionable_statuses, fn actionable_status ->
      gates
      |> Enum.find(&(status(&1) == actionable_status))
      |> reason()
    end)
  end

  def aggregate_reason(_gates), do: nil

  @spec first_actionable(term()) :: map() | nil
  def first_actionable(gates) when is_list(gates) do
    gate =
      gates
      |> normalize_gates()
      |> Enum.filter(&required?/1)
      |> then(fn required_gates ->
        Enum.find_value(@actionable_statuses, fn actionable_status ->
          Enum.find(required_gates, &(status(&1) == actionable_status))
        end)
      end)

    if gate do
      %{
        "gate_id" => gate["gate_id"],
        "label" => gate["label"],
        "status" => status(gate),
        "reason_class" => gate["reason_class"],
        "next_action" => gate["next_action"]
      }
    end
  end

  def first_actionable(_gates), do: nil

  @spec status(term()) :: String.t()
  def status(%{"status" => status}) when is_binary(status), do: status
  def status(_gate), do: "unknown"

  defp reason(nil), do: nil
  defp reason(%{"reason_class" => reason}) when is_binary(reason), do: reason
  defp reason(_gate), do: nil

  defp normalize_value(nil), do: nil
  defp normalize_value(true), do: true
  defp normalize_value(false), do: false
  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp normalize_value(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value
end
