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
             "default_name" => "Monoid",
             "meta" => Map.merge(meta, %{"surface" => "comma", "device_kind" => "stillfail"})
           }) do
      {:ok, "comma " <> token["server"] <> " " <> token["token"]}
    end
  end

  @doc """
  The Group's still.fail devices: id, name (what its station called itself
  as it connected: its still.fail workspace and its own name; nil before it
  first connected), its still.fail workspace's id (nil before it first
  connected), whether connected now, when last connected, and the models its
  Tasks may run (`task_models`, by runtime).
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
      "workspace_id" => get_in(device, ["meta", "stillfail_workspace"]),
      "connected" => device["status"] == "connected",
      "connected_at" => device["connected_at"],
      "task_models" => task_models(get_in(device, ["meta", "capabilities", "task_models"])),
      "workspace" => workspace(get_in(device, ["meta", "capabilities", "stillfail_workspace"]))
    }
    |> maybe_put_owner_email(owner_email(device))
    |> maybe_put_owner_active_at(owner_active_at(device))
  end

  @doc """
  Bound still.fail owner email per device_id for the Group's still.fail
  stations (`%{device_id => normalized_email}`). Reads an explicit override in
  `meta.stillfail_owner_email` first, then the station-reported
  `meta.capabilities.stillfail_owner_email`.
  """
  def owner_emails_by_device(group_id) when is_binary(group_id) do
    case Registry.list_by_group(group_id) do
      {:ok, devices} ->
        for device <- devices,
            stillfail?(device),
            email = owner_email(device),
            is_binary(email),
            into: %{},
            do: {device["device_id"], email}

      _ ->
        %{}
    end
  end

  def owner_emails_by_device(_group_id), do: %{}

  @doc """
  Last reported still.fail owner activity timestamp (Unix milliseconds) per
  connected still.fail device in the Group (`%{device_id => unix_ms}`).
  """
  def owner_active_at_by_device(group_id) when is_binary(group_id) do
    case Registry.list_by_group(group_id) do
      {:ok, devices} ->
        for device <- devices,
            stillfail?(device),
            device["status"] == "connected",
            ts = owner_active_at(device),
            is_integer(ts),
            into: %{},
            do: {device["device_id"], ts}

      _ ->
        %{}
    end
  end

  def owner_active_at_by_device(_group_id), do: %{}

  @doc """
  Map of `device_id => true` for still.fail stations in the Group that declare
  atomic `task.say` card CAS (`capabilities.task_say_cas == 1`).
  """
  def task_say_cas_by_device(group_id) when is_binary(group_id) do
    case Registry.list_by_group(group_id) do
      {:ok, devices} ->
        for device <- devices,
            stillfail?(device),
            get_in(device, ["meta", "capabilities", "task_say_cas"]) == 1,
            into: %{},
            do: {device["device_id"], true}

      _ ->
        %{}
    end
  end

  def task_say_cas_by_device(_group_id), do: %{}

  @doc """
  Map of `device_id => true` for still.fail stations in the Group that declare
  bounded chat attachment reads (`capabilities.task_read_file == 1`).
  """
  def task_read_file_by_device(group_id) when is_binary(group_id) do
    case Registry.list_by_group(group_id) do
      {:ok, devices} ->
        for device <- devices,
            stillfail?(device),
            get_in(device, ["meta", "capabilities", "task_read_file"]) == 1,
            into: %{},
            do: {device["device_id"], true}

      _ ->
        %{}
    end
  end

  def task_read_file_by_device(_group_id), do: %{}

  defp maybe_put_owner_email(map, nil), do: map
  defp maybe_put_owner_email(map, email), do: Map.put(map, "owner_email", email)

  defp maybe_put_owner_active_at(map, nil), do: map
  defp maybe_put_owner_active_at(map, ts), do: Map.put(map, "owner_active_at", ts)

  defp owner_email(device) do
    normalize_email(get_in(device, ["meta", "stillfail_owner_email"])) ||
      normalize_email(get_in(device, ["meta", "capabilities", "stillfail_owner_email"]))
  end

  defp owner_active_at(device) do
    case get_in(device, ["meta", "capabilities", "stillfail_owner_active_at"]) do
      ts when is_integer(ts) and ts > 0 -> ts
      _ -> nil
    end
  end

  defp normalize_email(value) when is_binary(value) do
    email = value |> String.trim() |> String.downcase()

    if byte_size(email) <= 200 and Regex.match?(~r/^[^\s@]+@[^\s@]+$/, email),
      do: email,
      else: nil
  end

  defp normalize_email(_value), do: nil

  # What the station says of its still.fail workspace in its metadata
  # (still.fail `station/src/comma/surface.ts` `capabilities`), again as it
  # changes: its name, its emoji, how many stations it has and what this one
  # is called. An icon image is not passed on: the clients show no remote image.
  @workspace_text 200

  defp workspace(%{"name" => name} = said) when is_binary(name) and name != "" do
    stations = said["stations"]

    %{
      "name" => String.slice(name, 0, @workspace_text),
      "emoji" => text(said["emoji"], 16),
      "station" => text(said["station"], @workspace_text),
      "station_count" => if(is_list(stations), do: length(stations))
    }
  end

  defp workspace(_said), do: nil

  defp text(value, most) when is_binary(value) and value != "", do: String.slice(value, 0, most)
  defp text(_value, _most), do: nil

  # The runtimes its Tasks may run and, for each, the model ids its profiles
  # name; a runtime with no ids runs its own default (still.fail
  # `station/src/comma/surface.ts` `capabilities`).
  defp task_models(models) when is_map(models) do
    for {runtime, ids} <- models, is_binary(runtime), into: %{} do
      {runtime, for(id <- List.wrap(ids), is_binary(id), do: id)}
    end
  end

  defp task_models(_models), do: %{}

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
           do: device["display_name"] || get_in(device, ["meta", "name"]) || "Monoid"
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
