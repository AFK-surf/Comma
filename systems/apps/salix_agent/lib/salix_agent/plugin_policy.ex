defmodule SalixAgent.PluginPolicy do
  @moduledoc false

  @doc false
  def allowed_tool?(ctx, tool_name) when is_map(ctx) do
    case projection(ctx) do
      nil ->
        true

      projection ->
        names = SalixAgent.ToolPolicy.tool_permission_names(to_string(tool_name || ""))

        Enum.any?(names, &enabled_tool?(projection, &1)) or
          not Enum.any?(names, &disabled_tool?(projection, &1))
    end
  end

  def allowed_tool?(_ctx, _tool_name), do: true

  @doc false
  def visible_skill?(ctx, skill_id) when is_map(ctx) do
    case projection(ctx) do
      nil ->
        false

      projection ->
        skill_id = to_string(skill_id || "")
        exact = MapSet.new(List.wrap(projection["visible_skill_ids"] || []))
        prefixes = List.wrap(projection["visible_skill_prefixes"] || [])

        MapSet.member?(exact, skill_id) or Enum.any?(prefixes, &String.starts_with?(skill_id, &1))
    end
  end

  def visible_skill?(_ctx, _skill_id), do: false

  @doc false
  def visible_im_provider?(ctx, provider) do
    case to_string(provider || "") do
      "" ->
        false

      provider ->
        case projection(ctx) do
          nil ->
            true

          projection ->
            prefix = "im_api." <> provider <> "."

            enabled_tool_family?(projection, prefix) or
              not disabled_tool_family?(projection, prefix)
        end
    end
  end

  @doc false
  def projection(ctx) when is_map(ctx) do
    case Map.get(ctx, :plugin_projection) || Map.get(ctx, "plugin_projection") do
      %{"revision" => _} = projection -> projection
      %{revision: _} = projection -> stringify(projection)
      _ -> nil
    end
  end

  def projection(_ctx), do: nil

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp enabled_tool_exact(projection),
    do: projection |> Map.get("allowed_tools", []) |> List.wrap() |> MapSet.new()

  defp enabled_tool_prefixes(projection),
    do: projection |> Map.get("allowed_tool_prefixes", []) |> List.wrap()

  defp enabled_tool?(projection, name) do
    MapSet.member?(enabled_tool_exact(projection), name) or
      Enum.any?(enabled_tool_prefixes(projection), &String.starts_with?(name, &1))
  end

  defp enabled_tool_family?(projection, prefix) do
    Enum.any?(enabled_tool_exact(projection), &String.starts_with?(&1, prefix)) or
      Enum.any?(
        enabled_tool_prefixes(projection),
        &(String.starts_with?(prefix, &1) or String.starts_with?(&1, prefix))
      )
  end

  defp disabled_tool_exact(projection),
    do: projection |> Map.get("disabled_tools", []) |> List.wrap() |> MapSet.new()

  defp disabled_tool_prefixes(projection),
    do: projection |> Map.get("disabled_tool_prefixes", []) |> List.wrap()

  defp disabled_tool?(projection, name) do
    MapSet.member?(disabled_tool_exact(projection), name) or
      Enum.any?(disabled_tool_prefixes(projection), &String.starts_with?(name, &1))
  end

  defp disabled_tool_family?(projection, prefix),
    do: Enum.any?(disabled_tool_prefixes(projection), &String.starts_with?(prefix, &1))
end
