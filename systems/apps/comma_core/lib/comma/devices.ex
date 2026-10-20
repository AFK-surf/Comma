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

  @doc """
  Settings › Devices: one page of the signed-in user's own computers that
  connected at least once, and on the first page the Workspace's Cloud VM
  (`cloud_vm`, nil when it has none). Other members' computers and install
  commands never used are not listed.
  """
  def computers(user, session, workspace_id, params) do
    with {:ok, workspace} <- scope(user, session, workspace_id),
         {:ok, limit} <- page_limit(params["limit"]),
         {:ok, page} <-
           Control.page_owned_environments(
             workspace["default_group_id"],
             workspace["salix_tenant_id"],
             user["id"],
             limit: limit,
             cursor: params["cursor"]
           ),
         {:ok, cloud_vm} <- cloud_vm(workspace, params["cursor"]) do
      {:ok,
       %{
         devices: Enum.map(page.records, &public_device/1),
         cloud_vm: cloud_vm && public_device(cloud_vm),
         next_cursor: page.next_cursor
       }}
    end
  end

  defp cloud_vm(workspace, nil),
    do:
      Control.group_compute_environment(
        workspace["default_group_id"],
        workspace["salix_tenant_id"]
      )

  defp cloud_vm(_workspace, _cursor), do: {:ok, nil}

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

  @access_levels ~w(off read full)

  @doc """
  Sets a computer's one access value (`off`, `read` or `full`), which its
  station's device connection and device tools share. Only the computer's
  owner sets it. The body is `{access}`, or the `{allow_operations}` boolean of
  clients from before: true is full, false is read (an Off computer stays Off).

  A station that reports its access (`capabilities.access`) takes the value
  as asked. An older station or Go connector knows two levels: Read and Full
  go to it as `allow_operations`, and Off is refused with its upgrade reason
  (`station_outdated` or `device_needs_station`), nothing changed.
  """
  def set_access(_user, %{"restricted" => true}, _workspace_id, _device_id, _params),
    do: {:error, :forbidden}

  def set_access(user, session, workspace_id, device_id, params) do
    with {:ok, wanted} <- access_request(params),
         {:ok, workspace} <- scope(user, session, workspace_id),
         {:ok, device} <-
           Control.get_owned_environment(
             device_id,
             workspace["default_group_id"],
             workspace["salix_tenant_id"],
             user["id"]
           ),
         {:ok, request} <- connector_access_request(device, wanted),
         {:ok, result} <-
           SalixEnv.Connector.Live.request(device["connector_run_id"], "device_access", request),
         {:ok, access} <- confirmed_access(wanted, result) do
      {:ok, %{access: access, allows_operations: access == "full"}}
    end
  end

  defp access_request(%{"access" => access}) when access in @access_levels,
    do: {:ok, {:level, access}}

  defp access_request(%{"allow_operations" => allow}) when is_boolean(allow),
    do: {:ok, {:allow, allow}}

  defp access_request(_params),
    do: {:error, {:bad_request, "access must be off, read or full"}}

  defp connector_access_request(device, {:level, access}) do
    cond do
      reports_access?(device) -> {:ok, %{"access" => access}}
      access == "off" -> {:error, outdated_access(device)}
      true -> {:ok, %{"allow_operations" => access == "full"}}
    end
  end

  # A station that reports its access maps the old boolean itself (it knows Off).
  defp connector_access_request(_device, {:allow, allow}),
    do: {:ok, %{"allow_operations" => allow}}

  defp reports_access?(device), do: get_in(device, ["capabilities", "access"]) in @access_levels

  defp outdated_access(device) do
    case SalixStore.StationReadiness.check(device["capabilities"]) do
      {reason, _info} -> reason
      :ready -> :station_outdated
    end
  end

  defp confirmed_access({:level, access}, %{"access" => access}), do: {:ok, access}

  # A connector from before answers the boolean alone.
  defp confirmed_access({:level, access}, %{"allows_operations" => allow} = result)
       when not is_map_key(result, "access") and allow == (access == "full"),
       do: {:ok, access}

  defp confirmed_access({:allow, allow}, %{"access" => access, "allows_operations" => allow})
       when access in @access_levels,
       do: {:ok, access}

  defp confirmed_access({:allow, allow}, %{"allows_operations" => allow} = result)
       when not is_map_key(result, "access"),
       do: {:ok, if(allow, do: "full", else: "read")}

  defp confirmed_access(_wanted, _result), do: {:error, :device_access_unavailable}

  @screen_stream_start_fields ~w(sdp target apps display control background)

  @doc """
  Relays one screen stream signaling step to the device's Connector.

  `ice` returns the ICE servers for both peers. `start` carries the viewer's
  WebRTC offer with those servers and returns the Connector's answer. Media and
  input then travel peer to peer. The device must allow operations.
  """
  def screen_stream(_user, %{"restricted" => true}, _workspace_id, _device_id, _params),
    do: {:error, :forbidden}

  def screen_stream(user, session, workspace_id, device_id, params) do
    with {:ok, request} <- screen_stream_request(params),
         {:ok, workspace} <- scope(user, session, workspace_id),
         {:ok, device} <-
           Control.get_environment(
             device_id,
             workspace["default_group_id"],
             workspace["salix_tenant_id"]
           ),
         :ok <- allow_probe(device),
         {:ok, %{"ok" => true} = result} <- screen_stream_step(device, request) do
      {:ok, Map.take(result, ~w(sdp stream_id geometry ice_servers))}
    else
      {:ok, %{"error" => message}} when is_binary(message) -> {:error, {:conflict, message}}
      {:ok, _} -> {:error, {:unavailable, "Screen stream failed"}}
      {:error, :connector_disconnected} -> {:error, {:unavailable, "Device is offline"}}
      {:error, reason} when reason in [:forbidden, :not_found] -> {:error, reason}
      {:error, {:bad_request, _} = reason} -> {:error, reason}
      {:error, _} -> {:error, {:unavailable, "Screen stream failed"}}
    end
  end

  defp screen_stream_step(_device, %{"op" => "ice"}),
    do: {:ok, %{"ok" => true, "ice_servers" => Comma.ScreenStreamIce.servers()}}

  defp screen_stream_step(device, request),
    do: SalixEnv.Connector.Live.request(device["connector_run_id"], "screen_stream", request)

  defp screen_stream_request(%{"op" => "ice"}), do: {:ok, %{"op" => "ice"}}

  defp screen_stream_request(%{"op" => "start", "sdp" => sdp} = params)
       when is_binary(sdp) and byte_size(sdp) in 1..65_536 do
    request = params |> Map.take(@screen_stream_start_fields) |> Map.put("op", "start")

    case params["ice_servers"] do
      servers when is_list(servers) and length(servers) in 1..4 ->
        {:ok, Map.put(request, "ice_servers", servers)}

      _ ->
        {:ok, request}
    end
  end

  defp screen_stream_request(%{"op" => "stop", "stream_id" => stream_id})
       when is_binary(stream_id) and byte_size(stream_id) in 1..64 do
    {:ok, %{"op" => "stop", "stream_id" => stream_id}}
  end

  defp screen_stream_request(_params),
    do: {:error, {:bad_request, "op must be ice, start with sdp, or stop with stream_id"}}

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
  # Readiness and models come from the device record already read, so a page
  # makes no call per device. `station_id` is the station the device's
  # Connector proved it runs, absent until one did.
  defp public_device(device) do
    device
    |> Map.take(
      ~w(device_id station_id name alias status os arch connected_at disconnected_at updated_at environments device_runtimes system_info)
    )
    |> Map.put("name", display_name(device))
    |> Map.put(
      "allows_operations",
      Enum.any?(device["environments"] || [], fn env ->
        env["requires_permission"] == false
      end)
    )
    |> Map.put("tasks_readiness", tasks_readiness(device))
    |> Map.put("task_models", task_models(device))
    |> put_access(device)
  end

  # "offline" while the Connector is disconnected. Otherwise "ready", or why
  # the station cannot take Tasks (`SalixStore.StationReadiness`):
  # "device_needs_station" (the old connector) or "station_outdated".
  defp tasks_readiness(%{"status" => "connected"} = device) do
    case SalixStore.StationReadiness.check(device["capabilities"]) do
      :ready -> "ready"
      {reason, _info} -> Atom.to_string(reason)
    end
  end

  defp tasks_readiness(_device), do: "offline"

  # The models the station reports it can run, by runtime (`codex`, `claude`),
  # as Control made public. Empty when the station reports none.
  defp task_models(device) do
    case device["capabilities"] do
      %{"task_models" => %{} = models} -> models
      _none -> %{}
    end
  end

  # The computer's one access value as its station reports it; a connector
  # from before has two levels, Full when it allows operations, else Read.
  defp put_access(public, device) do
    access =
      case get_in(device, ["capabilities", "access"]) do
        level when level in @access_levels -> level
        _ -> if public["allows_operations"], do: "full", else: "read"
      end

    Map.put(public, "access", access)
  end

  @doc """
  The name members see for a device: its display name, else its hostname.
  Hostnames belong to the authorized settings projection, not the Agent API
  name.
  """
  def display_name(device) do
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
