defmodule Salix.Control.PluginSetup do
  @moduledoc false

  alias Salix.Control.{Groups, OAuthBindings}
  alias SalixIM.ProviderConnects
  alias SalixMCP.{Gateway, Store}

  @setup_type "integration"
  # device_client: the MCP runs in the Comma desktop app on one member's Mac; that
  # Mac, not an OAuth grant, is what connects it (connect_device/5).
  @connection_kinds ~w(native_mcp_oauth managed_oauth composio im_connect mcp_api_key device_client)

  def credential_setup(definition, connection_id \\ nil) do
    with {:ok, setup} <- contract(definition),
         %{"kind" => "mcp_api_key"} = connection <-
           Enum.find(
             setup.connections,
             &(&1["id"] == (connection_id || credential_connection_id(setup)))
           ) do
      %{
        "key" => connection["config_key"],
        "label" => connection["credential_label"],
        "helpUrl" => connection["help_url"]
      }
    else
      _ -> nil
    end
  end

  defp credential_connection_id(setup) do
    case Enum.find(setup.connections, &(&1["kind"] == "mcp_api_key")) do
      nil -> setup.default_connection
      connection -> connection["id"]
    end
  end

  def configure_credentials(
        tenant_id,
        group_id,
        definition,
        values,
        connection_id \\ nil,
        opts \\ []
      ) do
    with %{"key" => key} <- credential_setup(definition, connection_id),
         {:ok, value} <- credential_value(values, key),
         config <- credential_config(definition, key, value, opts),
         definition <- credential_definition(definition, config),
         {:ok, %{"bindings" => [binding]}} <-
           prepare(tenant_id, group_id, definition, connection_id),
         {:ok, binding} <-
           Gateway.update_binding(tenant_id, group_id, binding["binding_id"], %{
             "config_values" => config,
             "enabled" => true
           }),
         {:ok, connection} <- Gateway.refresh_binding(tenant_id, group_id, binding["binding_id"]) do
      case connection["status"] do
        "running" ->
          :ok

        status when status in ~w(auth_failed not_authorized reauthorization_required) ->
          {:error, :plugin_credential_rejected}

        _ ->
          {:error, :plugin_connection_unavailable}
      end
    else
      nil -> {:error, {:bad_request, "plugin does not accept credentials"}}
      {:error, _} = error -> error
      _ -> {:error, {:bad_request, "plugin credential setup is invalid"}}
    end
  end

  defp credential_config(%{"plugin_id" => "x-twitter"}, key, value, opts) do
    if Keyword.get(opts, :app_only, false),
      do: %{key => value, "X_AUTH_MODE" => "app_only"},
      else: %{key => value}
  end

  defp credential_config(_definition, key, value, _opts), do: %{key => value}

  # The first refresh must already use Comma's explicit credential selection.
  defp credential_definition(definition, %{"X_AUTH_MODE" => "app_only"} = config) do
    update_in(definition, ["setup", "mcps"], fn mcps ->
      Enum.map(mcps, &Map.put(&1, "config_values", config))
    end)
  end

  defp credential_definition(definition, _config), do: definition

  def disconnect_credentials(tenant_id, group_id, definition, connection_id) do
    with %{"key" => key} <- credential_setup(definition, connection_id),
         {:ok, %{"bindings" => [binding]}} <-
           prepare(tenant_id, group_id, definition, connection_id) do
      if definition["plugin_id"] == "x-twitter" do
        with {:ok, current} <- Store.get_binding(tenant_id, group_id, binding["binding_id"]),
             {:ok, _} <-
               Gateway.update_binding(tenant_id, group_id, binding["binding_id"], %{
                 "config_values" => Map.delete(current["config_values"] || %{}, key)
               }),
             do: :ok
      else
        Gateway.delete_binding(tenant_id, group_id, binding["binding_id"])
      end
    else
      nil -> {:error, {:bad_request, "plugin does not accept credentials"}}
      {:error, _} = error -> error
      _ -> {:error, {:bad_request, "plugin credential setup is invalid"}}
    end
  end

  defp credential_value(values, key) when is_map(values) and map_size(values) == 1 do
    value = values[key]

    if is_binary(value) and byte_size(value) <= 4096 and
         Regex.match?(~r/\A[^\s]+\z/u, String.trim(value)) do
      {:ok, String.trim(value)}
    else
      {:error, {:bad_request, "enter a valid App-only Bearer Token"}}
    end
  end

  defp credential_value(_, _),
    do: {:error, {:bad_request, "enter the required plugin credential"}}

  def resolve_statuses(definitions, tenant_id, group_id) do
    if Enum.any?(definitions, &match?({:ok, _setup}, contract(&1))) do
      oauth_bindings = oauth_bindings_for_status(definitions, group_id)
      mcp_bindings = Store.list_group_bindings(tenant_id, group_id, include_disabled: true)
      im_connects = group_im_connects(group_id)
      Enum.map(definitions, &put_status(&1, oauth_bindings, mcp_bindings, im_connects))
    else
      definitions
    end
  end

  defp oauth_bindings_for_status(definitions, group_id) do
    bindings = OAuthBindings.list(group_id)

    if Enum.any?(definitions, &(&1["plugin_id"] == "x-twitter")) do
      others = Enum.reject(bindings, &(&1["provider"] == "x"))

      case OAuthBindings.select_provider_record(group_id, "x", "x") do
        {:error, :not_found} ->
          others

        {:ok, binding} ->
          detail =
            Enum.find(bindings, &(&1["binding_id"] == binding["binding_id"])) ||
              Map.put(binding, "status", "reauthorization_required")

          [detail | others]

        {:error, _} ->
          [%{"provider" => "x", "alias" => "x", "status" => "unknown"} | others]
      end
    else
      bindings
    end
  end

  def prepare(tenant_id, group_id, definition, connection_id \\ nil)

  def prepare(tenant_id, group_id, %{"owner_scope" => "system"} = definition, connection_id) do
    with {:ok, setup} <- contract(definition),
         {:ok, _group} <- Groups.get(group_id, tenant_id),
         {:ok, connection} <- select_connection(setup, connection_id),
         :ok <- not_device_client(connection),
         {:ok, connection} <- selected_oauth_connection(connection, group_id),
         {:ok, bindings} <- ensure_dependent_bindings(tenant_id, group_id, setup, connection) do
      {:ok, %{"connection" => connection, "bindings" => bindings}}
    end
  end

  def prepare(_tenant_id, _group_id, _definition, _connection_id),
    do: {:error, {:bad_request, "plugin setup is limited to system plugins"}}

  defp not_device_client(%{"kind" => "device_client"}),
    do:
      {:error,
       {:bad_request, "Connect this plugin from the Comma desktop app on the Mac it runs on."}}

  defp not_device_client(_connection), do: :ok

  @doc """
  Binds a device_client plugin's MCPs to one member's device runtime, owned by that
  member: creates the binding, or moves an existing one to this device and owner.
  """
  def connect_device(
        tenant_id,
        group_id,
        %{"owner_scope" => "system"} = definition,
        device_runtime_id,
        owner_user_id
      )
      when is_binary(device_runtime_id) and device_runtime_id != "" and
             is_binary(owner_user_id) and owner_user_id != "" do
    with {:ok, setup} <- contract(definition),
         {:ok, _group} <- Groups.get(group_id, tenant_id),
         %{} = connection <- Enum.find(setup.connections, &(&1["kind"] == "device_client")),
         connection =
           Map.merge(connection, %{
             "device_runtime_id" => device_runtime_id,
             "owner_user_id" => owner_user_id
           }),
         {:ok, bindings} <- ensure_dependent_bindings(tenant_id, group_id, setup, connection) do
      {:ok, %{"connection" => connection, "bindings" => bindings}}
    else
      nil -> {:error, {:bad_request, "plugin has no device connection"}}
      {:error, _} = error -> error
    end
  end

  def connect_device(_tenant_id, _group_id, _definition, _device_runtime_id, _owner_user_id),
    do: {:error, {:bad_request, "a device and its owner are required"}}

  defp selected_oauth_connection(%{"id" => "x-managed"} = connection, group_id) do
    case OAuthBindings.select_provider_record(group_id, "x", "x") do
      {:ok, binding} ->
        {:ok, Map.put(connection, "alias", binding["alias"])}

      {:error, :not_found} ->
        {:ok, connection}

      {:error, :ambiguous_oauth_accounts} ->
        {:error,
         {:bad_request,
          "Multiple X accounts are connected. Give the intended account the alias x."}}

      {:error, _} ->
        {:error, {:precondition_failed, "Cannot read the X OAuth connection. Retry the request."}}
    end
  end

  defp selected_oauth_connection(connection, _group_id), do: {:ok, connection}

  defp ensure_dependent_bindings(tenant_id, group_id, setup, connection) do
    setup.mcps
    |> Enum.filter(&(connection["id"] in mcp_auth_refs(&1)))
    |> Enum.reduce_while({:ok, []}, fn mcp, {:ok, bindings} ->
      with {:ok, _definition} <- Store.get_definition(mcp["mcp_id"], tenant_id),
           {:ok, binding} <- ensure_binding(tenant_id, group_id, mcp, connection) do
        {:cont, {:ok, [binding | bindings]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, bindings} -> {:ok, Enum.reverse(bindings)}
      error -> error
    end
  end

  defp ensure_binding(tenant_id, group_id, mcp, connection) do
    bindings = Store.list_group_bindings(tenant_id, group_id, include_disabled: true)
    by_alias = Enum.find(bindings, &(&1["alias"] == mcp["alias"]))
    by_definition = Enum.find(bindings, &(&1["mcp_id"] == mcp["mcp_id"]))

    cond do
      same_mcp?(by_alias, mcp) and mcp["mcp_id"] != "mcp1_0000000000000000009" and
        connection["kind"] == "mcp_api_key" and
          not auth_matches?(by_alias, mcp, connection) ->
        {:error, {:conflict, "MCP binding uses another authentication method"}}

      managed?(by_alias, mcp, connection) ->
        {:ok, by_alias}

      same_mcp?(by_alias, mcp) ->
        Gateway.update_binding(
          tenant_id,
          group_id,
          by_alias["binding_id"],
          binding_attrs(mcp, connection)
        )

      by_alias ->
        {:error, {:conflict, "MCP alias #{mcp["alias"]} is already in use"}}

      by_definition ->
        {:error, {:conflict, "MCP definition is already bound under a different alias"}}

      true ->
        Gateway.create_binding(tenant_id, group_id, binding_attrs(mcp, connection))
    end
  end

  defp binding_attrs(%{"mcp_id" => "mcp1_0000000000000000009"} = mcp, _connection) do
    mcp
    |> Map.take(~w(mcp_id alias target_ref placement config_values))
    |> Map.put("oauth_binding_refs", %{})
  end

  defp binding_attrs(mcp, %{"kind" => "managed_oauth"} = connection) do
    mcp
    |> Map.take(~w(mcp_id alias target_ref placement))
    |> Map.put("oauth_binding_refs", %{
      connection["credential_env_var"] => %{
        "provider" => connection["provider"],
        "alias" => connection["alias"],
        "credential" => "access_token",
        "scopes" => normalize_scopes(connection["scopes"])
      }
    })
  end

  defp binding_attrs(mcp, %{"kind" => "native_mcp_oauth"}) do
    attrs = Map.take(mcp, ~w(mcp_id alias target_ref placement))

    if length(mcp_auth_refs(mcp)) > 1,
      do: attrs,
      else: Map.put(attrs, "oauth_binding_refs", %{})
  end

  defp binding_attrs(mcp, %{"kind" => "mcp_api_key"}) do
    mcp
    |> Map.take(~w(mcp_id alias target_ref placement))
    |> Map.put("oauth_binding_refs", %{})
  end

  defp binding_attrs(mcp, %{"kind" => "device_client"} = connection) do
    mcp
    |> Map.take(~w(mcp_id alias target_ref placement))
    |> Map.merge(%{
      "device_runtime_id" => connection["device_runtime_id"],
      "owner_user_id" => connection["owner_user_id"],
      "oauth_binding_refs" => %{},
      "enabled" => true
    })
  end

  defp managed?(binding, mcp, connection) when is_map(binding) do
    binding["mcp_id"] == mcp["mcp_id"] and binding["target_ref"] == mcp["target_ref"] and
      binding["placement"] == mcp["placement"] and auth_matches?(binding, mcp, connection)
  end

  defp managed?(_binding, _mcp, _connection), do: false

  defp auth_matches?(binding, %{"mcp_id" => "mcp1_0000000000000000009"} = mcp, _connection),
    do:
      binding["oauth_binding_refs"] in [nil, %{}] and
        not Map.has_key?(mcp, "config_values")

  defp auth_matches?(binding, mcp, %{"kind" => "native_mcp_oauth"}) do
    length(mcp_auth_refs(mcp)) > 1 or binding["oauth_binding_refs"] in [nil, %{}]
  end

  defp auth_matches?(binding, _mcp, %{"kind" => "managed_oauth"} = connection) do
    ref = get_in(binding, ["oauth_binding_refs", connection["credential_env_var"]]) || %{}

    ref["provider"] == connection["provider"] and ref["alias"] == connection["alias"] and
      normalize_scopes(ref["scopes"]) == normalize_scopes(connection["scopes"])
  end

  defp auth_matches?(binding, _mcp, %{"kind" => "mcp_api_key"}),
    do:
      binding["oauth_binding_refs"] in [nil, %{}] and
        not present?(binding["remote_oauth_binding_id"])

  defp auth_matches?(binding, _mcp, %{"kind" => "device_client"} = connection),
    do:
      binding["device_runtime_id"] == connection["device_runtime_id"] and
        binding["owner_user_id"] == connection["owner_user_id"] and binding["enabled"] != false

  defp same_mcp?(binding, mcp) when is_map(binding) do
    binding["mcp_id"] == mcp["mcp_id"] and binding["target_ref"] == mcp["target_ref"] and
      binding["placement"] == mcp["placement"]
  end

  defp same_mcp?(_binding, _mcp), do: false

  defp put_status(definition, oauth_bindings, mcp_bindings, im_connects) do
    with {:ok, setup} <- contract(definition) do
      connections =
        Enum.map(setup.connections, fn connection ->
          connection =
            case connection do
              %{"id" => "x-managed"} ->
                case Enum.find(oauth_bindings, &(&1["provider"] == "x")) do
                  nil -> connection
                  oauth -> Map.put(connection, "alias", oauth["alias"])
                end

              _ ->
                connection
            end

          Map.put(
            connection,
            "state",
            connection_state(connection, setup.mcps, oauth_bindings, mcp_bindings, im_connects)
          )
        end)

      mcps =
        Enum.map(setup.mcps, fn mcp ->
          binding =
            Enum.find(
              mcp_bindings,
              &(&1["alias"] == mcp["alias"] or &1["mcp_id"] == mcp["mcp_id"])
            )

          Map.put(
            mcp,
            "state",
            mcp_state(binding, mcp, active_auth_state(binding, mcp, connections))
          )
        end)

      Map.put(definition, "setup_status", %{
        "type" => @setup_type,
        "default_connection" => setup.default_connection,
        "connections" => connections,
        "mcps" => mcps
      })
    else
      _ -> definition
    end
  end

  defp connection_state(
         %{"kind" => "managed_oauth"} = connection,
         _mcps,
         oauth,
         _bindings,
         _im_connects
       ) do
    oauth
    |> Enum.find(
      &(&1["provider"] == connection["provider"] and &1["alias"] == connection["alias"])
    )
    |> oauth_state(connection["scopes"])
  end

  defp connection_state(%{"kind" => "composio"}, _mcps, _oauth, _bindings, _im_connects),
    do: "external"

  defp connection_state(%{"id" => id, "kind" => "mcp_api_key"}, mcps, _oauth, bindings, _) do
    mcp = Enum.find(mcps, &(id in mcp_auth_refs(&1)))
    binding = mcp && Enum.find(bindings, &same_mcp?(&1, mcp))

    cond do
      is_nil(binding) ->
        "not_connected"

      binding["enabled"] == false ->
        "disabled"

      get_in(binding, ["connection", "status"]) == "running" and
          binding["config_configured"] == true ->
        "connected"

      true ->
        "not_connected"
    end
  end

  defp connection_state(
         %{"id" => id, "kind" => "native_mcp_oauth"},
         mcps,
         oauth,
         bindings,
         _im_connects
       ) do
    dependent = Enum.find(mcps, &(id in mcp_auth_refs(&1)))
    binding = dependent && Enum.find(bindings, &(&1["alias"] == dependent["alias"]))

    cond do
      is_nil(binding) ->
        "not_connected"

      binding["enabled"] == false ->
        "disabled"

      present?(binding["remote_oauth_binding_id"]) ->
        oauth
        |> Enum.find(&(&1["binding_id"] == binding["remote_oauth_binding_id"]))
        |> oauth_state([])

      get_in(binding, ["connection", "status"]) == "authorization_pending" ->
        "authorization_pending"

      true ->
        "not_connected"
    end
  end

  defp connection_state(%{"id" => id, "kind" => "device_client"}, mcps, _oauth, bindings, _) do
    mcp = Enum.find(mcps, &(id in mcp_auth_refs(&1)))
    binding = mcp && Enum.find(bindings, &same_mcp?(&1, mcp))

    cond do
      is_nil(binding) or not present?(binding["device_runtime_id"]) -> "not_connected"
      binding["enabled"] == false -> "disabled"
      true -> "connected"
    end
  end

  defp connection_state(
         %{"kind" => "im_connect", "provider" => provider},
         _mcps,
         _oauth,
         _bindings,
         im_connects
       ) do
    provider_connects = Enum.filter(im_connects, &(&1["provider"] == provider))

    cond do
      Enum.any?(provider_connects, &is_nil(&1["disabled_at"])) -> "connected"
      provider_connects != [] -> "disabled"
      true -> "not_connected"
    end
  end

  defp mcp_state(nil, _mcp, _auth), do: "not_configured"

  defp mcp_state(%{"mcp_id" => id}, %{"mcp_id" => expected}, _auth) when id != expected,
    do: "conflict"

  defp mcp_state(%{"alias" => name}, %{"alias" => expected}, _auth) when name != expected,
    do: "conflict"

  defp mcp_state(%{"enabled" => false}, _mcp, _auth), do: "disabled"
  defp mcp_state(_binding, _mcp, auth) when auth != "connected", do: "waiting_for_oauth"

  defp mcp_state(binding, _mcp, "connected") do
    case get_in(binding, ["connection", "status"]) do
      status when status in ~w(running degraded) -> status
      _status -> "ready_on_use"
    end
  end

  defp active_auth_state(nil, _mcp, _connections), do: nil

  defp active_auth_state(_binding, %{"mcp_id" => "mcp1_0000000000000000009"}, connections) do
    oauth = Enum.find(connections, &(&1["id"] == "x-managed"))
    api_key = Enum.find(connections, &(&1["id"] == "x-api-key"))
    if oauth["state"] != "not_connected", do: oauth["state"], else: api_key["state"]
  end

  defp active_auth_state(binding, mcp, connections) do
    refs = binding["oauth_binding_refs"] || %{}

    candidates =
      mcp
      |> mcp_auth_refs()
      |> Enum.map(fn auth_ref -> Enum.find(connections, &(&1["id"] == auth_ref)) end)
      |> Enum.filter(fn
        %{"kind" => "native_mcp_oauth"} ->
          present?(binding["remote_oauth_binding_id"])

        %{"kind" => "managed_oauth"} = connection ->
          ref = refs[connection["credential_env_var"]] || %{}
          ref["provider"] == connection["provider"] and ref["alias"] == connection["alias"]

        %{"kind" => "mcp_api_key"} ->
          binding["config_configured"] == true

        %{"kind" => "device_client"} ->
          present?(binding["device_runtime_id"])

        _connection ->
          false
      end)

    connection = Enum.find(candidates, &(&1["state"] == "connected")) || List.first(candidates)

    connection && connection["state"]
  end

  defp contract(%{"setup" => %{"type" => @setup_type} = raw}) do
    connections = raw["connections"] || []
    mcps = raw["mcps"] || []
    default = raw["default_connection"]

    with :ok <- validate_connections(connections),
         :ok <- validate_mcps(mcps, connections),
         :ok <- validate_required_connections(raw["required_connections"], connections),
         true <- Enum.any?(connections, &(&1["id"] == default)) do
      {:ok, %{connections: connections, mcps: mcps, default_connection: default}}
    else
      false -> {:error, {:bad_request, "plugin default connection is invalid"}}
      {:error, _reason} = error -> error
      _ -> {:error, {:bad_request, "plugin integration setup is incomplete"}}
    end
  end

  defp contract(_definition), do: {:error, :not_configured}

  defp validate_required_connections(nil, _connections), do: :ok

  defp validate_required_connections(ids, connections) when is_list(ids) and ids != [] do
    if Enum.uniq(ids) == ids and
         Enum.all?(ids, fn id -> Enum.any?(connections, &(&1["id"] == id)) end),
       do: :ok,
       else: {:error, {:bad_request, "plugin required connections are invalid"}}
  end

  defp validate_required_connections(_, _),
    do: {:error, {:bad_request, "plugin required connections are invalid"}}

  defp validate_connections(connections) when is_list(connections) and connections != [] do
    ids = Enum.map(connections, & &1["id"])

    valid =
      Enum.all?(connections, fn connection ->
        present?(connection["id"]) and connection["kind"] in @connection_kinds and
          connection_fields_valid?(connection)
      end)

    if valid and Enum.uniq(ids) == ids,
      do: :ok,
      else: {:error, {:bad_request, "plugin connections are invalid"}}
  end

  defp validate_connections(_connections),
    do: {:error, {:bad_request, "plugin connections are invalid"}}

  defp connection_fields_valid?(%{"kind" => "native_mcp_oauth"} = c),
    do: is_list(c["scopes"] || [])

  defp connection_fields_valid?(%{"kind" => "managed_oauth"} = c),
    do:
      present?(c["provider"]) and present?(c["alias"]) and is_list(c["scopes"] || []) and
        (!Map.has_key?(c, "credential_env_var") or present?(c["credential_env_var"]))

  defp connection_fields_valid?(%{"kind" => "composio"} = c), do: present?(c["toolkit"])
  defp connection_fields_valid?(%{"kind" => "im_connect"} = c), do: present?(c["provider"])

  defp connection_fields_valid?(%{"kind" => "mcp_api_key"} = c),
    do: present?(c["config_key"]) and present?(c["credential_label"]) and present?(c["help_url"])

  defp connection_fields_valid?(%{"kind" => "device_client"}), do: true

  defp validate_mcps([], _connections), do: :ok

  defp validate_mcps(mcps, connections) when is_list(mcps) and mcps != [] do
    by_id = Map.new(connections, &{&1["id"], &1})

    valid =
      Enum.all?(mcps, fn mcp ->
        auth_refs = mcp_auth_refs(mcp)
        fields = Enum.all?(~w(mcp_id alias target_ref placement), &present?(mcp[&1]))

        auth =
          auth_refs != [] and Enum.uniq(auth_refs) == auth_refs and
            Enum.all?(auth_refs, fn auth_ref ->
              case by_id[auth_ref] do
                %{"kind" => "native_mcp_oauth"} ->
                  true

                %{"kind" => "mcp_api_key"} ->
                  mcp["placement"] == "server" and
                    (length(auth_refs) == 1 or mcp["mcp_id"] == "mcp1_0000000000000000009")

                %{"kind" => "managed_oauth"} = connection ->
                  present?(connection["credential_env_var"])

                %{"kind" => "device_client"} ->
                  mcp["placement"] == "device" and length(auth_refs) == 1

                _connection ->
                  false
              end
            end)

        fields and auth
      end)

    if valid, do: :ok, else: {:error, {:bad_request, "plugin MCP dependencies are invalid"}}
  end

  defp validate_mcps(_mcps, _connections),
    do: {:error, {:bad_request, "plugin MCP dependencies are invalid"}}

  defp select_connection(setup, connection_id) do
    id = if present?(connection_id), do: connection_id, else: setup.default_connection

    case Enum.find(setup.connections, &(&1["id"] == id)) do
      nil -> {:error, {:bad_request, "plugin connection was not found"}}
      connection -> {:ok, connection}
    end
  end

  defp oauth_state(nil, _required_scopes), do: "not_connected"
  defp oauth_state(%{"enabled" => false}, _required_scopes), do: "disabled"
  defp oauth_state(%{"status" => "unknown"}, _required_scopes), do: "unknown"

  defp oauth_state(%{"status" => "active"} = binding, required_scopes) do
    if scopes_satisfied?(binding["scopes"], required_scopes),
      do: "connected",
      else: "missing_scopes"
  end

  defp oauth_state(_binding, _required_scopes), do: "reauthorization_required"

  defp scopes_satisfied?(granted, required) do
    required
    |> normalize_scopes()
    |> MapSet.new()
    |> MapSet.subset?(MapSet.new(normalize_scopes(granted)))
  end

  defp normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_scopes(_scopes), do: []

  defp mcp_auth_refs(%{"auth_refs" => refs}) when is_list(refs), do: refs

  defp mcp_auth_refs(%{"auth_ref" => ref}), do: if(present?(ref), do: [ref], else: [])
  defp mcp_auth_refs(_mcp), do: []

  defp group_im_connects(group_id) do
    case ProviderConnects.list_group_im_connects(group_id, nil) do
      {:ok, connects} when is_list(connects) -> connects
      _other -> []
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
