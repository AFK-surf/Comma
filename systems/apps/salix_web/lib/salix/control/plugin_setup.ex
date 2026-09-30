defmodule Salix.Control.PluginSetup do
  @moduledoc false

  alias Salix.Control.{Groups, OAuthBindings}
  alias SalixIM.ProviderConnects
  alias SalixMCP.{Gateway, Store}

  @setup_type "integration"
  @connection_kinds ~w(native_mcp_oauth managed_oauth composio im_connect)

  def resolve_statuses(definitions, tenant_id, group_id) do
    if Enum.any?(definitions, &match?({:ok, _setup}, contract(&1))) do
      oauth_bindings = OAuthBindings.list(group_id)
      mcp_bindings = Store.list_group_bindings(tenant_id, group_id, include_disabled: true)
      im_connects = group_im_connects(group_id)
      Enum.map(definitions, &put_status(&1, oauth_bindings, mcp_bindings, im_connects))
    else
      definitions
    end
  end

  def prepare(tenant_id, group_id, definition, connection_id \\ nil)

  def prepare(tenant_id, group_id, %{"owner_scope" => "system"} = definition, connection_id) do
    with {:ok, setup} <- contract(definition),
         {:ok, _group} <- Groups.get(group_id, tenant_id),
         {:ok, connection} <- select_connection(setup, connection_id),
         {:ok, bindings} <- ensure_dependent_bindings(tenant_id, group_id, setup, connection) do
      {:ok, %{"connection" => connection, "bindings" => bindings}}
    end
  end

  def prepare(_tenant_id, _group_id, _definition, _connection_id),
    do: {:error, {:bad_request, "plugin setup is limited to system plugins"}}

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

  defp managed?(binding, mcp, connection) when is_map(binding) do
    binding["mcp_id"] == mcp["mcp_id"] and binding["target_ref"] == mcp["target_ref"] and
      binding["placement"] == mcp["placement"] and auth_matches?(binding, mcp, connection)
  end

  defp managed?(_binding, _mcp, _connection), do: false

  defp auth_matches?(binding, mcp, %{"kind" => "native_mcp_oauth"}) do
    length(mcp_auth_refs(mcp)) > 1 or binding["oauth_binding_refs"] in [nil, %{}]
  end

  defp auth_matches?(binding, _mcp, %{"kind" => "managed_oauth"} = connection) do
    ref = get_in(binding, ["oauth_binding_refs", connection["credential_env_var"]]) || %{}

    ref["provider"] == connection["provider"] and ref["alias"] == connection["alias"] and
      normalize_scopes(ref["scopes"]) == normalize_scopes(connection["scopes"])
  end

  defp same_mcp?(binding, mcp) when is_map(binding) do
    binding["mcp_id"] == mcp["mcp_id"] and binding["target_ref"] == mcp["target_ref"] and
      binding["placement"] == mcp["placement"]
  end

  defp same_mcp?(_binding, _mcp), do: false

  defp put_status(definition, oauth_bindings, mcp_bindings, im_connects) do
    with {:ok, setup} <- contract(definition) do
      connections =
        Enum.map(setup.connections, fn connection ->
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

                %{"kind" => "managed_oauth"} = connection ->
                  present?(connection["credential_env_var"])

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
