defmodule SalixEnv.StillfailDevices do
  @moduledoc """
  The still.fail stations of a Group: devices with `device_kind` `stillfail`,
  each made with the line its station connects with, `comma <server> <token>`,
  which a member pastes into the station's Comma connect. Connected, the
  station takes the Group's Tasks and sends the Stats index of its still.fail
  workspace (`SalixStore.StillfailStations`). Comma's still.fail plugin and
  the CFT Agent Swarm still.fail page both make and remove them here.
  """

  alias SalixEnv.{ConnectorTokens, Registry}

  @doc """
  A new still.fail device of the Group and the line its station connects
  with; `meta`, what else the device says (who made it, for which product).
  The token is in the line only, never kept.
  """
  def connect_line(group_id, tenant_id, meta \\ %{}) when is_map(meta) do
    with {:ok, token} <-
           ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
             # (not pinned: the station says which still.fail workspace it is as it connects)
             "default_name" => "still.fail",
             "meta" => Map.merge(meta, %{"surface" => "comma", "device_kind" => "stillfail"})
           }) do
      {:ok, "comma " <> token["server"] <> " " <> token["token"]}
    end
  end

  @doc """
  The Group's still.fail devices: id, name (what its station called itself
  as it connected: its still.fail workspace and its own name; nil before it
  first connected), whether connected now, when last connected.
  """
  def list(group_id) when is_binary(group_id) do
    with {:ok, devices} <- Registry.list_by_group(group_id) do
      {:ok, for(device <- devices, stillfail?(device), do: public(device))}
    end
  end

  @doc """
  `list/1` within one bounded read of the Group's devices (the first page of
  `SalixEnv.Registry.page_by_group/2`), for an agent's tool: `{:ok, stations,
  more?}`, `more?` when the Group has devices that read did not reach.
  """
  def first_page(group_id) when is_binary(group_id) do
    with {:ok, %{records: devices, next_cursor: next}} <-
           Registry.page_by_group(group_id, keep: &stillfail?/1, limit: 100) do
      {:ok, Enum.map(devices, &public/1), not is_nil(next)}
    end
  end

  defp public(device) do
    %{
      "id" => device["device_id"],
      "name" =>
        if(device["connected_at"],
          do: device["display_name"] || get_in(device, ["meta", "name"])
        ),
      "connected" => device["status"] == "connected",
      "connected_at" => device["connected_at"]
    }
  end

  @doc """
  The record of the still.fail station a Connector run `view` is of, for the
  index pages it sends (`SalixStore.StillfailStations`); `:not_this_group`
  when the run's Device is not a still.fail one.
  """
  def station(%{tenant_id: tenant, group_id: group, device_id: device}) do
    with {:ok, record} <- Registry.get_device(tenant, group, device),
         true <- stillfail?(record) || {:error, :not_this_group} do
      SalixStore.StillfailStations.ensure(tenant, group, device)
    else
      {:error, :not_found} -> {:error, :not_this_group}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The name of another still.fail device of the Group that is of the
  still.fail `workspace` (as its station said connecting), else nil: a Group
  takes one connect of a workspace, so the workspace's usage and chats count
  once.
  """
  def workspace_held(group_id, device_id, workspace)
      when is_binary(group_id) and is_binary(device_id) and is_binary(workspace) do
    with {:ok, devices} <- Registry.list_by_group(group_id) do
      Enum.find_value(devices, fn device ->
        if stillfail?(device) and device["device_id"] != device_id and
             get_in(device, ["meta", "stillfail_workspace"]) == workspace,
           do: device["display_name"] || get_in(device, ["meta", "name"]) || "still.fail"
      end)
    else
      _ -> nil
    end
  end

  @doc """
  Removes one still.fail device of the Group, its credential and its
  statistics: that station's connect stops, the Group's others stay.
  `{:error, :not_found}` for a device that is not one of them.
  """
  def remove(group_id, device_id) when is_binary(group_id) and is_binary(device_id) do
    with {:ok, devices} <- Registry.list_by_group(group_id) do
      case Enum.find(devices, &(&1["device_id"] == device_id and stillfail?(&1))) do
        nil -> {:error, :not_found}
        device -> ConnectorTokens.remove_device(device)
      end
    end
  end

  @doc "Removes the Group's still.fail devices, their credentials and their statistics."
  def remove_all(group_id) when is_binary(group_id) do
    with {:ok, devices} <- Registry.list_by_group(group_id) do
      devices
      |> Enum.filter(&stillfail?/1)
      |> Enum.reduce_while(:ok, fn device, :ok ->
        case ConnectorTokens.remove_device(device) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp stillfail?(device), do: get_in(device, ["meta", "device_kind"]) == "stillfail"
end
