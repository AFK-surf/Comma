defmodule SalixAgent.RecommendationPolicy do
  @moduledoc "Fail-closed authorization for the hidden Comma recommendation agent."

  @always_allowed ~w(help tool_call.get_result recommendation.begin recommendation.publish recommendation.fail)

  def recommendation_agent?(ctx) when is_map(ctx) do
    policy(ctx) == :restricted
  end

  def recommendation_agent?(_ctx), do: false

  def allowed_tool?(ctx, name, args \\ %{}) do
    case policy(ctx) do
      :restricted ->
        name = to_string(name || "")
        name in @always_allowed and adapter_allows?(ctx, name, args)

      :ordinary ->
        true

      :unresolved ->
        false
    end
  end

  def allowed_disclosure?(ctx, candidate) when is_map(candidate) do
    case policy(ctx) do
      :restricted ->
        name = to_string(candidate["name"] || "")

        adapter_allows_disclosure?(ctx, name) and
          (name in @always_allowed or candidate["safety"] == "read")

      :ordinary ->
        true

      :unresolved ->
        false
    end
  end

  defp policy(ctx) do
    explicit = value(ctx, :recommendation_policy)
    disclosed = nested_value(ctx, :tool_disclosure, :recommendation_policy)

    case explicit || disclosed do
      value when value in [:restricted, "restricted"] -> :restricted
      value when value in [:ordinary, "ordinary"] -> :ordinary
      value when value in [:unresolved, "unresolved"] -> :unresolved
      nil -> :ordinary
      _ -> :unresolved
    end
  end

  defp adapter_allows_disclosure?(ctx, name) do
    case Application.get_env(:salix_agent, :recommendation_adapter_mod) do
      nil -> false
      module -> module.authorize_disclosure(ctx, name) == :ok
    end
  end

  defp adapter_allows?(ctx, name, args) do
    case Application.get_env(:salix_agent, :recommendation_adapter_mod) do
      nil -> false
      module -> module.authorize_tool(ctx, name, args) == :ok
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp nested_value(map, parent_key, child_key) do
    case value(map, parent_key) do
      nested when is_map(nested) -> value(nested, child_key)
      _ -> nil
    end
  end
end
