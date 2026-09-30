defmodule SalixWeb.Connect do
  @moduledoc """
  The `GET /v1/connect` WebSocket upgrade. A `salix-connect` client opens this
  socket; the server allocates a connector run, writes the durable record stamped
  with THIS node, and upgrades the connection to
  `SalixWeb.ConnectorSocket`.

  Query parameters:

    * `name`     — human-readable connector/device name (required)
    * `alias`    — tool-facing alias (defaults to `name`)
    * `os`, `arch` — advertised metadata
    * `scope` — optional Connector-owned current scope (`local_file_read` or
      the existing full empty value), used only for generation-fenced routing
      projection; token scope remains authoritative for socket authorization

  Auth already happened in `SalixWeb.Auth`; a connector credential supplies
  the stable device, connector and group identity. Current connector clients
  also send `X-Salix-Connector-Instance-ID`, which stays stable across socket
  reconnects in one process and changes after process replacement.

  Modeled in `tla/connector/ConnectorCredentialFence.tla`: this upgrade owns
  the request-side admission/CAS boundary and passes the exact committed run
  identity to the socket owner.
  """

  import Plug.Conn
  alias SalixEnv.Registry

  # Bandit's 8,000,000-byte default rejects a valid 8 MiB inline read once the
  # response envelope is included. Keep the larger bound scoped to connectors.
  @max_connector_message_bytes 16 * 1024 * 1024

  @connector_instance_header "x-salix-connector-instance-id"

  @spec upgrade(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def upgrade(conn, tenant_id) do
    params = conn.query_params

    with {:ok, scope} <- connector_scope(conn, tenant_id, params) do
      do_scoped_upgrade(conn, tenant_id, params, scope)
    else
      {:error, {status, message}} -> json_error(conn, status, message)
    end
  end

  defp do_scoped_upgrade(conn, tenant_id, params, scope) do
    name = scope.name
    group_id = scope.group_id

    cond do
      name == "" ->
        json_error(conn, 400, "name is required")

      group_id == "" ->
        json_error(conn, 400, "group_id is required")

      true ->
        case connector_reported_scope(params) do
          {:ok, connector_scope} ->
            do_upgrade(
              conn,
              tenant_id,
              params,
              name,
              group_id,
              Map.put(scope, :connector_scope, connector_scope)
            )

          {:error, message} ->
            json_error(conn, 400, message)
        end
    end
  end

  defp do_upgrade(conn, tenant_id, params, name, group_id, scope) do
    process_instance_id = connector_process_instance_id(conn)

    meta =
      scope
      |> Map.get(:meta, %{})
      |> Map.merge(%{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "name" => name,
        "alias" => scope.alias,
        "os" => params["os"] || "",
        "arch" => params["arch"] || ""
      })
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Registry.connect(
           to_string(node()),
           meta,
           registry_connect_opts(params, scope, process_instance_id)
         ) do
      {:ok, transport_id, record} ->
        conn
        |> upgrade_adapter(
          :websocket,
          {SalixWeb.ConnectorSocket,
           [
             env_id: transport_id,
             connector_run_id: record["connector_run_id"],
             connection_generation: record["connection_generation"],
             tenant_id: tenant_id,
             group_id: group_id,
             owner_user_id: meta["owner_user_id"],
             device_id: meta["device_id"],
             connector_id: meta["connector_id"],
             credential_generation: meta["credential_generation"],
             scope: meta["scope"],
             token_expires_at: Map.get(scope, :token_expires_at),
             token_hash: Map.get(scope, :token_hash),
             process_instance_id: record["process_instance_id"]
           ],
           [
             compress: false,
             max_frame_size: @max_connector_message_bytes,
             max_fragmented_message_size: @max_connector_message_bytes
           ]}
        )

      {:error, reason} ->
        json_error(
          conn,
          registry_error_status(reason),
          "could not register connector run: #{inspect(reason)}"
        )
    end
  end

  defp registry_error_status(:unauthorized), do: 403
  defp registry_error_status(:registration_unavailable), do: 503
  defp registry_error_status(:reclaim_conflict), do: 503
  defp registry_error_status(:connector_credential_revoked), do: 403
  defp registry_error_status(:connector_credential_expired), do: 403
  defp registry_error_status({:ambiguous, _reason}), do: 503

  defp registry_error_status({:http, status}) when status in [408, 429, 500, 502, 503, 504],
    do: 503

  defp registry_error_status({:http, status, _body})
       when status in [408, 429, 500, 502, 503, 504],
       do: 503

  defp registry_error_status(_reason), do: 500

  defp json_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => message}))
  end

  defp trimmed(nil), do: ""
  defp trimmed(v), do: String.trim(to_string(v))

  defp connector_scope(%{assigns: %{connector_token: token}}, tenant_id, params) do
    token_group = trimmed(token["group_id"])
    query_group = trimmed(params["group_id"])

    cond do
      query_group != "" ->
        {:error, {400, "group_id is not accepted with connector credential auth"}}

      true ->
        with :ok <- validate_connector_token_scope(token, tenant_id, token_group) do
          name = trimmed(params["name"]) |> default_to(token["name"] || "Group Connector")

          alias_name =
            trimmed(params["alias"])
            |> default_to(token["alias"] || name)

          {:ok,
           %{
             group_id: token_group,
             name: name,
             alias: alias_name,
             token_expires_at: token["expires_at"],
             token_hash: token["token_hash"],
             credential_generation: token["credential_generation"],
             meta:
               (token["meta"] || %{})
               |> Map.put("device_id", token["device_id"])
               |> Map.put("connector_id", token["connector_id"])
               |> Map.put("credential_generation", token["credential_generation"])
               |> put_token_scope(token["scope"])
           }}
        else
          _ -> {:error, {403, "connector credential scope is not available"}}
        end
    end
  end

  defp connector_scope(_conn, _tenant_id, _params),
    do: {:error, {403, "connector credential is required"}}

  defp registry_connect_opts(_params, scope, ""), do: credential_admission_opts(scope)

  defp registry_connect_opts(_params, scope, process_instance_id),
    do: [process_instance_id: process_instance_id] ++ credential_admission_opts(scope)

  # Threads the credential expiry into the Registry admission so the recheck
  # is enforced by a pre-CAS check plus exact post-CAS compensation:
  # auth-then-pause cannot become a serving owner or retire its predecessor.
  defp credential_admission_opts(scope) do
    []
    |> maybe_put_opt(:token_expires_at, Map.get(scope, :token_expires_at))
    |> maybe_put_opt(:credential_generation, Map.get(scope, :credential_generation))
    |> maybe_put_opt(:registration_token_hash, Map.get(scope, :token_hash))
    |> maybe_put_opt(:connector_scope, Map.get(scope, :connector_scope))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp connector_process_instance_id(conn) do
    conn
    |> get_req_header(@connector_instance_header)
    |> List.first()
    |> trimmed()
    |> case do
      id when byte_size(id) <= 128 -> id
      _ -> ""
    end
  end

  defp validate_connector_token_scope(_token, tenant_id, group) do
    case Salix.Control.Groups.get(group, tenant_id) do
      {:ok, _group} -> :ok
      _ -> {:error, :not_found}
    end
  end

  # The credential's capability scope is server-authoritative: it travels from
  # the token record into the durable registry meta, never from anything the
  # connector claims about itself.
  defp put_token_scope(meta, scope) when is_binary(scope) and scope != "",
    do: Map.put(meta, "scope", scope)

  defp put_token_scope(meta, _scope), do: meta

  defp connector_reported_scope(params) do
    case Map.fetch(params, "scope") do
      :error -> {:ok, nil}
      {:ok, scope} when scope in ["", "local_file_read"] -> {:ok, scope}
      {:ok, _invalid} -> {:error, "unsupported connector-reported scope"}
    end
  end

  defp default_to("", fallback), do: fallback
  defp default_to(v, _fallback), do: v
end
