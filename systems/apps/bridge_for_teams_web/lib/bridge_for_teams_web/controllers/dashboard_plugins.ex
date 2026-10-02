defmodule BridgeForTeamsWeb.DashboardPlugins do
  @moduledoc """
  Builds the Plugins page payload and saves organization plugins for
  `DashboardAPIController`.

  Salix owns plugin definitions, so each read or write is one Salix call and
  no database row per plugin. Every org member reads the catalog: the
  organization's own plugins and the product plugins of the system catalog.
  Only owners and admins create or update organization plugins; enabling a
  plugin happens inside each Agent Swarm. A Salix outage answers 503
  `runtime_unavailable`.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.Plugins

  @admin_roles ~w(owner admin)
  @ref_keys ~w(tool_refs skill_refs mcp_refs oauth_requirements im_connect_requirements)

  @doc "The catalog and whether the caller may manage organization plugins."
  def page(org, user, role) do
    case Plugins.list_org_plugins(org.id, actor_user_id: user.id) do
      {:ok, %{definitions: definitions}} ->
        {:ok,
         %{
           "viewer" => %{"can_manage" => role in @admin_roles},
           "plugins" =>
             for definition <- definitions,
                 definition["owner_scope"] in ~w(tenant system),
                 Plugins.product_plugin?(definition) do
               public_plugin(definition)
             end
         }}

      {:error, reason} ->
        error(reason, gettext("Could not load plugins."))
    end
  end

  @doc "Create an organization plugin; Salix assigns its id."
  def create(org, user, role, params) do
    with :ok <- require_admin(role),
         {:ok, attrs} <- definition_attrs(params) do
      org.id |> Plugins.create_tenant_definition(attrs, audit_opts(user)) |> saved()
    end
  end

  @doc "Update an organization plugin. Without `refs` its capabilities stay."
  def update(org, user, role, plugin_id, params) do
    with :ok <- require_admin(role),
         {:ok, attrs} <- definition_attrs(Map.put_new(params, "refs", nil)) do
      org.id |> Plugins.update_tenant_definition(plugin_id, attrs, audit_opts(user)) |> saved()
    end
  end

  defp saved({:ok, definition}) when is_map(definition), do: {:ok, public_plugin(definition)}
  defp saved({:error, reason}), do: error(reason, gettext("Couldn't save the plugin."))
  defp saved(_other), do: error(:invalid_response, gettext("Couldn't save the plugin."))

  defp require_admin(role) when role in @admin_roles, do: :ok
  defp require_admin(_role), do: error(:forbidden, nil)

  # Capability references are strings or JSON objects, grouped by category.
  defp definition_attrs(params) do
    refs = params["refs"]
    destination = text(params["setup_destination"])

    cond do
      not (is_nil(refs) or is_map(refs)) ->
        invalid(gettext("Refs JSON must be an object."))

      is_map(refs) and not Enum.all?(refs, fn {_key, value} -> is_list(value) end) ->
        invalid(gettext("Each capability category must be an array."))

      destination != "" and not Plugins.valid_setup_target?(destination) ->
        invalid(gettext("Choose a valid setup destination."))

      true ->
        {:ok,
         %{"name" => text(params["name"]), "description" => text(params["description"])}
         |> put_present("refs", refs)
         |> put_present("setup", if(destination != "", do: %{"destination" => destination}))}
    end
  end

  defp public_plugin(definition) do
    destination = get_in(definition, ["setup", "destination"])

    %{
      "plugin_id" => definition["plugin_id"],
      "name" => definition["name"],
      "description" => definition["description"],
      "owner_scope" => definition["owner_scope"],
      "editable" => definition["owner_scope"] == "tenant" and definition["read_only"] != true,
      "refs" => Map.new(@ref_keys, &{&1, definition |> get_in(["refs", &1]) |> List.wrap()}),
      "setup_destination" => if(Plugins.valid_setup_target?(destination), do: destination),
      "setup_targets" => Plugins.setup_targets(definition)
    }
  end

  defp error(reason, _message) when reason in [:unavailable, :timeout],
    do:
      {:error, 503, "runtime_unavailable",
       gettext("Plugins are unavailable right now. Retry shortly."), %{}}

  defp error(:forbidden, _message),
    do: {:error, 403, "forbidden", gettext("Only organization admins can manage plugins."), %{}}

  defp error(:not_found, _message),
    do: {:error, 404, "plugin_not_found", gettext("Plugin data was not found."), %{}}

  defp error({:bad_request, message}, _fallback) when is_binary(message), do: invalid(message)
  defp error(_reason, message), do: {:error, 500, "write_failed", message, %{}}

  defp invalid(message), do: {:error, 422, "invalid_plugin", message, %{}}

  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp audit_opts(user) do
    label =
      Enum.find([user.email, user.name], user.id, &(text(&1) != ""))

    [actor_user_id: user.id, actor_label: String.trim(label), request_id: Ecto.UUID.generate()]
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
