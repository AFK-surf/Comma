defmodule Salix.Bindings.MCPCredentials do
  @moduledoc false

  @behaviour SalixMCP.Credentials

  alias Salix.Control.{OAuthApps, OAuthBindings}
  alias SalixStore.OAuth

  @refresh_leeway_ms 60_000

  require Logger

  # X chooses its OAuth account at request time instead of storing a fixed reference.
  # Refresh discovery after account changes so Agents also see the current tool set.
  def oauth_binding_changed(%{"provider" => "x"} = binding) do
    context = SystemsObservability.Context.capture()

    case SystemsRuntime.TaskSupervisor.start_child(SalixWeb.OAuthMCPRefreshSupervisor, fn ->
           SystemsObservability.Context.run(context, fn ->
             refresh_x_bindings(binding["tenant_id"], binding["group_id"], nil)
           end)
         end) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> Logger.warning("X MCP discovery refresh could not start")
    end
  end

  def oauth_binding_changed(_binding), do: :ok

  # Background work reads 64 objects per page and refreshes one binding at a time.
  # The existing supervisor admits at most 16 OAuth discovery workers across providers.
  defp refresh_x_bindings(tenant_id, group_id, cursor) do
    prefix = SalixStore.Keys.ctl_mcp_group_bindings_prefix(tenant_id, group_id)

    case SalixStore.S3.list(prefix, max_keys: 64, continuation_token: cursor) do
      {:ok, %{objects: objects, next: next}} ->
        Enum.each(objects, fn %{key: key} ->
          if String.ends_with?(key, "/state.json") do
            with {:ok, %{"mcp_id" => "mcp1_0000000000000000009"} = binding} <-
                   Salix.Control.Store.get_record(key),
                 true <- binding["enabled"] != false and is_nil(binding["deleted_at"]),
                 false <- get_in(binding, ["config_values", "X_AUTH_MODE"]) == "app_only" do
              SalixMCP.Gateway.refresh_binding(tenant_id, group_id, binding["binding_id"])
            end
          end
        end)

        if next, do: refresh_x_bindings(tenant_id, group_id, next), else: :ok

      {:error, _reason} ->
        Logger.warning("X MCP discovery refresh could not read bindings")
    end
  end

  @impl true
  def resolve(%{
        "mcp_id" => "mcp1_0000000000000000009",
        "config_values" => %{"X_AUTH_MODE" => "app_only"}
      }),
      do: {:ok, %{}}

  def resolve(%{"mcp_id" => "mcp1_0000000000000000009"} = binding) do
    group_id = to_string(binding["group_id"] || "")

    case OAuthBindings.select_provider_record(group_id, "x", "x") do
      {:error, :not_found} ->
        {:ok, %{}}

      {:ok, oauth} ->
        resolve_refs(
          Map.put(binding, "oauth_binding_refs", %{
            "X_BEARER_TOKEN" => %{
              "binding_id" => oauth["binding_id"],
              "provider" => "x",
              "credential" => "access_token",
              "scopes" => ~w(tweet.read users.read)
            }
          })
        )

      {:error, :ambiguous_oauth_accounts} ->
        {:error,
         {:missing_oauth,
          "Multiple X accounts are connected. Give the intended account the alias x."}}

      {:error, _reason} ->
        {:error, {:missing_oauth, "Cannot read the X OAuth connection. Retry the request."}}
    end
  end

  def resolve(%{"oauth_binding_refs" => refs} = mcp_binding) when is_map(refs) do
    resolve_refs(mcp_binding)
  end

  def resolve(_binding), do: {:ok, %{}}

  defp resolve_refs(%{"oauth_binding_refs" => refs} = mcp_binding) do
    group_id = to_string(mcp_binding["group_id"] || "")
    tenant_id = to_string(mcp_binding["tenant_id"] || "")

    refs
    |> Enum.reduce_while({:ok, %{}}, fn {name, ref}, {:ok, acc} ->
      case resolve_ref(tenant_id, group_id, to_string(name), ref) do
        {:ok, {env_name, value}} -> {:cont, {:ok, Map.put(acc, env_name, value)}}
        {:error, reason} -> {:halt, {:error, {:missing_oauth, reason}}}
      end
    end)
  end

  @impl true
  def resolve_remote_headers(%{"mcp_id" => "mcp1_0000000000000000009"}, _binding),
    do: {:ok, %{}}

  def resolve_remote_headers(_definition, binding) do
    Salix.Control.RemoteMCPOAuth.resolve_headers(binding)
  end

  @impl true
  def redaction_values(_definition, binding) do
    Salix.Control.RemoteMCPOAuth.redaction_values(binding)
  end

  @impl true
  def start_remote_authorization(tenant_id, group_id, binding_id, params) do
    Salix.Control.RemoteMCPOAuth.start_authorization(tenant_id, group_id, binding_id, params)
  end

  @impl true
  def invalidate_remote_oauth_binding(binding, reason) do
    Salix.Control.RemoteMCPOAuth.invalidate_binding_ref(binding, reason)
  end

  @impl true
  def mark_remote_oauth_reauthorization_required(binding, reason) do
    Salix.Control.RemoteMCPOAuth.mark_binding_reauthorization_required(binding, reason)
  end

  defp resolve_ref(tenant_id, group_id, name, ref) do
    with {:ok, normalized} <- normalize_ref(name, ref),
         {:ok, binding} <- find_binding(group_id, normalized),
         :ok <- ensure_binding_scope(binding, tenant_id, group_id),
         :ok <- ensure_enabled(binding),
         {:ok, conn_id} <- connection_id(binding),
         :ok <-
           ensure_expected_connection(conn_id, Map.get(normalized, :expected_connection_id, "")),
         {:ok, conn} <- load_connection(conn_id),
         :ok <- ensure_connection_status(conn),
         :ok <- ensure_connection_scopes(conn, normalized.scopes),
         provider <- nonblank(normalized.provider, binding["provider"]),
         {:ok, adapter} <- adapter(provider),
         :ok <- adapter.validate_credential_value(normalized.credential, conn["scopes"] || []),
         {:ok, conn} <- maybe_refresh(tenant_id, provider, conn_id, conn, adapter),
         {:ok, token} <- adapter.resolve_credential_value(conn, normalized.credential) do
      {:ok, {normalized.env_name, token}}
    end
  end

  defp normalize_ref(name, ref) when is_map(ref) do
    ref = stringify(ref)

    {:ok,
     %{
       env_name: string(ref["env_var"] || name),
       provider: provider(ref["provider"]),
       alias: string(ref["alias"]),
       binding_id: string(ref["binding_id"]),
       expected_connection_id: string(ref["expected_connection_id"]),
       scopes: normalize_scopes(ref["scopes"]),
       credential:
         string(
           ref["credential"] || ref["credential_name"] || ref["credentialName"] || "access_token"
         )
     }}
  end

  defp normalize_ref(name, ref) when is_binary(ref) do
    case String.split(ref, ~r/[\/:]/, parts: 2) do
      [provider, alias_name] ->
        {:ok,
         %{
           env_name: name,
           provider: provider(provider),
           alias: string(alias_name),
           binding_id: "",
           scopes: [],
           credential: "access_token"
         }}

      _ ->
        {:error, "OAuth ref #{inspect(name)} must include provider and alias"}
    end
  end

  defp normalize_ref(name, _ref), do: {:error, "OAuth ref #{inspect(name)} must be an object"}

  defp find_binding(group_id, %{binding_id: binding_id}) when binding_id != "" do
    OAuthBindings.get(group_id, binding_id)
  end

  defp find_binding(group_id, %{provider: provider, alias: alias_name}) do
    case Enum.find(OAuthBindings.list_records(group_id), fn binding ->
           binding["provider"] == provider and binding["alias"] == alias_name
         end) do
      nil -> {:error, "OAuth binding #{provider}/#{alias_name} is not connected"}
      binding -> {:ok, binding}
    end
  end

  defp ensure_binding_scope(binding, tenant_id, group_id) do
    cond do
      binding["tenant_id"] != tenant_id ->
        {:error, "OAuth binding does not belong to this tenant"}

      binding["group_id"] != group_id ->
        {:error, "OAuth binding does not belong to this group"}

      true ->
        :ok
    end
  end

  defp ensure_enabled(binding) do
    if Map.get(binding, "enabled", true) == false do
      {:error, "OAuth binding #{binding["provider"]}/#{binding["alias"]} is disabled"}
    else
      :ok
    end
  end

  defp connection_id(binding) do
    case string(binding["connection_id"]) do
      "" -> {:error, "OAuth binding #{binding["provider"]}/#{binding["alias"]} has no connection"}
      conn_id -> {:ok, conn_id}
    end
  end

  # Member-scoped readers pin the consented connection, not a mutable alias.
  # Reject replacement before token refresh or any provider request.
  defp ensure_expected_connection(_connection_id, ""), do: :ok
  defp ensure_expected_connection(connection_id, connection_id), do: :ok

  defp ensure_expected_connection(_connection_id, _expected),
    do: {:error, "OAuth binding connection changed"}

  defp load_connection(conn_id) do
    case OAuth.get(conn_id) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, "load OAuth connection: #{format_reason(reason)}"}
    end
  end

  defp ensure_connection_status(conn) do
    case conn["status"] do
      status when status in [nil, "active"] -> :ok
      "reauthorization_required" -> {:error, "OAuth connection requires reauthorization"}
      "revoked" -> {:error, "OAuth connection is revoked"}
      _status -> {:error, "OAuth connection is not active"}
    end
  end

  defp ensure_connection_scopes(conn, required_scopes) do
    granted = MapSet.new(normalize_scopes(conn["scopes"]))
    required = MapSet.new(required_scopes)

    if MapSet.subset?(required, granted) do
      :ok
    else
      {:error, "OAuth connection is missing required scopes"}
    end
  end

  defp adapter(provider) do
    case SalixStore.OAuth.Adapters.for_provider(provider) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, _} -> {:error, "OAuth provider #{inspect(provider)} is not supported"}
    end
  end

  defp maybe_refresh(tenant_id, provider, conn_id, conn, adapter) do
    now = SystemsClock.system_time(:millisecond)

    cond do
      not is_integer(conn["expires_at"]) or conn["expires_at"] <= 0 ->
        {:ok, conn}

      now < conn["expires_at"] - @refresh_leeway_ms ->
        {:ok, conn}

      true ->
        refresh_connection(tenant_id, provider, conn_id, adapter)
    end
  end

  defp refresh_connection(tenant_id, provider, conn_id, adapter) do
    with {:ok, app} <- OAuthApps.get(tenant_id, provider),
         {:ok, _token} <-
           OAuth.valid_token(
             conn_id,
             fn record -> refresh_tokens(adapter, app, record) end,
             now: SystemsClock.system_time(:millisecond) + @refresh_leeway_ms
           ),
         {:ok, conn} <- OAuth.get(conn_id) do
      {:ok, conn}
    else
      {:error, :reauthorization_required} ->
        mark_reauthorization_required(conn_id)
        {:error, "OAuth connection requires reauthorization"}

      {:error, reason} ->
        {:error, "refresh OAuth connection: #{format_reason(reason)}"}
    end
  end

  defp refresh_tokens(adapter, app, record) do
    case adapter.refresh(app, record) do
      {:ok, tokens} when is_map(tokens) -> {:ok, sanitize_tokens(tokens, record)}
      {:error, _} = err -> err
      other -> {:error, "unexpected OAuth refresh result: #{inspect(other)}"}
    end
  end

  defp sanitize_tokens(tokens, record) do
    access_token = to_string(tokens["access_token"] || "")

    if access_token == "" or access_token == record["access_token"] do
      %{}
    else
      tokens
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()
      |> then(fn map ->
        if map["scopes"] in [nil, []], do: Map.delete(map, "scopes"), else: map
      end)
    end
  end

  defp mark_reauthorization_required(conn_id) do
    case OAuth.get(conn_id) do
      {:ok, conn} -> _ = OAuth.put(conn_id, Map.put(conn, "status", "reauthorization_required"))
      _ -> :ok
    end
  end

  defp provider(value) do
    value |> string() |> String.downcase()
  end

  defp nonblank(value, fallback) do
    case string(value) do
      "" -> string(fallback)
      value -> value
    end
  end

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: String.trim(value)
  defp string(value), do: value |> to_string() |> String.trim()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_scopes(_scopes), do: []

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
