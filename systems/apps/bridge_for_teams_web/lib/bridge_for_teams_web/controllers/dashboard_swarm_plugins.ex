defmodule BridgeForTeamsWeb.DashboardSwarmPlugins do
  @moduledoc """
  Builds the Agent Swarm Plugins page payloads and applies its writes for
  `DashboardAPIController`: the product plugins this swarm can use with their
  enablement, one plugin's MCP servers and connections, Android admission,
  enable and disable, project plugin definitions, and the confirmed connect,
  reconnect and disconnect of a plugin credential.

  Salix owns plugin definitions and group enablement, so the list and the
  detail are each one Salix read of the group's definitions and enablements
  (plus the Android admission record when the Android plugin is listed) and
  no database row per plugin. A connect reads them once more to find the
  credential and its dependent MCP servers. A swarm that is still preparing
  answers 409 `group_not_ready`; a Salix outage answers 503.

  A managed-OAuth or Composio connect answers the provider address the
  browser opens, or that the credential is already connected. A messaging
  (IM connect) credential is set up on the swarm's Connections page, so its
  connect is refused here.

  Every swarm member reads the pages; every write is for swarm admins. A
  refused write records a denied audit entry, as the LiveView page did.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Environments, Observability, Plugins}
  alias BridgeForTeamsWeb.DashboardPlugins

  @android "android-control"
  @ref_keys ~w(tool_refs skill_refs mcp_refs oauth_requirements im_connect_requirements)
  @ready_mcp_states ~w(ready_on_use running degraded)
  @fixed_mcp_states ~w(ready_on_use running degraded disabled conflict)

  # ---- Reads ----

  @doc "The swarm's product plugins, sorted by name, with their enablement."
  def page(org, user, project, role) do
    with {:ok, listed} <- list(org, user, project) do
      plugins = Enum.filter(listed.definitions, &Plugins.product_plugin?/1)
      android = if Enum.any?(plugins, &(&1["plugin_id"] == @android)), do: android(project)

      {:ok,
       %{
         "project" => public_project(project, role),
         "plugins" =>
           plugins
           |> Enum.sort_by(&(&1["name"] || &1["plugin_id"] || ""))
           |> Enum.map(&row(&1, listed.enablement_by_id, role, android)),
         "android" => android
       }}
    end
  end

  @doc """
  One plugin with its MCP servers and connections; `plugin` is nil when the
  swarm cannot see it, so the page can say so in place.
  """
  def show(org, user, project, role, plugin_id) do
    with {:ok, listed} <- list(org, user, project) do
      definition = find(listed.definitions, plugin_id)
      android = if definition && definition["plugin_id"] == @android, do: android(project)

      {:ok,
       %{
         "project" => public_project(project, role),
         "plugin" =>
           definition &&
             definition
             |> row(listed.enablement_by_id, role, android)
             |> Map.put("setup", setup(org, project, definition)),
         "android" => android
       }}
    end
  end

  # ---- Writes ----

  @doc "Turn a plugin on or off for this swarm; the Android plugin needs tenant admission."
  def set_enabled(org, user, project, role, plugin_id, params) do
    enabled = params["enabled"]
    action = if enabled == true, do: "enabled", else: "disabled"

    with :ok <-
           authorize(role, fn ->
             denied(org, user, project, "plugin.group_enablement.#{action}", "plugin", %{
               "plugin_id_configured" => present?(plugin_id)
             })
           end),
         true <-
           is_boolean(enabled) ||
             {:error, 422, "invalid_enablement", gettext("Could not update plugin state."), %{}},
         :ok <- android_admission(project, plugin_id, enabled) do
      result =
        if enabled,
          do: Plugins.enable_project_plugin(org.id, project.id, plugin_id, audit_opts(user)),
          else: Plugins.disable_project_plugin(org.id, project.id, plugin_id, audit_opts(user))

      case result do
        {:ok, _enablement} ->
          {:ok,
           %{
             "notice" =>
               if(enabled, do: gettext("Plugin enabled."), else: gettext("Plugin disabled."))
           }}

        {:error, reason} ->
          plugin_error(reason)
      end
    end
  end

  @doc "Create a project plugin definition; Salix assigns its id."
  def create(org, user, project, role, params) do
    with :ok <-
           authorize(role, fn ->
             denied(org, user, project, "plugin.group_definition.created", "plugin", %{
               "name_configured" => present?(params["name"])
             })
           end),
         {:ok, attrs} <- DashboardPlugins.definition_attrs(params) do
      case Plugins.create_group_definition(org.id, project.id, attrs, audit_opts(user)) do
        {:ok, definition} ->
          {:ok,
           %{
             "plugin_id" => definition["plugin_id"],
             "notice" => gettext("Plugin created: %{id}.", id: definition["plugin_id"])
           }}

        {:error, reason} ->
          plugin_error(reason)
      end
    end
  end

  @doc "Update a project plugin definition. Without `refs` its capabilities stay."
  def update(org, user, project, role, plugin_id, params) do
    with :ok <-
           authorize(role, fn ->
             denied(org, user, project, "plugin.group_definition.updated", "plugin", %{
               "plugin_id_configured" => present?(plugin_id)
             })
           end),
         {:ok, attrs} <- DashboardPlugins.definition_attrs(Map.put_new(params, "refs", nil)) do
      case Plugins.update_group_definition(
             org.id,
             project.id,
             plugin_id,
             attrs,
             audit_opts(user)
           ) do
        {:ok, _definition} -> {:ok, %{"notice" => gettext("Plugin updated.")}}
        {:error, reason} -> plugin_error(reason)
      end
    end
  end

  @doc """
  Start the confirmed connection of a plugin credential. A credential that
  is already connected is authorized again (reconnect), except a connected
  managed-OAuth account whose MCP servers are not running yet: that one
  configures them with the existing account. `base_url` is the dashboard
  origin the provider returns the browser to.
  """
  def connect(org, user, project, role, plugin_id, connection_id, base_url, params \\ %{}) do
    with :ok <-
           authorize(role, fn ->
             denied(org, user, project, "plugin.setup.authorization_started", "plugin", %{
               "plugin_id" => plugin_id
             })
           end),
         {:ok, listed} <- list(org, user, project),
         {:ok, connection, mcps} <- find_connection(listed.definitions, plugin_id, connection_id) do
      action = connect_action(connection, mcps)

      return_to =
        "#{base_url}/orgs/#{org.slug}/projects/#{project.id}/plugins/#{segment(plugin_id)}"

      org.id
      |> Plugins.connect_plugin(
        project.id,
        plugin_id,
        connection_id,
        return_to,
        [force_reauthorize: action == "reconnect"] ++ credential_opts(params) ++ audit_opts(user)
      )
      |> connect_result()
    end
  end

  defp credential_opts(%{"config_values" => values}), do: [config_values: values]
  defp credential_opts(_params), do: []

  @doc "Disconnect a plugin credential from the plugin and its dependent MCP servers."
  def disconnect(org, user, project, role, plugin_id, connection_id) do
    with :ok <-
           authorize(role, fn ->
             denied(org, user, project, "connection.disconnect", "connection", %{
               "plugin_id" => plugin_id
             })
           end) do
      case Plugins.disconnect_plugin(
             org.id,
             project.id,
             plugin_id,
             connection_id,
             audit_opts(user)
           ) do
        {:ok, _value} -> {:ok, %{"notice" => gettext("Connection disconnected.")}}
        {:error, reason} -> setup_error(reason)
      end
    end
  end

  defp connect_result({:ok, %{"authorization_url" => url}}) when is_binary(url) and url != "",
    do: {:ok, %{"redirect_url" => url}}

  defp connect_result({:ok, %{"redirect_url" => url}}) when is_binary(url) and url != "",
    do: {:ok, %{"redirect_url" => url}}

  defp connect_result({:ok, %{"status" => "connected"}}),
    do: {:ok, %{"notice" => gettext("Connected")}}

  defp connect_result({:ok, _payload}), do: setup_error(:no_redirect_url)
  defp connect_result({:error, reason}), do: setup_error(reason)

  # ---- Plugins ----

  defp list(org, user, project) do
    case Plugins.list_project_plugins(org.id, project.id, actor_user_id: user.id) do
      {:ok, listed} -> {:ok, listed}
      {:error, reason} -> plugin_error(reason)
    end
  end

  defp find(definitions, plugin_id) do
    plugin_id = text(plugin_id)
    Enum.find(definitions, &(&1["plugin_id"] == plugin_id))
  end

  defp row(definition, enablement_by_id, role, android) do
    locked = definition["locked"] == true
    admin = role == "admin"

    %{
      "plugin_id" => definition["plugin_id"],
      "name" => definition["name"],
      "description" => definition["description"],
      "owner_scope" => definition["owner_scope"],
      "enabled" => Plugins.enabled?(definition, enablement_by_id),
      "locked" => locked,
      "toggleable" =>
        admin and not locked and
          (definition["plugin_id"] != @android or match?(%{"entitled" => true}, android)),
      "editable" =>
        admin and definition["owner_scope"] == "group" and definition["read_only"] != true,
      "attention" => attention(definition),
      "refs" => Map.new(@ref_keys, &{&1, definition |> get_in(["refs", &1]) |> List.wrap()}),
      "setup_destination" => setup_destination(definition)
    }
  end

  defp setup_destination(definition) do
    destination = get_in(definition, ["setup", "destination"])
    if Plugins.valid_setup_target?(destination), do: destination
  end

  # The MCP servers and messaging connections that still need setup.
  defp attention(%{"setup_status" => status}) when is_map(status) do
    mcps =
      for mcp <- List.wrap(status["mcps"]),
          is_map(mcp),
          mcp["state"] not in @ready_mcp_states,
          do: mcp["alias"] || mcp["mcp_id"] || gettext("MCP")

    messaging =
      for connection <- List.wrap(status["connections"]),
          is_map(connection),
          connection["kind"] == "im_connect",
          connection["state"] not in ~w(connected external),
          do: connection["label"] || connection["id"] || gettext("Messaging")

    mcps ++ messaging
  end

  defp attention(_definition), do: []

  # ---- Setup: MCP servers and connections ----

  defp setup(org, project, %{"setup_status" => %{"type" => "integration"} = status}) do
    connections = Enum.filter(List.wrap(status["connections"]), &is_map/1)
    mcps = Enum.filter(List.wrap(status["mcps"]), &is_map/1)
    public = &connection(org, project, &1, mcps)

    servers =
      for mcp <- mcps,
          used <- [Enum.filter(connections, &(&1["id"] in auth_refs(mcp)))],
          used != [] do
        %{
          "alias" => mcp["alias"],
          "placement" => mcp["placement"],
          "state" => mcp_state(mcp, used),
          "connections" => Enum.map(used, public)
        }
      end

    # A credential no listed MCP server uses stands on its own.
    used =
      for server <- servers, used <- server["connections"], into: MapSet.new(), do: used["id"]

    %{
      "mcps" => servers,
      "connections" =>
        for(
          connection <- connections,
          not MapSet.member?(used, connection["id"]),
          do: public.(connection)
        )
    }
  end

  defp setup(_org, _project, _definition), do: nil

  defp connection(org, project, connection, mcps) do
    kind = connection["kind"]
    dependent = Enum.filter(mcps, &(connection["id"] in auth_refs(&1)))
    messaging = kind == "im_connect"

    %{
      "id" => connection["id"],
      "kind" => kind,
      "label" => connection["label"] || connection["id"],
      "state" => connection["state"],
      "dependent_mcps" => Enum.map(dependent, & &1["alias"]),
      "credential_setup" =>
        if(kind == "mcp_api_key",
          do: %{
            "key" => connection["config_key"],
            "label" => connection["credential_label"],
            "help_url" => connection["help_url"]
          }
        ),
      "action" => if(messaging, do: nil, else: connect_action(connection, dependent)),
      # A Composio account is disconnected from the Composio connection list.
      "disconnectable" =>
        kind not in ~w(im_connect composio) and connection["state"] == "connected",
      "integrations_href" =>
        if(messaging, do: integrations_href(org, project, connection["provider"]))
    }
  end

  # The Connections page scrolls to the provider's messaging section.
  defp integrations_href(org, project, provider) do
    base = "/orgs/#{org.slug}/projects/#{project.id}/connections"
    if present?(provider), do: base <> "?" <> URI.encode_query(provider: provider), else: base
  end

  defp find_connection(definitions, plugin_id, connection_id) do
    with %{} = definition <- find(definitions, plugin_id),
         %{} = connection <-
           Enum.find(
             List.wrap(get_in(definition, ["setup_status", "connections"])),
             &(is_map(&1) and &1["id"] == connection_id)
           ) do
      if connection["kind"] == "im_connect" do
        {:error, 422, "messaging_connection",
         gettext("Set up this messaging connection on the Connections page."), %{}}
      else
        mcps =
          get_in(definition, ["setup_status", "mcps"])
          |> List.wrap()
          |> Enum.filter(&(is_map(&1) and connection_id in auth_refs(&1)))

        {:ok, connection, mcps}
      end
    else
      _missing ->
        {:error, 404, "connection_not_found", gettext("Plugin connection was not found."), %{}}
    end
  end

  # A connected managed-OAuth account whose MCP servers are not running yet
  # configures them with that account; any other connected credential is
  # authorized again.
  defp connect_action(%{"kind" => "managed_oauth", "state" => "connected"}, [_ | _] = mcps) do
    if Enum.all?(mcps, &(&1["state"] in @ready_mcp_states)), do: "reconnect", else: "connect"
  end

  defp connect_action(%{"state" => "connected"}, _mcps), do: "reconnect"
  defp connect_action(_connection, _mcps), do: "connect"

  defp mcp_state(%{"state" => state}, _connections) when state in @fixed_mcp_states, do: state

  defp mcp_state(mcp, connections) do
    cond do
      Enum.any?(connections, &(&1["state"] == "missing_scopes")) ->
        "missing_scopes"

      Enum.any?(connections, &(&1["state"] == "reauthorization_required")) ->
        "reauthorization_required"

      Enum.any?(connections, &(&1["state"] == "connected")) ->
        mcp["state"]

      Enum.any?(connections, &(&1["kind"] == "mcp_api_key")) ->
        "waiting_for_credentials"

      true ->
        "waiting_for_oauth"
    end
  end

  defp auth_refs(%{"auth_refs" => refs}) when is_list(refs), do: refs
  defp auth_refs(%{"auth_ref" => ref}) when is_binary(ref), do: [ref]
  defp auth_refs(_mcp), do: []

  # ---- Android ----

  defp android(project) do
    case Environments.android_control_status(project.id) do
      {:ok, %{entitled: entitled}} -> %{"status" => "ok", "entitled" => entitled == true}
      {:error, _reason} -> %{"status" => "unavailable", "entitled" => false}
    end
  end

  # Admission is read again when the plugin is turned on.
  defp android_admission(project, @android, true) do
    case Environments.android_control_status(project.id) do
      {:ok, %{entitled: true}} ->
        :ok

      {:ok, _not_entitled} ->
        {:error, 409, "android_not_entitled",
         gettext("Android connector access is not enabled for this organization."), %{}}

      {:error, _reason} ->
        {:error, 503, "android_unavailable",
         gettext("Android admission status is unavailable. Try again shortly."), %{}}
    end
  end

  defp android_admission(_project, _plugin_id, _enabled), do: :ok

  # ---- Authorization and envelopes ----

  defp authorize("admin", _record), do: :ok

  defp authorize(_role, record) do
    _ = record.()
    {:error, 403, "forbidden", gettext("Only Agent Swarm admins can manage plugins."), %{}}
  end

  defp denied(org, user, project, action, resource_type, metadata) do
    Observability.record_write_attempt(%{
      org_id: org.id,
      actor_user_id: user.id,
      actor_label: actor_label(user),
      action: action,
      resource_type: resource_type,
      resource_label: project.name,
      result: "denied",
      reason: :forbidden,
      request_id: SystemsRuntime.Proc.uuid(),
      surface: "plugins",
      metadata:
        Map.merge(
          %{
            "project_id" => project.id,
            "salix_group_id" => project.salix_group_id,
            "surface" => "plugins"
          },
          metadata
        )
    })
  end

  defp plugin_error({:bad_request, message}) when is_binary(message),
    do: {:error, 422, "invalid_plugin", message, %{}}

  defp plugin_error(:group_not_ready),
    do:
      {:error, 409, "group_not_ready", gettext("Agent Swarm is still preparing. Retry shortly."),
       %{}}

  defp plugin_error(:forbidden),
    do: {:error, 403, "forbidden", gettext("Only Agent Swarm admins can manage plugins."), %{}}

  defp plugin_error(:not_found),
    do: {:error, 404, "plugin_not_found", gettext("Plugin data was not found."), %{}}

  defp plugin_error(:timeout),
    do: {:error, 503, "runtime_unavailable", gettext("Salix timed out. Retry shortly."), %{}}

  defp plugin_error(:unavailable),
    do: {:error, 503, "runtime_unavailable", gettext("Salix is unavailable. Retry shortly."), %{}}

  defp plugin_error(_reason),
    do: {:error, 503, "runtime_unavailable", gettext("Could not update plugin state."), %{}}

  defp setup_error(:plugin_credential_rejected),
    do:
      {:error, 422, "credential_rejected",
       gettext("The service rejected this token. Check it and try again."), %{}}

  defp setup_error(:plugin_connection_unavailable),
    do:
      {:error, 503, "connection_unavailable",
       gettext("The token was saved, but the service could not connect. Retry shortly."), %{}}

  defp setup_error({kind, message})
       when kind in [:conflict, :bad_request, :precondition_failed] and is_binary(message),
       do:
         {:error, if(kind == :conflict, do: 409, else: 422), "connection_rejected", message, %{}}

  defp setup_error(:group_not_ready),
    do:
      {:error, 409, "group_not_ready", gettext("The runtime is not ready yet. Retry shortly."),
       %{}}

  defp setup_error(reason) when reason in [:provider_not_configured, :not_configured],
    do:
      {:error, 422, "provider_not_configured",
       gettext("That platform isn't configured for your organization yet."), %{}}

  defp setup_error({:precondition_failed, _detail}), do: setup_error(:provider_not_configured)

  defp setup_error({:bad_request, _detail}),
    do:
      {:error, 422, "connection_rejected",
       gettext("The platform rejected the authorization request."), %{}}

  defp setup_error(:forbidden),
    do: {:error, 403, "forbidden", gettext("Only Agent Swarm admins can connect plugins."), %{}}

  defp setup_error(reason) when reason in [:unavailable, :timeout],
    do:
      {:error, 503, "runtime_unavailable",
       gettext("Salix is unavailable right now. Retry shortly."), %{}}

  defp setup_error(_reason),
    do:
      {:error, 503, "write_failed", gettext("Could not connect the account. Please try again."),
       %{}}

  defp public_project(project, role),
    do: %{"id" => project.id, "name" => project.name, "role" => role}

  defp audit_opts(user),
    do: [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: SystemsRuntime.Proc.uuid()
    ]

  defp actor_label(user), do: nonblank(user.email) || nonblank(user.name) || user.id

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonblank(_value), do: nil

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
