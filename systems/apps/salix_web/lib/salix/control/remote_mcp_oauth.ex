defmodule Salix.Control.RemoteMCPOAuth do
  @moduledoc false

  require Logger

  alias Salix.Control.{OAuthApps, OAuthBindings, Store}
  alias SalixMCP.{Config, RemoteClient, RemoteOAuth}
  alias SalixStore.{Keys, OAuth, S3}
  alias SalixStore.OAuth.AuthState

  @auth_state_ttl_ms 600_000
  @refresh_leeway_ms 60_000
  @provider "mcp"
  @provider_kind "remote_mcp"

  def start_authorization(tenant_id, group_id, binding_id, params \\ %{}) do
    params = if is_map(params), do: stringify(params), else: %{}

    with {:ok, binding, definition, _connection} <-
           SalixMCP.Store.get_binding_with_definition(tenant_id, group_id, binding_id),
         :ok <- ensure_remote_binding(definition, binding),
         {:ok, config} <- remote_config(definition, binding),
         {:ok, identity} <- discover_identity(definition, binding, config) do
      start_authorization_with_identity(tenant_id, group_id, binding, identity, params)
    else
      {:error, {:bad_request, _message}} = err -> err
      {:error, {:precondition_failed, _message}} = err -> err
      {:error, {:missing_oauth_client, _message}} = err -> err
      {:error, reason} -> internal_error("start remote MCP OAuth", reason)
    end
  end

  def disconnect(tenant_id, group_id, mcp_binding_id) do
    with {:ok, mcp_binding, _definition, _connection} <-
           SalixMCP.Store.get_binding_with_definition(tenant_id, group_id, mcp_binding_id) do
      case string(mcp_binding["remote_oauth_binding_id"]) do
        "" ->
          reset_mcp_connection(mcp_binding)

        oauth_binding_id ->
          with {:ok, oauth_binding} <- OAuthBindings.get(group_id, oauth_binding_id),
               :ok <- ensure_oauth_binding_scope(oauth_binding, tenant_id, group_id),
               {:ok, cleared_binding} <-
                 SalixMCP.Store.set_remote_oauth_binding(
                   tenant_id,
                   group_id,
                   mcp_binding_id,
                   ""
                 ),
               :ok <- OAuthBindings.delete(group_id, oauth_binding_id),
               :ok <- reset_mcp_connection(cleared_binding) do
            _ =
              revoke_connection_if_unreferenced(
                tenant_id,
                oauth_binding["connection_id"],
                oauth_binding_id
              )

            :ok
          end
      end
    end
  end

  defp start_authorization_with_identity(tenant_id, group_id, binding, identity, params) do
    case client_for_authorization(tenant_id, identity) do
      {:ok, client} ->
        with {:ok, auth} <-
               create_auth_state(tenant_id, group_id, binding, identity, client, params),
             :ok <- mark_authorization_pending(binding, identity, auth) do
          {:ok,
           %{
             "authorization_url" => auth.authorization_url,
             "state" => auth.state,
             "provider" => @provider,
             "provider_kind" => @provider_kind,
             "provider_key" => identity["provider_key"],
             "mcp_binding_id" => binding["binding_id"]
           }}
        end

      {:error, {:missing_oauth_client, message}} ->
        _ = mark_missing_oauth_client(binding, identity, message)
        {:error, {:missing_oauth_client, message}}

      {:error, {:bad_request, _message}} = err ->
        err

      {:error, {:precondition_failed, _message}} = err ->
        err

      {:error, reason} ->
        internal_error("start remote MCP OAuth with identity", reason)
    end
  end

  def handle_callback(query) do
    query = if is_map(query), do: stringify(query), else: %{}
    state_id = string(query["state"])

    cond do
      state_id == "" ->
        finish(nil, "missing state")

      string(query["error"]) != "" ->
        with {:ok, auth} <- consume_state(state_id) do
          finish(auth, "authorization denied: " <> string(query["error"]))
        else
          {:error, reason} -> finish(nil, callback_state_error(reason))
        end

      string(query["code"]) == "" ->
        with {:ok, auth} <- consume_state(state_id) do
          finish(auth, "missing code")
        else
          {:error, reason} -> finish(nil, callback_state_error(reason))
        end

      true ->
        with {:ok, auth} <- consume_state(state_id),
             :ok <- ensure_remote_auth_state(auth),
             :ok <- ensure_auth_binding_current(auth),
             {:ok, client} <- client_for_state(auth),
             {:ok, token} <- exchange_code(auth, client, query["code"]),
             {:ok, completion} <- guarded_persist_authorization(auth, client, token) do
          finish(auth, nil, completion)
        else
          {:error, {state, reason}} when is_map(state) ->
            finish(state, format_reason(reason))

          {:error, reason} ->
            finish(nil, format_reason(reason))
        end
    end
  end

  defp guarded_persist_authorization(auth, client, token) do
    case SalixWeb.OAuthCommitGuard.run(auth, fn -> persist_authorization(auth, client, token) end) do
      {:error, reason} when is_binary(reason) -> {:error, {auth, reason}}
      other -> other
    end
  end

  def resolve_headers(%{"remote_oauth_binding_id" => binding_id} = mcp_binding)
      when is_binary(binding_id) and binding_id != "" do
    tenant_id = string(mcp_binding["tenant_id"])
    group_id = string(mcp_binding["group_id"])

    with {:ok, binding} <- OAuthBindings.get(group_id, binding_id),
         :ok <- ensure_oauth_binding_scope(binding, tenant_id, group_id),
         :ok <- ensure_oauth_binding_enabled(binding),
         {:ok, connection_id} <- oauth_connection_id(binding),
         {:ok, token} <- valid_remote_token(tenant_id, connection_id) do
      {:ok, %{"authorization" => "Bearer " <> token}}
    else
      {:error, :not_found} ->
        {:error, {:missing_oauth, "remote MCP OAuth binding is not connected"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def resolve_headers(_mcp_binding), do: {:ok, %{}}

  def redaction_values(%{"remote_oauth_binding_id" => binding_id} = mcp_binding)
      when is_binary(binding_id) and binding_id != "" do
    tenant_id = string(mcp_binding["tenant_id"])
    group_id = string(mcp_binding["group_id"])

    with {:ok, binding} <- OAuthBindings.get(group_id, binding_id),
         {:ok, connection_id} <- oauth_connection_id(binding),
         {:ok, conn} <- OAuth.get(connection_id) do
      client =
        case client_for_connection(tenant_id, conn) do
          {:ok, client} -> client
          _ -> %{}
        end

      [
        conn["access_token"],
        conn["refresh_token"],
        get_in(conn, ["metadata", "client_secret"]),
        client["client_secret"],
        client["registration_access_token"]
      ]
      |> Enum.map(&string/1)
      |> Enum.reject(&(&1 == ""))
    else
      _ -> []
    end
  end

  def redaction_values(_mcp_binding), do: []

  def invalidate_binding_ref(%{"remote_oauth_binding_id" => binding_id} = mcp_binding, reason)
      when is_binary(binding_id) and binding_id != "" do
    tenant_id = string(mcp_binding["tenant_id"])
    group_id = string(mcp_binding["group_id"])

    with {:ok, binding} <- OAuthBindings.get(group_id, binding_id),
         :ok <- ensure_oauth_binding_scope(binding, tenant_id, group_id),
         {:ok, binding} <- OAuthBindings.disable_remote_mcp(group_id, binding_id, reason),
         :ok <-
           revoke_connection_if_unreferenced(
             tenant_id,
             binding["connection_id"],
             binding["binding_id"]
           ) do
      :ok
    else
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def invalidate_binding_ref(_mcp_binding, _reason), do: :ok

  def mark_binding_reauthorization_required(
        %{"remote_oauth_binding_id" => binding_id} = mcp_binding,
        _reason
      )
      when is_binary(binding_id) and binding_id != "" do
    tenant_id = string(mcp_binding["tenant_id"])
    group_id = string(mcp_binding["group_id"])

    with {:ok, binding} <- OAuthBindings.get(group_id, binding_id),
         :ok <- ensure_oauth_binding_scope(binding, tenant_id, group_id),
         {:ok, connection_id} <- oauth_connection_id(binding) do
      mark_reauthorization_required(connection_id)
      :ok
    else
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_binding_reauthorization_required(_mcp_binding, _reason), do: :ok

  def list_provider_apps(tenant_id), do: OAuthApps.list_remote_mcp(tenant_id)

  def put_provider_app(tenant_id, provider_key, attrs),
    do: OAuthApps.put_remote_mcp(tenant_id, provider_key, attrs)

  def delete_provider_app(tenant_id, provider_key),
    do: OAuthApps.delete_remote_mcp(tenant_id, provider_key)

  # ---- discovery / authorization setup ----

  defp ensure_remote_binding(definition, binding) do
    with {:ok, entry} <- SalixMCP.Store.target_entry(definition, binding) do
      if Config.entry_kind(entry) == :remote do
        :ok
      else
        {:error, {:bad_request, "MCP binding target is not remote"}}
      end
    end
  end

  defp remote_config(definition, binding) do
    with {:ok, entry} <- SalixMCP.Store.target_entry(definition, binding) do
      entry
      |> Map.update("headers_schema", %{}, fn headers ->
        Map.reject(headers, fn {name, _spec} ->
          String.downcase(to_string(name)) == "authorization"
        end)
      end)
      |> Config.resolve_entry(binding)
    end
  end

  defp discover_identity(definition, binding, %{"url" => url} = config) do
    if SalixWeb.LocalOAuthMock.enabled?() do
      SalixWeb.LocalOAuthMock.remote_identity(definition, binding, config)
    else
      with {:ok, protected_metadata, protected_url, challenge} <-
             discover_protected_resource(config),
           :ok <- ensure_protected_resource_matches(protected_metadata, url),
           {:ok, authorization_issuer} <- authorization_issuer(protected_metadata),
           {:ok, authorization_metadata, authorization_metadata_url} <-
             discover_authorization_server(authorization_issuer),
           :ok <- require_authorization_metadata(authorization_metadata) do
        oauth_resource = string(protected_metadata["resource"])
        resource_server_url = if(oauth_resource == "", do: string(url), else: oauth_resource)

        identity =
          %{
            "provider_kind" => @provider_kind,
            "resource_server_url" => resource_server_url,
            "oauth_resource" => oauth_resource,
            "authorization_issuer" => authorization_issuer,
            "authorization_server_metadata_url" => authorization_metadata_url,
            "protected_resource_metadata_url" => protected_url,
            "mcp_definition_id" => definition["mcp_id"],
            "mcp_binding_id" => binding["binding_id"],
            "target_ref" => binding["target_ref"],
            "scope" => authorization_scope(challenge, protected_metadata),
            "protected_resource_metadata" => public_metadata(protected_metadata),
            "authorization_server_metadata" =>
              public_authorization_metadata(authorization_metadata)
          }

        {:ok, Map.put(identity, "provider_key", provider_key(identity))}
      end
    end
  end

  defp discover_protected_resource(config) do
    challenge = probe_challenge(config)

    candidates =
      [
        challenge["resource_metadata_url"]
        | RemoteOAuth.protected_resource_metadata_urls(config["url"])
      ]
      |> Enum.map(&string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case fetch_first_json(candidates, "MCP protected resource metadata") do
      {:ok, metadata, url} -> {:ok, metadata, url, challenge}
      {:error, reason} -> {:error, {:bad_request, format_reason(reason)}}
    end
  end

  defp probe_challenge(config) do
    case RemoteClient.initialize(config) do
      {:error, reason} ->
        RemoteOAuth.challenge_from_http_error(reason) || %{}

      _ ->
        %{}
    end
  end

  defp authorization_issuer(metadata) do
    servers =
      metadata["authorization_servers"] ||
        metadata["authorizationServers"] ||
        metadata["authorization_server"] ||
        metadata["issuer"] ||
        []

    servers
    |> List.wrap()
    |> Enum.map(&string/1)
    |> Enum.reject(&(&1 == ""))
    |> List.first()
    |> case do
      nil -> {:error, {:bad_request, "protected resource metadata has no authorization server"}}
      issuer -> {:ok, issuer}
    end
  end

  defp discover_authorization_server(issuer) do
    with {:ok, metadata, metadata_url} <-
           issuer
           |> RemoteOAuth.authorization_server_metadata_urls()
           |> fetch_first_json("OAuth authorization server metadata"),
         :ok <- ensure_metadata_issuer(metadata, issuer) do
      {:ok, metadata, metadata_url}
    end
  end

  defp require_authorization_metadata(metadata) do
    cond do
      string(metadata["authorization_endpoint"]) == "" ->
        {:error, {:bad_request, "authorization server metadata missing authorization_endpoint"}}

      string(metadata["token_endpoint"]) == "" ->
        {:error, {:bad_request, "authorization server metadata missing token_endpoint"}}

      true ->
        :ok
    end
  end

  defp ensure_metadata_issuer(metadata, expected_issuer) do
    actual = string(metadata["issuer"])

    cond do
      actual == "" ->
        {:error, {:bad_request, "authorization server metadata missing issuer"}}

      normalize_issuer(actual) != normalize_issuer(expected_issuer) ->
        {:error, {:bad_request, "authorization server metadata issuer mismatch"}}

      true ->
        :ok
    end
  end

  defp client_for_authorization(tenant_id, identity) do
    case get_client_registration(tenant_id, identity["provider_key"]) do
      {:ok, client} ->
        if compatible_client_registration?(client, callback_url()) do
          {:ok, client}
        else
          create_client_for_authorization(tenant_id, identity)
        end

      {:error, :not_found} ->
        create_client_for_authorization(tenant_id, identity)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_client_for_authorization(tenant_id, identity) do
    metadata = identity["authorization_server_metadata"] || %{}

    case string(metadata["registration_endpoint"]) do
      "" ->
        static_client_for_authorization(tenant_id, identity)

      registration_endpoint ->
        if dynamic_client_registration_allowed?(metadata) do
          case register_dynamic_client(tenant_id, identity, registration_endpoint) do
            {:ok, _client} = ok ->
              ok

            {:error, reason} ->
              fallback_static_client_for_authorization(tenant_id, identity, reason)
          end
        else
          static_client_for_authorization(tenant_id, identity)
        end
    end
  end

  defp dynamic_client_registration_allowed?(metadata) do
    methods =
      metadata["token_endpoint_auth_methods_supported"]
      |> List.wrap()
      |> Enum.map(&string/1)
      |> Enum.reject(&(&1 == ""))

    methods == [] or "none" in methods
  end

  defp fallback_static_client_for_authorization(tenant_id, identity, dcr_reason) do
    case static_client_for_authorization(tenant_id, identity) do
      {:ok, _client} = ok ->
        ok

      {:error, {:missing_oauth_client, message}} ->
        {:error,
         {:missing_oauth_client,
          message <> "; dynamic client registration failed: " <> format_reason(dcr_reason)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp static_client_for_authorization(tenant_id, identity) do
    case OAuthApps.get_remote_mcp(tenant_id, identity["provider_key"]) do
      {:ok, app} ->
        {:ok,
         Map.merge(app, %{
           "client_registration_id" => "static:" <> identity["provider_key"],
           "provider_key" => identity["provider_key"],
           "client_source" => "static"
         })}

      {:error, :not_configured} ->
        {:error,
         {:missing_oauth_client,
          "remote MCP OAuth client is not configured for provider_key #{identity["provider_key"]}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp register_dynamic_client(tenant_id, identity, registration_endpoint) do
    redirect_uri = callback_url()

    body = %{
      "client_name" => "Salix MCP " <> string(identity["mcp_definition_id"]),
      "redirect_uris" => [redirect_uri],
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    }

    with {:ok, status, parsed} <-
           post_json(registration_endpoint, body, "MCP dynamic client registration"),
         :ok <- expect_status(status, 200..299, "MCP dynamic client registration"),
         client_id when client_id != "" <- string(parsed["client_id"]) do
      client_secret = string(parsed["client_secret"])

      client =
        %{
          "client_registration_id" => "mcpreg-" <> provider_hash(identity),
          "provider_kind" => @provider_kind,
          "provider_key" => identity["provider_key"],
          "tenant_id" => tenant_id,
          "client_source" => "dynamic",
          "client_id" => client_id,
          "client_secret" => client_secret,
          "token_endpoint_auth_method" => dynamic_token_auth_method(parsed, client_secret),
          "registration_client_uri" => string(parsed["registration_client_uri"]),
          "registration_access_token" => string(parsed["registration_access_token"]),
          "redirect_uris" => parsed["redirect_uris"] || [redirect_uri],
          "created_at" => Store.now(),
          "updated_at" => Store.now()
        }

      put_client_registration(tenant_id, identity["provider_key"], client)
    else
      "" -> {:error, {:bad_request, "dynamic client registration response missing client_id"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_auth_state(tenant_id, group_id, binding, identity, client, params) do
    identity = Map.put(identity, "client_registration_id", client["client_registration_id"])
    # Linear's MCP authorization relay is known to interoperate with the
    # conventional 128-bit OAuth state used by existing MCP clients.
    state = new_state()
    verifier = new_token()
    redirect_uri = callback_url()
    scope = requested_scope(params, identity)

    auth_url =
      authorization_url(
        identity["authorization_server_metadata"]["authorization_endpoint"],
        %{
          "client_id" => client["client_id"],
          "redirect_uri" => redirect_uri,
          "state" => state,
          "code_challenge" => code_challenge_s256(verifier),
          "scope" => scope,
          "resource" => identity["oauth_resource"]
        }
      )

    with {:ok, redirect_after} <- validate_redirect_after(params["redirect_after"]) do
      now = System.system_time(:millisecond)

      record = %{
        "state" => state,
        "tenant" => tenant_id,
        "group_id" => group_id,
        "agent_id" => nil,
        "session_id" => nil,
        "provider" => @provider,
        "provider_kind" => @provider_kind,
        "provider_key" => identity["provider_key"],
        "alias" => binding["alias"],
        "scopes" => split_scope(scope),
        "code_verifier" => verifier,
        "redirect_uri" => redirect_uri,
        "redirect_after" => redirect_after,
        "origin" => "mcp",
        "comma_operation" => params["comma_operation"],
        "status" => "pending",
        "error" => nil,
        "binding_id" => nil,
        "connection_id" => nil,
        "provider_account_name" => nil,
        "mcp_definition_id" => binding["mcp_id"],
        "mcp_binding_id" => binding["binding_id"],
        "binding_revision" => binding["revision"],
        "target_ref" => binding["target_ref"],
        "client_registration_id" => client["client_registration_id"],
        "client_source" => client["client_source"],
        "oauth_metadata" => identity,
        "expires_at" =>
          case params["expires_at"] do
            value when is_integer(value) -> min(value, now + @auth_state_ttl_ms)
            _ -> now + @auth_state_ttl_ms
          end,
        "created_at" => now
      }

      case AuthState.create(record) do
        :ok -> {:ok, %{state: state, authorization_url: auth_url}}
        {:error, reason} -> internal_error("persist remote MCP OAuth state", reason)
      end
    end
  end

  defp authorization_url(endpoint, req) do
    query =
      [
        {"client_id", req["client_id"]},
        {"redirect_uri", req["redirect_uri"]},
        {"response_type", "code"},
        {"state", req["state"]},
        {"code_challenge", req["code_challenge"]},
        {"code_challenge_method", "S256"}
      ]
      |> maybe_query("scope", req["scope"])
      |> maybe_query("resource", req["resource"])
      |> URI.encode_query()

    endpoint <> "?" <> query
  end

  defp mark_authorization_pending(binding, identity, auth) do
    case SalixMCP.Store.put_connection(binding, %{
           "status" => "authorization_pending",
           "last_error" => %{
             "oauth" => %{
               "provider_kind" => @provider_kind,
               "provider_key" => identity["provider_key"],
               "authorization_url" => auth.authorization_url,
               "state" => auth.state
             }
           }
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reset_mcp_connection(binding) do
    case SalixMCP.Store.put_connection(binding, %{"status" => "configured", "last_error" => nil}) do
      {:ok, _connection} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_missing_oauth_client(binding, identity, message) do
    case SalixMCP.Store.put_connection(binding, %{
           "status" => "missing_oauth_client",
           "last_error" => %{
             "oauth" => %{
               "provider_kind" => @provider_kind,
               "provider_key" => identity["provider_key"],
               "resource_server_url" => identity["resource_server_url"],
               "authorization_issuer" => identity["authorization_issuer"],
               "reason" => message
             }
           }
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- callback / token persistence ----

  defp consume_state(state_id) do
    case AuthState.consume(state_id) do
      {:ok, auth} -> {:ok, auth}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_remote_auth_state(auth) do
    if auth["provider"] == @provider and auth["provider_kind"] == @provider_kind do
      :ok
    else
      {:error, {auth, "authorization state is not a remote MCP OAuth state"}}
    end
  end

  defp ensure_auth_binding_current(auth) do
    with {:ok, binding, _definition, _connection} <-
           SalixMCP.Store.get_binding_with_definition(
             auth["tenant"],
             auth["group_id"],
             auth["mcp_binding_id"]
           ) do
      cond do
        binding["mcp_id"] != auth["mcp_definition_id"] ->
          {:error, {auth, "MCP binding changed while authorization was pending"}}

        binding["revision"] != auth["binding_revision"] ->
          {:error, {auth, "MCP binding revision changed while authorization was pending"}}

        string(binding["target_ref"]) != string(auth["target_ref"]) ->
          {:error, {auth, "MCP binding target changed while authorization was pending"}}

        true ->
          :ok
      end
    else
      {:error, reason} ->
        {:error, {auth, "MCP binding is no longer available: " <> format_reason(reason)}}
    end
  end

  defp client_for_state(auth) do
    provider_key = string(auth["provider_key"])

    case string(auth["client_source"]) do
      "dynamic" ->
        get_client_registration(auth["tenant"], provider_key)

      "static" ->
        case OAuthApps.get_remote_mcp(auth["tenant"], provider_key) do
          {:ok, app} ->
            {:ok,
             Map.merge(app, %{
               "client_registration_id" => auth["client_registration_id"],
               "provider_key" => provider_key,
               "client_source" => "static"
             })}

          {:error, reason} ->
            {:error, {auth, reason}}
        end

      _ ->
        {:error, {auth, "unknown remote MCP OAuth client source"}}
    end
  end

  defp exchange_code(auth, client, code) do
    metadata = auth["oauth_metadata"] || %{}
    authorization_metadata = metadata["authorization_server_metadata"] || %{}

    form =
      [
        {"grant_type", "authorization_code"},
        {"code", code},
        {"redirect_uri", auth["redirect_uri"]},
        {"code_verifier", auth["code_verifier"]}
      ]
      |> maybe_query("client_id", client_id_form_value(client))
      |> maybe_query("resource", metadata["oauth_resource"])

    with {:ok, status, parsed} <-
           post_form(
             authorization_metadata["token_endpoint"],
             authorize_form_with_client_secret(form, client),
             "remote MCP token",
             token_headers(client)
           ),
         :ok <- expect_status(status, 200..299, "remote MCP token"),
         {:ok, token} <- token_from_response(parsed) do
      {:ok, token}
    else
      {:error, reason} -> {:error, {auth, reason}}
    end
  end

  defp persist_authorization(auth, client, token) do
    metadata = auth["oauth_metadata"] || %{}
    connection_id = "conn-" <> Store.random_id()

    record =
      token
      |> Map.merge(%{
        "connection_id" => connection_id,
        "tenant" => auth["tenant"],
        "provider" => @provider_kind,
        "provider_kind" => @provider_kind,
        "provider_key" => auth["provider_key"],
        "provider_account_id" => metadata["resource_server_url"] || auth["provider_key"],
        "provider_account_name" => metadata["resource_server_url"] || "Remote MCP",
        "metadata" =>
          metadata
          |> Map.take([
            "resource_server_url",
            "authorization_issuer",
            "authorization_server_metadata_url",
            "protected_resource_metadata_url",
            "mcp_definition_id",
            "mcp_binding_id",
            "target_ref",
            "scope",
            "oauth_resource"
          ])
          |> Map.merge(%{
            "client_registration_id" => client["client_registration_id"],
            "client_source" => client["client_source"],
            "token_endpoint" =>
              get_in(metadata, ["authorization_server_metadata", "token_endpoint"]),
            "revocation_endpoint" =>
              get_in(metadata, ["authorization_server_metadata", "revocation_endpoint"])
          }),
        "status" => "active",
        "created_at" => Store.now(),
        "updated_at" => Store.now()
      })

    with :ok <- OAuth.put(connection_id, record),
         {:ok, oauth_binding, previous_connection_id} <-
           OAuthBindings.put_remote_mcp(
             auth["tenant"],
             auth["group_id"],
             auth["provider_key"],
             auth["alias"],
             connection_id,
             %{
               "mcp_definition_id" => auth["mcp_definition_id"],
               "mcp_binding_id" => auth["mcp_binding_id"],
               "resource_server_url" => metadata["resource_server_url"]
             }
           ),
         {:ok, _mcp_binding} <-
           SalixMCP.Store.set_remote_oauth_binding(
             auth["tenant"],
             auth["group_id"],
             auth["mcp_binding_id"],
             oauth_binding["binding_id"]
           ) do
      if previous_connection_id do
        cleanup_previous_connection(auth["tenant"], previous_connection_id)
      end

      _ =
        SalixMCP.Gateway.refresh_binding(auth["tenant"], auth["group_id"], auth["mcp_binding_id"])

      completion = %{
        "binding_id" => oauth_binding["binding_id"],
        "connection_id" => connection_id,
        "provider_account_name" => record["provider_account_name"]
      }

      {:ok, completion}
    else
      {:error, reason} ->
        # A Comma reauthorization may have changed the binding even when a later
        # write fails. Keep its credential for the fenced retry path.
        if is_nil(auth["comma_operation"]) do
          _ = S3.delete(Keys.oauth_connection(connection_id))
        end

        {:error, {auth, reason}}
    end
  end

  defp cleanup_previous_connection(tenant_id, connection_id) do
    if OAuthBindings.count_for_connection(connection_id) == 0 do
      with {:ok, conn} <- OAuth.get(connection_id) do
        best_effort_revoke(tenant_id, conn)
      end

      _ = S3.delete(Keys.oauth_connection(connection_id))
    end

    :ok
  end

  defp revoke_connection_if_unreferenced(_tenant_id, connection_id, _binding_id)
       when not is_binary(connection_id) or connection_id == "",
       do: :ok

  defp revoke_connection_if_unreferenced(tenant_id, connection_id, binding_id) do
    if OAuthBindings.count_for_connection(connection_id, exclude_binding_id: binding_id) == 0 do
      revoke_connection(tenant_id, connection_id)
    else
      :ok
    end
  end

  defp revoke_connection(tenant_id, connection_id) do
    with {:ok, conn} <- OAuth.get(connection_id) do
      best_effort_revoke(tenant_id, conn)

      OAuth.put(
        connection_id,
        conn
        |> Map.drop(["access_token", "refresh_token"])
        |> Map.put("status", "revoked")
        |> Map.put("updated_at", Store.now())
      )
    else
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp best_effort_revoke(tenant_id, conn) do
    revocation_endpoint = get_in(conn, ["metadata", "revocation_endpoint"])

    tokens =
      [
        {"access_token", conn["access_token"]},
        {"refresh_token", conn["refresh_token"]}
      ]
      |> Enum.map(fn {hint, token} -> {hint, string(token)} end)
      |> Enum.reject(fn {_hint, token} -> token == "" end)

    if string(revocation_endpoint) != "" and tokens != [] do
      with {:ok, client} <- client_for_connection(tenant_id, conn) do
        Enum.each(tokens, fn {hint, token} ->
          post_form(
            revocation_endpoint,
            authorize_form_with_client_secret(
              [{"token", token}, {"token_type_hint", hint}]
              |> maybe_query("client_id", client_id_form_value(client)),
              client
            ),
            "remote MCP token revoke",
            token_headers(client)
          )
        end)
      end
    end

    :ok
  rescue
    error ->
      Logger.warning("remote MCP OAuth revoke failed: #{Exception.message(error)}")
      :ok
  end

  # ---- token resolve / refresh ----

  defp valid_remote_token(tenant_id, connection_id) do
    with {:ok, conn} <- OAuth.get(connection_id),
         :ok <- ensure_connection_usable(conn),
         :ok <- ensure_access_token(conn) do
      if should_refresh?(conn) do
        refresh_remote_token(tenant_id, connection_id)
      else
        {:ok, conn["access_token"]}
      end
    else
      {:error, :reauthorization_required} ->
        mark_reauthorization_required(connection_id)
        {:error, {:reauthorization_required, "remote MCP OAuth requires reauthorization"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_remote_token(tenant_id, connection_id) do
    case OAuth.valid_token(
           connection_id,
           fn record -> refresh_tokens(tenant_id, record) end,
           now: System.system_time(:millisecond) + @refresh_leeway_ms
         ) do
      {:ok, token} ->
        {:ok, token}

      {:error, :reauthorization_required} ->
        mark_reauthorization_required(connection_id)
        {:error, {:reauthorization_required, "remote MCP OAuth requires reauthorization"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_access_token(conn) do
    if string(conn["access_token"]) == "" do
      {:error, :reauthorization_required}
    else
      :ok
    end
  end

  defp should_refresh?(conn) do
    case conn["expires_at"] do
      expires_at when is_integer(expires_at) and expires_at > 0 ->
        System.system_time(:millisecond) >= expires_at - @refresh_leeway_ms

      _ ->
        false
    end
  end

  defp ensure_connection_usable(conn) do
    case conn["status"] do
      "reauthorization_required" ->
        {:error, {:reauthorization_required, "remote MCP OAuth requires reauthorization"}}

      "revoked" ->
        {:error, {:reauthorization_required, "remote MCP OAuth credential is revoked"}}

      _ ->
        :ok
    end
  end

  defp refresh_tokens(tenant_id, conn) do
    cond do
      string(conn["refresh_token"]) == "" ->
        {:error, :reauthorization_required}

      true ->
        with {:ok, client} <- client_for_connection(tenant_id, conn) do
          form =
            [
              {"grant_type", "refresh_token"},
              {"refresh_token", conn["refresh_token"]}
            ]
            |> maybe_query("client_id", client_id_form_value(client))
            |> authorize_form_with_client_secret(client)

          case post_form(
                 get_in(conn, ["metadata", "token_endpoint"]),
                 form,
                 "remote MCP refresh",
                 token_headers(client)
               ) do
            {:ok, status, parsed} when status in 200..299 ->
              with {:ok, tokens} <- token_from_response(parsed) do
                {:ok, drop_empty_token_fields(tokens)}
              end

            {:ok, _status, parsed} ->
              refresh_error(parsed)

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp client_for_connection(tenant_id, conn) do
    provider_key = get_in(conn, ["metadata", "provider_key"]) || conn["provider_key"]

    case get_in(conn, ["metadata", "client_source"]) do
      "dynamic" ->
        case get_client_registration(tenant_id, provider_key) do
          {:ok, client} -> {:ok, client}
          _ -> {:error, :reauthorization_required}
        end

      "static" ->
        case OAuthApps.get_remote_mcp(tenant_id, provider_key) do
          {:ok, client} -> {:ok, client}
          _ -> {:error, :reauthorization_required}
        end

      _ ->
        {:error, :reauthorization_required}
    end
  end

  defp mark_reauthorization_required(connection_id) do
    case OAuth.get(connection_id) do
      {:ok, conn} ->
        _ = OAuth.put(connection_id, Map.put(conn, "status", "reauthorization_required"))

      _ ->
        :ok
    end
  end

  defp ensure_oauth_binding_scope(binding, tenant_id, group_id) do
    cond do
      binding["tenant_id"] != tenant_id ->
        {:error, {:missing_oauth, "remote MCP OAuth binding belongs to another tenant"}}

      binding["group_id"] != group_id ->
        {:error, {:missing_oauth, "remote MCP OAuth binding belongs to another group"}}

      binding["provider_kind"] != @provider_kind ->
        {:error, {:missing_oauth, "MCP binding references a non-remote-MCP OAuth credential"}}

      true ->
        :ok
    end
  end

  defp ensure_oauth_binding_enabled(binding) do
    if Map.get(binding, "enabled", true) == false do
      {:error, {:oauth_disabled, "remote MCP OAuth credential is disabled"}}
    else
      :ok
    end
  end

  defp oauth_connection_id(binding) do
    case string(binding["connection_id"]) do
      "" -> {:error, {:missing_oauth, "remote MCP OAuth binding has no connection"}}
      id -> {:ok, id}
    end
  end

  # ---- client registration store ----

  defp get_client_registration(tenant_id, provider_key) do
    case Store.get_record(Keys.ctl_oauth_remote_mcp_client_registration(tenant_id, provider_key)) do
      {:ok, rec} -> {:ok, rec}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_client_registration(tenant_id, provider_key, rec) do
    Store.upsert_record(
      Keys.ctl_oauth_remote_mcp_client_registration(tenant_id, provider_key),
      rec,
      fn existing ->
        rec
        |> Map.put("created_at", existing["created_at"] || rec["created_at"])
        |> Map.put("updated_at", Store.now())
      end
    )
  end

  # ---- HTTP helpers ----

  defp fetch_first_json(urls, label), do: fetch_first_json(urls, label, nil)

  defp fetch_first_json([], label, nil), do: {:error, "#{label}: not found"}
  defp fetch_first_json([], _label, reason), do: {:error, reason}

  defp fetch_first_json([url | rest], label, _last_reason) do
    case fetch_json(url, label) do
      {:ok, metadata} -> {:ok, metadata, url}
      {:error, reason} -> fetch_first_json(rest, label, reason)
    end
  end

  defp fetch_json(url, label) do
    with {:ok, target} <- oauth_http_target(url) do
      case Req.get(
             target.url,
             headers: [{"accept", "application/json"}, {"host", target.host_header}],
             connect_options: target.connect_options,
             inet6: target.inet6,
             redirect: false,
             retry: false
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          decode_json_body(body, label)

        {:ok, %Req.Response{status: status}} ->
          {:error, "#{label}: HTTP #{status}"}

        {:error, error} ->
          {:error, "#{label}: #{Exception.message(error)}"}
      end
    end
  end

  defp post_json(url, body, label) do
    with {:ok, target} <- oauth_http_target(url) do
      case Req.post(
             target.url,
             json: body,
             headers: [{"accept", "application/json"}, {"host", target.host_header}],
             connect_options: target.connect_options,
             inet6: target.inet6,
             redirect: false,
             retry: false
           ) do
        {:ok, %Req.Response{status: status, body: body}} ->
          with {:ok, parsed} <- decode_json_body(body, label), do: {:ok, status, parsed}

        {:error, error} ->
          {:error, "#{label}: #{Exception.message(error)}"}
      end
    end
  end

  defp post_form(url, form, label, headers) do
    with {:ok, target} <- oauth_http_target(url) do
      case Req.post(
             target.url,
             form: form,
             headers: [{"accept", "application/json"}, {"host", target.host_header}] ++ headers,
             connect_options: target.connect_options,
             inet6: target.inet6,
             redirect: false,
             retry: false
           ) do
        {:ok, %Req.Response{status: status, body: body}} ->
          with {:ok, parsed} <- decode_json_body(body, label), do: {:ok, status, parsed}

        {:error, error} ->
          {:error, "#{label}: #{Exception.message(error)}"}
      end
    end
  end

  defp oauth_http_target(url) do
    case SalixWeb.LocalOAuthMock.http_target(url) do
      {:ok, target} -> {:ok, target}
      {:error, :not_local_oauth_mock} -> SalixMCP.URLPolicy.public_http_target(url)
    end
  end

  defp decode_json_body(body, _label) when is_map(body), do: {:ok, stringify(body)}

  defp decode_json_body(body, label) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> {:ok, stringify(map)}
      _ -> {:error, "#{label}: invalid JSON"}
    end
  end

  defp decode_json_body(_body, label), do: {:error, "#{label}: invalid JSON"}

  defp expect_status(status, range, label) do
    if status in range do
      :ok
    else
      {:error, "#{label}: HTTP #{status}"}
    end
  end

  # ---- token / client helpers ----

  defp token_from_response(parsed) do
    access_token = string(parsed["access_token"])

    cond do
      access_token == "" ->
        {:error, "remote MCP token response missing access_token"}

      true ->
        {:ok,
         %{
           "access_token" => access_token,
           "refresh_token" => blank_to_nil(parsed["refresh_token"]),
           "token_type" => string(parsed["token_type"] || "Bearer"),
           "scopes" => split_scope(parsed["scope"] || parsed["scopes"]),
           "expires_at" => expires_at_ms(parsed["expires_in"]),
           "refresh_expires_at" => nil
         }}
    end
  end

  defp drop_empty_token_fields(tokens) do
    tokens
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" or value == [] end)
    |> Map.new()
  end

  defp refresh_error(parsed) when is_map(parsed) do
    message =
      [parsed["error"], parsed["error_description"]]
      |> Enum.map(&string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(": ")

    downcase = String.downcase(message)

    if String.contains?(downcase, "invalid_grant") or
         String.contains?(downcase, "invalid grant") or
         String.contains?(downcase, "expired_token") do
      {:error, :reauthorization_required}
    else
      {:error, if(message == "", do: "remote MCP refresh failed", else: message)}
    end
  end

  defp authorize_form_with_client_secret(form, client) do
    if string(client["client_secret"]) != "" and
         token_auth_method(client) != "client_secret_basic" do
      maybe_query(form, "client_secret", client["client_secret"])
    else
      form
    end
  end

  defp token_headers(client) do
    if string(client["client_secret"]) != "" and
         token_auth_method(client) == "client_secret_basic" do
      [
        {"authorization",
         "Basic " <>
           Base.encode64(string(client["client_id"]) <> ":" <> string(client["client_secret"]))}
      ]
    else
      []
    end
  end

  defp client_id_form_value(client) do
    if token_auth_method(client) == "client_secret_basic" do
      ""
    else
      client["client_id"]
    end
  end

  defp token_auth_method(client) do
    case string(client["token_endpoint_auth_method"]) do
      "" -> if(string(client["client_secret"]) == "", do: "none", else: "client_secret_post")
      method -> method
    end
  end

  defp dynamic_token_auth_method(parsed, client_secret) do
    case string(parsed["token_endpoint_auth_method"]) do
      "" -> if(client_secret == "", do: "none", else: "client_secret_post")
      method -> method
    end
  end

  defp requested_scope(params, identity) do
    cond do
      is_list(params["scopes"]) -> Enum.join(split_scope(params["scopes"]), " ")
      string(params["scope"]) != "" -> string(params["scope"])
      string(identity["scope"]) != "" -> string(identity["scope"])
      true -> ""
    end
  end

  @doc false
  def authorization_scope(challenge, metadata) do
    cond do
      string(challenge["scope"]) != "" ->
        string(challenge["scope"])

      true ->
        metadata["scopes_supported"]
        |> split_scope()
        |> Enum.join(" ")
    end
  end

  @doc false
  def redirect_after_allowed?(value) when is_binary(value), do: safe_redirect_after?(value)
  def redirect_after_allowed?(_value), do: false

  defp split_scope(scopes) when is_list(scopes) do
    scopes |> Enum.map(&string/1) |> Enum.reject(&(&1 == ""))
  end

  defp split_scope(scopes) when is_binary(scopes) do
    scopes
    |> String.split(~r/[\s,]+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_scope(_scopes), do: []

  defp expires_at_ms(expires_in) when is_number(expires_in) and expires_in > 0,
    do: System.system_time(:millisecond) + trunc(expires_in) * 1000

  defp expires_at_ms(_expires_in), do: nil

  defp provider_key(identity), do: "mcp_" <> provider_hash(identity)

  defp provider_hash(identity) do
    [
      identity["resource_server_url"],
      identity["authorization_issuer"],
      identity["authorization_server_metadata_url"],
      identity["protected_resource_metadata_url"],
      identity["mcp_definition_id"]
    ]
    |> Enum.map(&string/1)
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp callback_url do
    String.trim_trailing(SalixWeb.Application.public_base_url(), "/") <>
      "/v1/oauth/mcp/callback"
  end

  defp new_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp new_state, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp code_challenge_s256(verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  # ---- response rendering ----

  defp finish(auth, error_message, completion \\ nil) do
    record_outcome(auth, error_message, completion)

    redirect_after = auth && blank_to_nil(auth["redirect_after"])

    cond do
      error_message && redirect_after ->
        {:redirect, append_oauth_error(redirect_after, error_message)}

      is_nil(error_message) && redirect_after ->
        {:redirect, redirect_after}

      true ->
        status = if error_message, do: 400, else: 200
        service = (auth && auth["alias"]) || "remote MCP"
        {:page, status, SalixWeb.OAuthCallbackPage.render_mcp(service, error_message)}
    end
  end

  defp record_outcome(nil, _error_message, _completion), do: :ok

  defp record_outcome(auth, error_message, completion) do
    cond do
      is_binary(error_message) ->
        _ = AuthState.record_failure(auth["state"], error_message)

      is_map(completion) ->
        _ = AuthState.record_completion(auth["state"], completion)

      true ->
        :ok
    end
  end

  defp callback_state_error(reason) when reason in [:not_found, :expired, :already_consumed],
    do: "authorization session expired"

  defp callback_state_error(reason), do: format_reason(reason)

  defp append_oauth_error(redirect_after, message) do
    uri = URI.parse(redirect_after)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put("oauth_error", message)
      |> URI.encode_query()

    URI.to_string(%{uri | query: query})
  end

  # ---- misc helpers ----

  defp public_authorization_metadata(metadata) do
    metadata
    |> public_metadata()
    |> Map.take([
      "issuer",
      "authorization_endpoint",
      "token_endpoint",
      "registration_endpoint",
      "revocation_endpoint",
      "scopes_supported",
      "response_types_supported",
      "grant_types_supported",
      "token_endpoint_auth_methods_supported"
    ])
  end

  defp public_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.new(fn {key, value} -> {to_string(key), public_metadata(value)} end)
    |> Map.drop([
      "access_token",
      "refresh_token",
      "authorization_code",
      "code_verifier",
      "client_secret",
      "registration_access_token"
    ])
  end

  defp public_metadata(list) when is_list(list), do: Enum.map(list, &public_metadata/1)
  defp public_metadata(value), do: value

  defp compatible_client_registration?(client, redirect_uri) do
    redirect_uri in Enum.map(List.wrap(client["redirect_uris"]), &string/1)
  end

  defp validate_redirect_after(value) do
    case blank_to_nil(value) do
      nil ->
        {:ok, nil}

      redirect_after ->
        if redirect_after_allowed?(redirect_after) do
          {:ok, redirect_after}
        else
          {:error, {:bad_request, "redirect_after must use a configured Comma web origin"}}
        end
    end
  end

  defp safe_redirect_after?("/" <> _ = path) do
    case safe_uri_decode(path) do
      {:ok, decoded} ->
        String.starts_with?(decoded, "/") and
          not String.starts_with?(decoded, ["//", "/\\"])

      :error ->
        false
    end
  end

  defp safe_redirect_after?(url) do
    actual = URI.parse(url)

    actual.scheme in ["http", "https"] and is_binary(actual.host) and
      is_nil(actual.userinfo) and
      Enum.any?(oauth_return_base_urls(), &same_origin?(actual, URI.parse(&1)))
  end

  defp oauth_return_base_urls do
    [
      SalixWeb.Application.public_base_url()
      | Application.get_env(:salix_web, :oauth_return_base_urls, [])
    ]
    |> Enum.map(&string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp same_origin?(actual, expected) do
    expected.scheme in ["http", "https"] and is_binary(expected.host) and
      actual.scheme == expected.scheme and actual.host == expected.host and
      effective_port(actual) == effective_port(expected)
  end

  defp ensure_protected_resource_matches(metadata, mcp_url) do
    case string(metadata["resource"]) do
      "" ->
        :ok

      resource ->
        if resource_covers_mcp_url?(resource, mcp_url) do
          :ok
        else
          {:error, {:bad_request, "protected resource metadata resource does not match MCP URL"}}
        end
    end
  end

  defp resource_covers_mcp_url?(resource, mcp_url) do
    resource_uri = URI.parse(resource)
    mcp_uri = URI.parse(string(mcp_url))

    http_url?(resource_uri) and http_url?(mcp_uri) and
      resource_uri.scheme == mcp_uri.scheme and
      resource_uri.host == mcp_uri.host and
      effective_port(resource_uri) == effective_port(mcp_uri) and
      path_prefix?(resource_uri.path, mcp_uri.path)
  end

  defp http_url?(%URI{scheme: scheme, host: host}),
    do: scheme in ["http", "https"] and is_binary(host) and host != ""

  defp path_prefix?(resource_path, mcp_path) do
    resource_path = normalize_path(resource_path)
    mcp_path = normalize_path(mcp_path)

    resource_path == "/" or mcp_path == resource_path or
      String.starts_with?(mcp_path, String.trim_trailing(resource_path, "/") <> "/")
  end

  defp normalize_path(path) do
    case string(path) do
      "" -> "/"
      "/" -> "/"
      path -> ("/" <> String.trim_leading(path, "/")) |> String.trim_trailing("/")
    end
  end

  defp effective_port(%URI{scheme: "http", port: nil}), do: 80
  defp effective_port(%URI{scheme: "https", port: nil}), do: 443
  defp effective_port(%URI{port: port}), do: port

  defp normalize_issuer(value), do: value |> string() |> String.trim_trailing("/")

  defp maybe_query(params, _key, nil), do: params
  defp maybe_query(params, _key, ""), do: params
  defp maybe_query(params, key, value), do: params ++ [{key, value}]

  defp blank_to_nil(value) do
    case string(value) do
      "" -> nil
      value -> value
    end
  end

  defp safe_uri_decode(value) do
    {:ok, URI.decode(value)}
  rescue
    _ -> :error
  end

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: String.trim(value)
  defp string(value), do: value |> to_string() |> String.trim()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp internal_error(context, reason) do
    Logger.warning("#{context}: #{inspect(reason)}")
    {:error, {:internal, "internal OAuth error"}}
  end

  defp format_reason(reason) when is_binary(reason), do: reason

  defp format_reason({kind, message})
       when kind in [
              :bad_request,
              :precondition_failed,
              :missing_oauth_client,
              :missing_oauth,
              :oauth_disabled,
              :reauthorization_required,
              :internal
            ] and is_binary(message),
       do: message

  defp format_reason(_reason), do: "remote MCP OAuth request failed"
end
