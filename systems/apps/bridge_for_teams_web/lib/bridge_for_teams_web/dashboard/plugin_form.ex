defmodule BridgeForTeamsWeb.Dashboard.PluginForm do
  @moduledoc false
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.Plugins

  @empty_refs %{
    "tool_refs" => [],
    "skill_refs" => [],
    "mcp_refs" => [],
    "oauth_requirements" => [],
    "im_connect_requirements" => []
  }

  def empty_form do
    %{
      "plugin_id" => "",
      "name" => "",
      "description" => "",
      "setup_destination" => "",
      "refs_json" => Jason.encode!(@empty_refs, pretty: true)
    }
  end

  def form_for_definition(definition) when is_map(definition) do
    update_form([definition], definition["plugin_id"])
  end

  def form_from_params(params) when is_map(params) do
    %{
      "plugin_id" => trim(params["plugin_id"]),
      "name" => params["name"] || "",
      "description" => params["description"] || "",
      "setup_destination" => params["setup_destination"] || "",
      "refs_json" => params["refs_json"] || Jason.encode!(@empty_refs, pretty: true)
    }
  end

  def refs_json(form) when is_map(form) do
    case decode_json_object(form["refs_json"] || "{}") do
      {:ok, refs} -> Jason.encode!(Map.merge(@empty_refs, refs), pretty: true)
      _ -> Jason.encode!(@empty_refs, pretty: true)
    end
  end

  def parse_attrs(params, opts \\ []) when is_map(params) do
    refs_json = params["refs_json"] || "{}"
    allow_blank_refs = Keyword.get(opts, :allow_blank_refs, false)

    with {:ok, refs} <- decode_refs_json(refs_json, allow_blank_refs),
         {:ok, setup} <- decode_setup_destination(params["setup_destination"]) do
      attrs =
        %{
          "name" => trim(params["name"]),
          "description" => trim(params["description"])
        }
        |> maybe_put("refs", refs)
        |> maybe_put("setup", setup)

      {:ok, attrs}
    end
  end

  def setup_destination_options do
    [
      {gettext("Agent Swarm skills"), "project_skills"},
      {gettext("Agent Swarm connections"), "project_connections"},
      {gettext("Agent Swarm integrations"), "project_integrations"},
      {gettext("Agent Swarm devices"), "project_devices"},
      {gettext("Agent Swarm agents"), "project_agents"},
      {gettext("Organization OAuth settings"), "org_oauth"},
      {gettext("Organization Feishu settings"), "org_feishu"},
      {gettext("Organization Composio settings"), "org_composio"}
    ]
  end

  def update_form(definitions, plugin_id) when is_list(definitions) do
    plugin_id = trim(plugin_id)

    case Enum.find(definitions, &(&1["plugin_id"] == plugin_id)) do
      nil ->
        empty_form() |> Map.put("plugin_id", plugin_id)

      definition ->
        %{
          "plugin_id" => definition["plugin_id"],
          "name" => definition["name"] || "",
          "description" => definition["description"] || "",
          "setup_destination" => explicit_setup_destination(definition),
          "refs_json" => Jason.encode!(definition["refs"] || %{}, pretty: true)
        }
    end
  end

  defp decode_refs_json(value, true) do
    case trim(value) do
      "" -> {:ok, nil}
      _ -> decode_json_object(value)
    end
  end

  defp decode_refs_json(value, _allow_blank_refs), do: decode_json_object(value)

  defp decode_json_object(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_refs_json}
    end
  end

  defp decode_json_object(_value), do: {:error, :invalid_refs_json}

  defp decode_setup_destination(value) do
    case trim(value) do
      "" ->
        {:ok, nil}

      target ->
        if Plugins.valid_setup_target?(target),
          do: {:ok, %{"destination" => target}},
          else: {:error, :invalid_setup_destination}
    end
  end

  defp explicit_setup_destination(%{"setup" => %{"destination" => target}}) do
    if Plugins.valid_setup_target?(target), do: target, else: ""
  end

  defp explicit_setup_destination(_definition), do: ""

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
