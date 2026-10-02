defmodule Comma.Devices do
  @moduledoc "Workspace-scoped device settings backed by the Salix device owner."

  alias SalixEnv.Control

  def page(user, session, workspace_id, params) do
    with {:ok, workspace} <- scope(user, session, workspace_id),
         {:ok, limit} <- page_limit(params["limit"]),
         {:ok, page} <-
           Control.page_group_environments(
             workspace["default_group_id"],
             workspace["salix_tenant_id"],
             limit: limit,
             cursor: params["cursor"]
           ) do
      {:ok, %{devices: Enum.map(page.records, &public_device/1), next_cursor: page.next_cursor}}
    end
  end

  def get(user, session, workspace_id, device_id) do
    with {:ok, workspace} <- scope(user, session, workspace_id),
         {:ok, device} <-
           Control.get_environment(
             device_id,
             workspace["default_group_id"],
             workspace["salix_tenant_id"]
           ) do
      {:ok, public_device(device)}
    end
  end

  def probe(_user, %{"restricted" => true}, _workspace_id, _device_id),
    do: {:error, :forbidden}

  def probe(user, session, workspace_id, device_id) do
    with {:ok, workspace} <- scope(user, session, workspace_id),
         {:ok, device} <-
           Control.get_environment(
             device_id,
             workspace["default_group_id"],
             workspace["salix_tenant_id"]
           ),
         :ok <- allow_probe(device),
         :ok <-
           Control.discover_runtimes(
             device_id,
             workspace["default_group_id"],
             workspace["salix_tenant_id"]
           ),
         {:ok, updated} <-
           Control.get_environment(
             device_id,
             workspace["default_group_id"],
             workspace["salix_tenant_id"]
           ) do
      {:ok, public_device(updated)}
    else
      {:error, reason} when reason in [:forbidden, :not_found] -> {:error, reason}
      {:error, _} -> {:error, {:unavailable, "Device runtime check failed"}}
    end
  end

  defp allow_probe(%{"status" => "connected"} = device) do
    if public_device(device)["allows_operations"], do: :ok, else: {:error, :forbidden}
  end

  defp allow_probe(_device), do: {:error, :connector_disconnected}

  def set_access(_user, %{"restricted" => true}, _workspace_id, _device_id, _params),
    do: {:error, :forbidden}

  def set_access(user, session, workspace_id, device_id, %{"allow_operations" => allow})
      when is_boolean(allow) do
    with {:ok, workspace} <- scope(user, session, workspace_id),
         {:ok, device} <-
           Control.get_environment(
             device_id,
             workspace["default_group_id"],
             workspace["salix_tenant_id"]
           ),
         {:ok, %{"allows_operations" => ^allow}} <-
           SalixEnv.Connector.Live.request(device["connector_run_id"], "device_access", %{
             "allow_operations" => allow
           }) do
      {:ok, %{allows_operations: allow}}
    else
      {:ok, _} -> {:error, :device_access_unavailable}
      {:error, _} = error -> error
    end
  end

  def set_access(_, _, _, _, _),
    do: {:error, {:bad_request, "allow_operations must be a boolean"}}

  def rename(_user, %{"restricted" => true}, _, _, _), do: {:error, :forbidden}

  def rename(user, session, workspace_id, device_id, params) do
    with {:ok, workspace} <- scope(user, session, workspace_id),
         {:ok, device} <-
           Control.rename_environment(
             device_id,
             workspace["default_group_id"],
             workspace["salix_tenant_id"],
             params["name"]
           ) do
      {:ok, public_device(device)}
    end
  end

  def remove(_user, %{"restricted" => true}, _, _), do: {:error, :forbidden}

  def remove(user, session, workspace_id, device_id) do
    with {:ok, workspace} <- scope(user, session, workspace_id),
         {:ok, _device} <-
           Control.remove_environment(
             device_id,
             workspace["default_group_id"],
             workspace["salix_tenant_id"]
           ) do
      {:ok, %{removed: true}}
    end
  end

  defp scope(user, session, workspace_id) do
    with {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace) do
      {:ok, workspace}
    end
  end

  defp page_limit(nil), do: {:ok, 20}
  defp page_limit(value) when is_integer(value) and value in 1..50, do: {:ok, value}

  defp page_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> page_limit(limit)
      _ -> {:error, {:bad_request, "limit must be between 1 and 50"}}
    end
  end

  defp page_limit(_), do: {:error, {:bad_request, "limit must be between 1 and 50"}}

  # Control has already removed private commands, paths and credentials. Keep
  # this client projection narrow; discovery does not trigger provider probes.
  defp public_device(device) do
    device
    |> Map.take(
      ~w(device_id name alias status os arch connected_at disconnected_at updated_at environments device_runtimes system_info)
    )
    |> Map.put("name", device_display_name(device))
    |> Map.put(
      "allows_operations",
      Enum.any?(device["environments"] || [], fn env ->
        env["requires_permission"] == false
      end)
    )
  end

  # Hostnames belong to the authorized settings projection, not the Agent API name.
  defp device_display_name(device) do
    Enum.find(
      [
        device["display_name"],
        get_in(device, ["system_info", "hostname"]),
        device["name"],
        device["device_id"]
      ],
      fn value ->
        is_binary(value) and String.trim(value) != ""
      end
    )
  end
end
