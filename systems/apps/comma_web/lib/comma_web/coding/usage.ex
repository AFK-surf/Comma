defmodule CommaWeb.Coding.Usage do
  @moduledoc """
  Public egress whitelist for coding Task usage facts.

  Shared by both `CommaWeb.SalixClient` (SSE / API `run.facts.usage`) and
  `CommaWeb.Coding.Endpoints` (HTTP `/history` responses) so internal ledger
  keys (`sessions`, `retired_sessions`, `by_slot[*].session`, `agent_id`, etc.)
  can never leak to clients.
  """

  @numeric_keys ~w(modelCalls inputTokens cachedTokens outputTokens)

  @doc """
  Sanitizes a raw Task or Session usage payload into its public client shape.
  Returns `nil` when input is `nil` or not a valid usage map.
  """
  def public_usage(nil), do: nil

  def public_usage(%{} = usage) do
    if Enum.any?(@numeric_keys, &is_number(Map.get(usage, &1))) do
      base =
        %{
          "modelCalls" => numeric(usage["modelCalls"]),
          "inputTokens" => numeric(usage["inputTokens"]),
          "cachedTokens" => numeric(usage["cachedTokens"]),
          "outputTokens" => numeric(usage["outputTokens"]),
          "model" => if(is_binary(usage["model"]), do: usage["model"], else: nil)
        }
        |> put_public_models(usage["models"])
        |> put_public_partial(usage["partial"])
        |> put_public_by_slot(usage["by_slot"])

      base
    else
      nil
    end
  end

  def public_usage(_other), do: nil

  defp numeric(v) when is_integer(v) or is_float(v), do: v
  defp numeric(_v), do: 0

  defp put_public_models(acc, models) when is_map(models) and map_size(models) > 0 do
    sanitized =
      Enum.reduce(models, %{}, fn {model, value}, map ->
        cond do
          not is_binary(model) or model == "" ->
            map

          is_number(value) ->
            Map.put(map, model, value)

          is_map(value) ->
            counts =
              %{
                "modelCalls" => numeric(value["modelCalls"]),
                "inputTokens" => numeric(value["inputTokens"]),
                "cachedTokens" => numeric(value["cachedTokens"]),
                "outputTokens" => numeric(value["outputTokens"])
              }

            Map.put(map, model, counts)

          true ->
            map
        end
      end)

    if map_size(sanitized) > 0, do: Map.put(acc, "models", sanitized), else: acc
  end

  defp put_public_models(acc, models) when is_list(models) do
    names =
      models
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    if names == [], do: acc, else: Map.put(acc, "models", names)
  end

  defp put_public_models(acc, _models), do: acc

  defp put_public_partial(acc, true), do: Map.put(acc, "partial", true)
  defp put_public_partial(acc, _other), do: acc

  defp put_public_by_slot(acc, by_slot) when is_map(by_slot) and map_size(by_slot) > 0 do
    sanitized =
      Enum.reduce(by_slot, %{}, fn {slot, entry}, map ->
        if is_binary(slot) and slot != "" and is_map(entry) do
          public_entry =
            %{"slot" => slot}
            |> maybe_put_bool("is_primary", entry["is_primary"])
            |> maybe_put_bool("unreadable", entry["unreadable"])
            |> maybe_put_bool("partial", entry["partial"])
            |> maybe_put_model(entry["model"])
            |> put_slot_usage(entry)

          Map.put(map, slot, public_entry)
        else
          map
        end
      end)

    if map_size(sanitized) > 0, do: Map.put(acc, "by_slot", sanitized), else: acc
  end

  defp put_public_by_slot(acc, _by_slot), do: acc

  defp put_slot_usage(entry_map, %{"usage" => nil}), do: Map.put(entry_map, "usage", nil)

  defp put_slot_usage(entry_map, %{"usage" => %{} = nested}) do
    Map.put(entry_map, "usage", public_leaf_usage(nested))
  end

  defp put_slot_usage(entry_map, raw_entry) do
    if Enum.any?(@numeric_keys, &is_number(Map.get(raw_entry, &1))) do
      Map.put(entry_map, "usage", public_leaf_usage(raw_entry))
    else
      entry_map
    end
  end

  defp public_leaf_usage(%{} = u) do
    %{
      "modelCalls" => numeric(u["modelCalls"]),
      "inputTokens" => numeric(u["inputTokens"]),
      "cachedTokens" => numeric(u["cachedTokens"]),
      "outputTokens" => numeric(u["outputTokens"]),
      "model" => if(is_binary(u["model"]), do: u["model"], else: nil)
    }
  end

  defp maybe_put_bool(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp maybe_put_bool(map, _key, _value), do: map

  defp maybe_put_model(map, model) when is_binary(model) and model != "",
    do: Map.put(map, "model", model)

  defp maybe_put_model(map, _model), do: map
end
