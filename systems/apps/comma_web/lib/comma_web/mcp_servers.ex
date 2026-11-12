defmodule CommaWeb.McpServers do
  @moduledoc """
  The MCP servers a workspace's owner connected by address, listed beside the
  plugin catalog: every workspace binding of a tenant's own MCP definition,
  whether it was added here or by an Agent through `mcp_manager`. Bindings of
  system definitions belong to their plugins and are not offered here.
  """

  alias Comma.Workspaces
  alias Salix.Control.RemoteMCPOAuth
  alias SalixMCP.{Gateway, Store}

  # A server that refuses Streamable HTTP may still speak the older SSE.
  @transports ~w(streamable-http sse)
  @connected ~w(running degraded)
  @needs_authorization ~w(not_authorized reauthorization_required authorization_pending)

  def list(user, session, workspace_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id) do
      {:ok, %{"servers" => servers(workspace)}}
    end
  end

  @doc "Connects a server by its address; `authorizationUrl` when it asks for an OAuth sign-in."
  def add(user, session, workspace_id, attrs) when is_map(attrs) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, url} <- address(attrs["url"]) do
      name = display_name(attrs["name"], url)
      alias_name = binding_alias(name, url)

      with :ok <- alias_free(workspace, alias_name),
           {:ok, binding} <- connect_first(workspace, name, url, alias_name, @transports) do
        answer(workspace, binding, fn ->
          Gateway.delete_binding(tenant(workspace), group(workspace), binding["binding_id"])
        end)
      end
    end
  end

  def add(_user, _session, _workspace_id, _attrs), do: {:error, {:bad_request, "invalid_mcp_url"}}

  @doc "Connects a listed server again; `authorizationUrl` when it needs a new sign-in."
  def connect(user, session, workspace_id, binding_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, binding} <- listed_binding(workspace, binding_id),
         :ok <- enable(workspace, binding),
         {:ok, _connection} <-
           Gateway.refresh_binding(tenant(workspace), group(workspace), binding_id),
         {:ok, refreshed} <- Store.get_binding(tenant(workspace), group(workspace), binding_id) do
      answer(workspace, Store.public_binding_with_connection(refreshed), fn -> :ok end)
    end
  end

  def remove(user, session, workspace_id, binding_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, _binding} <- listed_binding(workspace, binding_id),
         :ok <- RemoteMCPOAuth.disconnect(tenant(workspace), group(workspace), binding_id),
         :ok <- Gateway.delete_binding(tenant(workspace), group(workspace), binding_id) do
      {:ok, %{"servers" => servers(workspace)}}
    end
  end

  defp connect_first(_workspace, _name, _url, _alias_name, []),
    do: {:error, {:bad_request, "mcp_server_unreachable"}}

  defp connect_first(workspace, name, url, alias_name, [transport | rest]) do
    with {:ok, definition} <- definition_for(workspace, name, url, transport),
         {:ok, binding} <-
           Gateway.create_binding(tenant(workspace), group(workspace), %{
             "mcp_id" => definition["mcp_id"],
             "alias" => alias_name,
             "target_ref" => definition |> remote() |> Map.fetch!("target_ref"),
             "placement" => "server"
           }) do
      if status(binding) == "failed" do
        _ = Gateway.delete_binding(tenant(workspace), group(workspace), binding["binding_id"])
        connect_first(workspace, name, url, alias_name, rest)
      else
        {:ok, binding}
      end
    end
  end

  # Adding a server again after removing it uses its definition again.
  defp definition_for(workspace, name, url, transport) do
    existing =
      tenant(workspace)
      |> tenant_definitions()
      |> Enum.find(fn definition ->
        remote = remote(definition)

        definition["name"] == name and remote["url"] == url and remote["transport"] == transport
      end)

    case existing do
      nil ->
        Store.create_definition(%{
          "tenant_id" => tenant(workspace),
          "name" => name,
          "url" => url,
          "transport" => transport
        })

      definition ->
        {:ok, definition}
    end
  end

  defp answer(workspace, binding, undo) do
    if status(binding) == "needs_authorization" do
      case RemoteMCPOAuth.start_authorization(
             tenant(workspace),
             group(workspace),
             binding["binding_id"],
             %{}
           ) do
        {:ok, %{"authorization_url" => url}} ->
          {:ok, %{"servers" => servers(workspace), "authorizationUrl" => url}}

        {:error, _reason} ->
          _ = undo.()
          {:error, {:bad_request, "mcp_server_authorization_unavailable"}}
      end
    else
      {:ok, %{"servers" => servers(workspace)}}
    end
  end

  defp servers(workspace) do
    definitions = Map.new(tenant_definitions(tenant(workspace)), &{&1["mcp_id"], &1})

    tenant(workspace)
    |> Store.list_group_bindings(group(workspace), include_disabled: true)
    |> Enum.flat_map(fn binding ->
      case definitions[binding["mcp_id"]] do
        nil -> []
        definition -> [server(definition, binding)]
      end
    end)
  end

  defp server(definition, binding) do
    %{
      "id" => binding["binding_id"],
      "name" => definition["name"],
      "url" => remote(definition)["url"],
      "status" => status(binding),
      "tools" => length(get_in(binding, ["connection", "discovered", "tools"]) || [])
    }
  end

  defp status(binding) do
    case get_in(binding, ["connection", "status"]) do
      status when status in @connected -> "connected"
      status when status in @needs_authorization -> "needs_authorization"
      _status -> "failed"
    end
  end

  defp tenant_definitions(tenant_id) do
    tenant_id
    |> Store.list_definitions()
    |> Enum.filter(&(&1["scope"] == "tenant"))
  end

  defp remote(definition) do
    get_in(definition, ["server_metadata", "remotes"]) |> List.wrap() |> List.first() || %{}
  end

  defp listed_binding(workspace, binding_id) do
    with {:ok, binding} <- Store.get_binding(tenant(workspace), group(workspace), binding_id),
         {:ok, %{"tenant_id" => owner}} when owner != "" <-
           Store.get_definition(binding["mcp_id"], tenant(workspace)) do
      {:ok, binding}
    else
      _ -> {:error, :not_found}
    end
  end

  defp enable(_workspace, %{"enabled" => enabled}) when enabled != false, do: :ok

  defp enable(workspace, binding) do
    with {:ok, _binding} <-
           Gateway.set_binding_enabled(
             tenant(workspace),
             group(workspace),
             binding["binding_id"],
             true
           ),
         do: :ok
  end

  defp alias_free(workspace, alias_name) do
    case Store.find_binding_by_alias(tenant(workspace), group(workspace), alias_name) do
      {:error, :not_found} -> :ok
      {:ok, _binding} -> {:error, {:bad_request, "mcp_server_exists"}}
    end
  end

  defp address(value) when is_binary(value) do
    url = String.trim(value)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        {:ok, url}

      _uri ->
        {:error, {:bad_request, "invalid_mcp_url"}}
    end
  end

  defp address(_value), do: {:error, {:bad_request, "invalid_mcp_url"}}

  defp display_name(name, url) when is_binary(name) do
    case String.trim(name) do
      "" -> URI.parse(url).host
      trimmed -> trimmed
    end
  end

  defp display_name(_name, url), do: URI.parse(url).host

  # A name with no latin letters has an empty alias; the host names the tools then.
  defp binding_alias(name, url) do
    case Store.normalize_alias(name) do
      "mcp" -> Store.normalize_alias(URI.parse(url).host)
      alias_name -> alias_name
    end
  end

  defp tenant(workspace), do: workspace["salix_tenant_id"]
  defp group(workspace), do: workspace["default_group_id"]
end
