defmodule Comma.ChatDevices do
  @moduledoc "Read-only chat navigation over the authorized Device projection."
  alias SalixStore.CasRecord

  @page_size 6
  @view_bytes 16_384
  @ttl 900

  # One replaceable navigation projection per IM Connect, shared across nodes.
  # It stores IDs and cursors, never device facts or authorization. The revision
  # only prevents an old numbered choice from selecting a new list's device.
  def browse(user, workspace, connect_id, action) do
    with {:ok, _} <- Comma.Workspaces.authorize(user, %{}, workspace["id"]) do
      case action do
        "list" -> page(user, workspace, connect_id, nil, nil)
        value -> navigate(user, workspace, connect_id, value)
      end
    end
  end

  defp navigate(user, workspace, connect_id, action) do
    with [revision, selection] <- String.split(action, ":", parts: 2),
         {:ok, view, _} <- CasRecord.get_bounded(key(connect_id), @view_bytes),
         true <-
           view["revision"] == revision and view["user_id"] == user["id"] and
             view["workspace_id"] == workspace["id"] and is_integer(view["expires_at"]) and
             view["expires_at"] > now() do
      case selection do
        "refresh" ->
          page(user, workspace, connect_id, view["cursor"], revision)

        "first" ->
          page(user, workspace, connect_id, nil, revision)

        "next" ->
          if is_binary(view["next_cursor"]),
            do: page(user, workspace, connect_id, view["next_cursor"], revision),
            else: {:error, :device_view_expired}

        index ->
          detail(user, workspace, view, index)
      end
    else
      _ -> {:error, :device_view_expired}
    end
  end

  defp page(user, workspace, connect_id, cursor, expected_revision) do
    with {:ok, page} <-
           Comma.Devices.page(user, %{}, workspace["id"], %{
             "limit" => @page_size,
             "cursor" => cursor
           }),
         view = %{
           "user_id" => user["id"],
           "workspace_id" => workspace["id"],
           "revision" => Base.encode16(:crypto.strong_rand_bytes(6)),
           "expires_at" => now() + @ttl,
           "cursor" => cursor,
           "next_cursor" => page.next_cursor,
           "device_ids" => Enum.map(page.devices, & &1["device_id"])
         },
         true <- byte_size(Jason.encode!(view)) <= @view_bytes,
         {:ok, _} <-
           CasRecord.update(
             key(connect_id),
             fn current ->
               if is_nil(expected_revision) or
                    (is_map(current) and current["revision"] == expected_revision),
                  do: view,
                  else: {:error, :device_view_expired}
             end,
             attempts: 2
           ) do
      {:ok, %{kind: :list, devices: page.devices, view: view, observed_at: now()}}
    else
      false -> {:error, :device_view_unavailable}
      other -> other
    end
  end

  defp detail(user, workspace, view, index) do
    with {number, ""} when number in 1..@page_size <- Integer.parse(index),
         id when is_binary(id) <- Enum.at(view["device_ids"], number - 1),
         {:ok, device} <- Comma.Devices.get(user, %{}, workspace["id"], id) do
      {:ok, %{kind: :detail, device: device, index: number, view: view, observed_at: now()}}
    else
      _ -> {:error, :device_view_expired}
    end
  end

  defp key(connect_id),
    do: "comma/chat_device_views/" <> Base.url_encode64(connect_id, padding: false) <> ".json"

  defp now, do: System.system_time(:second)
end
