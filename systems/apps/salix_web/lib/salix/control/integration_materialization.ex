defmodule Salix.Control.IntegrationMaterialization do
  @moduledoc """
  Materializes third-party integration credentials for an agent group.

  The HTTP contract is provider-neutral and group-scoped. Provider-specific IM
  validation remains in the owning IM adapter; OAuth credentials are persisted
  through the normal OAuth store and optionally wired into a system plugin's
  managed or native MCP connection.
  """

  alias Salix.Control.{
    Groups,
    IntegrationMaterializationLifecycle,
    OAuthBindings,
    Plugins,
    Store
  }

  alias SalixIM.SlackMaterialization
  alias SalixMCP.Gateway, as: MCPGateway
  alias SalixStore.{Crypto, Keys, OAuth, S3}

  @token_fields ~w(access_token refresh_token expires_at refresh_expires_at token_type)

  def materialize(tenant_id, group_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    with {:ok, _group} <- Groups.get(group_id, tenant_id),
         {:ok, materialization_kind} <-
           infer_materialization_kind(tenant_id, group_id, attrs) do
      case materialization_kind do
        "im_connect" ->
          materialize_im_connect(tenant_id, group_id, attrs)

        "managed_oauth" ->
          materialize_oauth_with_lifecycle(
            tenant_id,
            group_id,
            materialization_kind,
            attrs,
            fn -> materialize_managed_oauth(tenant_id, group_id, attrs) end
          )

        "remote_mcp_oauth" ->
          materialize_oauth_with_lifecycle(
            tenant_id,
            group_id,
            materialization_kind,
            attrs,
            fn -> materialize_remote_mcp_oauth(tenant_id, group_id, attrs) end
          )
      end
    end
  rescue
    error in ArgumentError -> {:error, {:bad_request, Exception.message(error)}}
  end

  def materialize(_tenant_id, _group_id, _attrs),
    do: {:error, {:bad_request, "invalid request body"}}

  defp materialize_oauth_with_lifecycle(
         tenant_id,
         group_id,
         materialization_kind,
         attrs,
         operation
       ) do
    integration_id = required_text(attrs, "integration_id")
    alias_name = required_text(attrs, "alias")

    identity =
      case materialization_kind do
        "managed_oauth" ->
          %{
            "kind" => materialization_kind,
            "provider" => provider(attrs),
            "alias" => alias_name
          }

        "remote_mcp_oauth" ->
          %{
            "kind" => materialization_kind,
            "provider_key" =>
              nonblank(
                attrs["provider_key"],
                "materialized:" <> provider(attrs) <> ":" <> integration_id
              ),
            "alias" => alias_name
          }
      end

    IntegrationMaterializationLifecycle.run(
      tenant_id,
      group_id,
      identity,
      integration_id,
      operation
    )
  end

  defp infer_materialization_kind(tenant_id, group_id, attrs) do
    case map(attrs["credentials"])["type"] do
      "app" ->
        {:ok, "im_connect"}

      "oauth" ->
        infer_oauth_materialization_kind(tenant_id, group_id, attrs["plugin"])

      _ ->
        {:error, {:bad_request, "integration credentials type must be app or oauth"}}
    end
  end

  defp infer_oauth_materialization_kind(_tenant_id, _group_id, nil),
    do: {:ok, "managed_oauth"}

  defp infer_oauth_materialization_kind(tenant_id, group_id, raw_plugin) do
    plugin = map(raw_plugin)
    plugin_id = required_text(plugin, "plugin_id")
    connection_id = required_text(plugin, "connection_id")

    with {:ok, definition} <- Plugins.get_definition(tenant_id, group_id, plugin_id),
         {:ok, connection} <- find_setup_connection(definition, connection_id) do
      case connection["kind"] do
        "managed_oauth" -> {:ok, "managed_oauth"}
        "native_mcp_oauth" -> {:ok, "remote_mcp_oauth"}
        _ -> {:error, {:bad_request, "plugin connection does not accept OAuth credentials"}}
      end
    end
  end

  defp materialize_im_connect(tenant_id, group_id, attrs) do
    provider = provider(attrs)

    case provider do
      "slack" ->
        credentials = map(attrs["credentials"])

        slack_attrs =
          credentials
          |> Map.put("inbound_agent_id", text(attrs["inbound_agent_id"]))

        with {:ok, connect} <-
               SlackMaterialization.materialize(tenant_id, group_id, slack_attrs) do
          {:ok,
           %{
             "materialization_id" => "im_connect:" <> connect["connect_id"],
             "materialization_kind" => "im_connect",
             "provider" => provider,
             "resources" => %{"im_connect" => connect}
           }}
        end

      _ ->
        {:error, {:bad_request, "unsupported IM integration provider: #{provider}"}}
    end
  end

  defp materialize_managed_oauth(tenant_id, group_id, attrs) do
    provider = provider(attrs)
    alias_name = required_text(attrs, "alias")
    integration_id = required_text(attrs, "integration_id")
    credentials = map(attrs["credentials"])
    scopes = scopes(attrs["scopes"])

    with :ok <- require_access_token(credentials),
         {:ok, _adapter} <- supported_oauth_provider(provider),
         {:ok, plugin} <-
           validate_plugin_connection(
             tenant_id,
             group_id,
             attrs["plugin"],
             "managed_oauth",
             provider,
             alias_name,
             scopes
           ),
         existing <- find_managed_oauth_binding(group_id, provider, alias_name),
         :ok <- require_materialization_owner(existing, integration_id) do
      case put_managed_oauth(
             tenant_id,
             group_id,
             integration_id,
             provider,
             alias_name,
             credentials,
             scopes,
             map(attrs["account"])
           ) do
        {:ok, binding, connection_id, created} ->
          case prepare_plugin(tenant_id, group_id, plugin) do
            {:ok, preparation} ->
              {:ok,
               oauth_result(
                 "managed_oauth",
                 provider,
                 binding,
                 connection_id,
                 preparation.bindings
               )}

            {:error, reason} ->
              case rollback_materialized_oauth(group_id, binding, connection_id, created) do
                :ok -> {:error, reason}
                {:error, rollback_reason} -> rollback_failed(reason, rollback_reason)
              end
          end

        error ->
          error
      end
    end
  rescue
    error in ArgumentError -> {:error, {:bad_request, Exception.message(error)}}
  end

  defp materialize_remote_mcp_oauth(tenant_id, group_id, attrs) do
    provider = provider(attrs)
    alias_name = required_text(attrs, "alias")
    integration_id = required_text(attrs, "integration_id")
    credentials = map(attrs["credentials"])
    scopes = scopes(attrs["scopes"])

    provider_key =
      nonblank(
        attrs["provider_key"],
        "materialized:" <> provider <> ":" <> integration_id
      )

    with :ok <- require_access_token(credentials),
         {:ok, plugin} <-
           validate_plugin_connection(
             tenant_id,
             group_id,
             attrs["plugin"],
             "native_mcp_oauth",
             provider,
             alias_name,
             scopes
           ),
         existing <- find_remote_mcp_oauth_binding(group_id, provider_key, alias_name),
         :ok <- require_materialization_owner(existing, integration_id),
         {:ok, preparation} <- prepare_plugin(tenant_id, group_id, plugin) do
      case require_mcp_bindings(preparation.bindings) do
        :ok ->
          materialize_remote_mcp_oauth(
            tenant_id,
            group_id,
            integration_id,
            provider,
            provider_key,
            alias_name,
            credentials,
            scopes,
            map(attrs["account"]),
            preparation
          )

        {:error, reason} ->
          case rollback_plugin_preparation(tenant_id, group_id, preparation) do
            :ok -> {:error, reason}
            {:error, rollback_reason} -> rollback_failed(reason, rollback_reason)
          end
      end
    end
  rescue
    error in ArgumentError -> {:error, {:bad_request, Exception.message(error)}}
  end

  defp materialize_remote_mcp_oauth(
         tenant_id,
         group_id,
         integration_id,
         provider,
         provider_key,
         alias_name,
         credentials,
         scopes,
         account,
         preparation
       ) do
    case put_remote_mcp_oauth(
           tenant_id,
           group_id,
           integration_id,
           provider,
           provider_key,
           alias_name,
           credentials,
           scopes,
           account,
           preparation.bindings
         ) do
      {:ok, binding, connection_id, created} ->
        case bind_remote_mcp_oauth(
               tenant_id,
               group_id,
               preparation.bindings,
               binding["binding_id"]
             ) do
          {:ok, bound_mcp_bindings} ->
            {:ok,
             oauth_result(
               "remote_mcp_oauth",
               provider,
               binding,
               connection_id,
               bound_mcp_bindings
             )}

          {:error, reason} ->
            compensate_oauth_and_plugin(
              tenant_id,
              group_id,
              binding,
              connection_id,
              created,
              preparation,
              reason
            )
        end

      {:error, reason} ->
        case rollback_plugin_preparation(tenant_id, group_id, preparation) do
          :ok -> {:error, reason}
          {:error, rollback_reason} -> rollback_failed(reason, rollback_reason)
        end
    end
  end

  defp validate_plugin_connection(
         _tenant_id,
         _group_id,
         nil,
         "managed_oauth",
         _provider,
         _alias_name,
         _scopes
       ),
       do: {:ok, nil}

  defp validate_plugin_connection(
         _tenant_id,
         _group_id,
         nil,
         _kind,
         _provider,
         _alias_name,
         _scopes
       ),
       do: {:error, {:bad_request, "plugin is required for remote MCP OAuth"}}

  defp validate_plugin_connection(
         tenant_id,
         group_id,
         raw_plugin,
         expected_kind,
         provider,
         alias_name,
         granted_scopes
       ) do
    plugin = map(raw_plugin)
    plugin_id = required_text(plugin, "plugin_id")
    connection_id = required_text(plugin, "connection_id")

    with {:ok, definition} <- Plugins.get_definition(tenant_id, group_id, plugin_id),
         {:ok, connection} <- find_setup_connection(definition, connection_id),
         :ok <- require_connection_kind(connection, expected_kind),
         :ok <- require_managed_identity(connection, expected_kind, provider, alias_name),
         :ok <- require_scopes(granted_scopes, scopes(connection["scopes"])) do
      {:ok, %{"plugin_id" => plugin_id, "connection_id" => connection_id}}
    end
  end

  defp find_setup_connection(definition, connection_id) do
    connections = get_in(definition, ["setup", "connections"]) || []

    case Enum.find(connections, &(&1["id"] == connection_id)) do
      nil -> {:error, {:bad_request, "plugin connection was not found"}}
      connection -> {:ok, connection}
    end
  end

  defp require_connection_kind(%{"kind" => expected}, expected), do: :ok

  defp require_connection_kind(_connection, expected),
    do: {:error, {:bad_request, "plugin connection must use #{expected}"}}

  defp require_managed_identity(connection, "managed_oauth", provider, alias_name) do
    if connection["provider"] == provider and connection["alias"] == alias_name do
      :ok
    else
      {:error, {:bad_request, "plugin connection OAuth identity does not match request"}}
    end
  end

  defp require_managed_identity(_connection, _kind, _provider, _alias_name), do: :ok

  defp require_scopes(granted, required) do
    if MapSet.subset?(MapSet.new(required), MapSet.new(granted)) do
      :ok
    else
      {:error, {:bad_request, "materialized OAuth credential is missing plugin scopes"}}
    end
  end

  defp prepare_plugin(_tenant_id, _group_id, nil),
    do:
      {:ok,
       %{
         bindings: [],
         created_binding_ids: [],
         enablement_changed: false,
         previous_enablement: nil,
         plugin: nil
       }}

  defp prepare_plugin(tenant_id, group_id, plugin) do
    {:ok, enablements} = Plugins.list_group_enablements(tenant_id, group_id)

    previous_enablement =
      Enum.find(enablements, &(&1["plugin_id"] == plugin["plugin_id"]))

    previous_binding_ids =
      tenant_id
      |> SalixMCP.Store.list_group_bindings(group_id, include_disabled: true)
      |> MapSet.new(& &1["binding_id"])

    result =
      Plugins.prepare_group_setup(
        tenant_id,
        group_id,
        plugin["plugin_id"],
        plugin["connection_id"]
      )

    current_binding_ids =
      tenant_id
      |> SalixMCP.Store.list_group_bindings(group_id, include_disabled: true)
      |> Enum.map(& &1["binding_id"])

    preparation = %{
      bindings:
        if(match?({:ok, %{"bindings" => _}}, result),
          do: elem(result, 1)["bindings"],
          else: []
        ),
      created_binding_ids:
        Enum.reject(current_binding_ids, &MapSet.member?(previous_binding_ids, &1)),
      enablement_changed: false,
      previous_enablement: previous_enablement,
      plugin: plugin
    }

    case result do
      {:ok, %{"bindings" => _bindings}} ->
        if previous_enablement && previous_enablement["enabled"] == true do
          {:ok, preparation}
        else
          case Plugins.enable_group(tenant_id, group_id, plugin["plugin_id"]) do
            {:ok, _enablement} ->
              {:ok, %{preparation | enablement_changed: true}}

            {:error, reason} ->
              case rollback_plugin_preparation(tenant_id, group_id, preparation) do
                :ok -> {:error, reason}
                {:error, rollback_reason} -> rollback_failed(reason, rollback_reason)
              end
          end
        end

      {:error, reason} ->
        case rollback_plugin_preparation(tenant_id, group_id, preparation) do
          :ok -> {:error, reason}
          {:error, rollback_reason} -> rollback_failed(reason, rollback_reason)
        end
    end
  end

  defp put_managed_oauth(
         tenant_id,
         group_id,
         integration_id,
         provider,
         alias_name,
         credentials,
         scopes,
         account
       ) do
    existing = find_managed_oauth_binding(group_id, provider, alias_name)

    if existing do
      with :ok <- require_materialization_owner(existing, integration_id) do
        {:ok, existing, existing["connection_id"], false}
      end
    else
      connection_id =
        "conn-" <>
          String.slice(
            Crypto.hex(Jason.encode!([group_id, integration_id, provider, alias_name])),
            0,
            32
          )

      record =
        oauth_connection_record(
          tenant_id,
          integration_id,
          provider,
          connection_id,
          credentials,
          scopes,
          account
        )

      with :ok <- OAuth.put(connection_id, record),
           {:ok, binding, created} <-
             OAuthBindings.put_materialized(
               tenant_id,
               group_id,
               provider,
               alias_name,
               connection_id,
               integration_id
             ) do
        {:ok, binding, connection_id, created}
      else
        error ->
          _ = delete_connection(connection_id)
          error
      end
    end
  end

  defp put_remote_mcp_oauth(
         tenant_id,
         group_id,
         integration_id,
         provider,
         provider_key,
         alias_name,
         credentials,
         scopes,
         account,
         [first_binding | _]
       ) do
    existing = find_remote_mcp_oauth_binding(group_id, provider_key, alias_name)

    if existing do
      with :ok <- require_materialization_owner(existing, integration_id) do
        {:ok, existing, existing["connection_id"], false}
      end
    else
      connection_id =
        "conn-" <>
          String.slice(
            Crypto.hex(Jason.encode!([group_id, integration_id, provider_key, alias_name])),
            0,
            32
          )

      record =
        oauth_connection_record(
          tenant_id,
          integration_id,
          "remote_mcp",
          connection_id,
          credentials,
          scopes,
          account
        )
        |> Map.put("provider_kind", "remote_mcp")
        |> Map.put("provider_key", provider_key)
        |> Map.update!("metadata", fn metadata ->
          metadata
          |> Map.put("logical_provider", provider)
          |> Map.put("mcp_definition_id", first_binding["mcp_id"])
          |> Map.put("mcp_binding_id", first_binding["binding_id"])
          |> Map.put("target_ref", first_binding["target_ref"])
        end)

      binding_metadata = %{
        "logical_provider" => provider,
        "mcp_definition_id" => first_binding["mcp_id"],
        "mcp_binding_id" => first_binding["binding_id"]
      }

      with :ok <- OAuth.put(connection_id, record),
           {:ok, binding, created} <-
             OAuthBindings.put_materialized_remote_mcp(
               tenant_id,
               group_id,
               provider_key,
               alias_name,
               connection_id,
               integration_id,
               binding_metadata
             ) do
        {:ok, binding, connection_id, created}
      else
        error ->
          _ = delete_connection(connection_id)
          error
      end
    end
  end

  defp bind_remote_mcp_oauth(tenant_id, group_id, bindings, oauth_binding_id) do
    Enum.reduce_while(bindings, {:ok, []}, fn binding, {:ok, bound} ->
      case SalixMCP.Store.set_remote_oauth_binding(
             tenant_id,
             group_id,
             binding["binding_id"],
             oauth_binding_id
           ) do
        {:ok, updated} ->
          case MCPGateway.refresh_binding(tenant_id, group_id, binding["binding_id"]) do
            {:ok, %{"status" => "running"}} ->
              {:cont, {:ok, [updated | bound]}}

            {:ok, connection} ->
              {:halt,
               {:error,
                {:provider,
                 "MCP binding #{binding["binding_id"]} did not become runnable: #{connection["status"] || "unknown"}"}}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, bindings} -> {:ok, Enum.reverse(bindings)}
      error -> error
    end
  end

  defp find_managed_oauth_binding(group_id, provider, alias_name) do
    group_id
    |> OAuthBindings.list_records()
    |> Enum.find(&(&1["provider"] == provider and &1["alias"] == alias_name))
  end

  defp find_remote_mcp_oauth_binding(group_id, provider_key, alias_name) do
    group_id
    |> OAuthBindings.list_records()
    |> Enum.find(
      &(&1["provider_kind"] == "remote_mcp" and &1["provider_key"] == provider_key and
          &1["alias"] == alias_name)
    )
  end

  defp require_materialization_owner(nil, _integration_id), do: :ok

  defp require_materialization_owner(binding, integration_id) do
    with connection_id when is_binary(connection_id) and connection_id != "" <-
           binding["connection_id"],
         {:ok, connection} <- OAuth.get(connection_id),
         %{"integration_materialized" => true, "integration_id" => ^integration_id} <-
           connection["metadata"] do
      :ok
    else
      _ ->
        {:error, {:conflict, "OAuth provider and alias are already owned by another connection"}}
    end
  end

  defp compensate_oauth_and_plugin(
         tenant_id,
         group_id,
         binding,
         connection_id,
         created,
         preparation,
         reason
       ) do
    oauth_result = rollback_materialized_oauth(group_id, binding, connection_id, created)

    plugin_result = rollback_plugin_preparation(tenant_id, group_id, preparation)

    case Enum.reject([oauth_result, plugin_result], &(&1 == :ok)) do
      [] -> {:error, reason}
      rollback_errors -> rollback_failed(reason, rollback_errors)
    end
  end

  defp rollback_materialized_oauth(_group_id, _binding, _connection_id, false), do: :ok

  defp rollback_materialized_oauth(group_id, binding, connection_id, true) do
    with :ok <- OAuthBindings.delete(group_id, binding["binding_id"]),
         result when result in [:ok, {:error, :not_found}] <- delete_connection(connection_id) do
      :ok
    else
      {:error, rollback_reason} -> {:error, rollback_reason}
      other -> {:error, other}
    end
  end

  defp rollback_plugin_preparation(_tenant_id, _group_id, %{plugin: nil}), do: :ok

  defp rollback_plugin_preparation(tenant_id, group_id, preparation) do
    binding_results =
      Enum.map(preparation.created_binding_ids, fn binding_id ->
        MCPGateway.delete_binding(tenant_id, group_id, binding_id)
      end)

    enablement_result =
      case {preparation.enablement_changed, preparation.previous_enablement} do
        {false, _previous} ->
          :ok

        {true, nil} ->
          Plugins.clear_group_enablement(
            tenant_id,
            group_id,
            preparation.plugin["plugin_id"]
          )

        {true, %{"enabled" => true}} ->
          case Plugins.enable_group(tenant_id, group_id, preparation.plugin["plugin_id"]) do
            {:ok, _enablement} -> :ok
            error -> error
          end

        {true, %{"enabled" => false}} ->
          case Plugins.disable_group(tenant_id, group_id, preparation.plugin["plugin_id"]) do
            {:ok, _enablement} -> :ok
            error -> error
          end
      end

    case Enum.reject(binding_results ++ [enablement_result], &(&1 == :ok)) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp rollback_failed(reason, rollback_reason) do
    {:error,
     {:provider,
      "integration materialization failed (#{inspect(reason)}) and compensation failed: #{inspect(rollback_reason)}"}}
  end

  defp oauth_connection_record(
         tenant_id,
         integration_id,
         provider,
         connection_id,
         credentials,
         scopes,
         account
       ) do
    now = Store.now()

    credentials
    |> Map.take(@token_fields)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
    |> Map.merge(%{
      "connection_id" => connection_id,
      "tenant" => tenant_id,
      "provider" => provider,
      "provider_account_id" => text(account["provider_account_id"]),
      "provider_account_name" => text(account["provider_account_name"]),
      "scopes" => scopes,
      "metadata" => %{
        "integration_materialized" => true,
        "integration_id" => integration_id
      },
      "status" => "active",
      "created_at" => now,
      "updated_at" => now
    })
  end

  defp oauth_result(materialization_kind, provider, binding, connection_id, mcp_bindings) do
    %{
      "materialization_id" => materialization_kind <> ":" <> binding["binding_id"],
      "materialization_kind" => materialization_kind,
      "provider" => provider,
      "resources" => %{
        "oauth_binding" => %{
          "binding_id" => binding["binding_id"],
          "connection_id" => connection_id,
          "alias" => binding["alias"]
        },
        "mcp_bindings" => mcp_bindings
      }
    }
  end

  defp supported_oauth_provider(provider) do
    case SalixStore.OAuth.Adapters.for_provider(provider) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, _} -> {:error, {:bad_request, "unsupported OAuth provider: #{provider}"}}
    end
  end

  defp require_access_token(credentials) do
    if text(credentials["access_token"]) == "" do
      {:error, {:bad_request, "credentials.access_token is required"}}
    else
      :ok
    end
  end

  defp require_mcp_bindings([]),
    do: {:error, {:bad_request, "plugin has no MCP binding"}}

  defp require_mcp_bindings(_bindings), do: :ok

  defp delete_connection(connection_id), do: S3.delete(Keys.oauth_connection(connection_id))

  defp provider(attrs) do
    case attrs |> Map.get("provider") |> text() |> String.downcase() do
      "" -> raise ArgumentError, "provider is required"
      provider -> provider
    end
  end

  defp required_text(map, key) do
    case map |> Map.get(key) |> text() do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp nonblank(value, fallback) do
    case text(value) do
      "" -> fallback
      value -> value
    end
  end

  defp scopes(value) when is_list(value) do
    value |> Enum.map(&text/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp scopes(_value), do: []
  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
