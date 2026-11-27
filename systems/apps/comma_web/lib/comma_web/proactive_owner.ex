defmodule CommaWeb.ProactiveOwner do
  @moduledoc """
  Shared, fail-closed owner identity resolution for station-hosted Task rows
  (`SalixStore.StationTaskIndex`) read by proactive consumers (`MemberPortrait`,
  `ProactiveResearch`, `ProactiveExecution`).

  Always requires a valid `owner_email` for `owner_user_id`. Bound still.fail
  device owner emails (`SalixEnv.StillfailDevices.owner_emails_by_device/1`,
  allowing a personal owner's still.fail email to differ from their Comma
  email) are admitted ONLY when `owner_user_id` is verified as the sole owner
  and member of a single-owner personal Workspace for `group_id`. In shared or
  multi-member Workspaces, rows must match `owner_email` strictly.
  """

  @max_scan_limit 500

  @doc "Normalized lowercase owner email for `owner_user_id`, or nil."
  def owner_email(owner_user_id) when is_binary(owner_user_id) do
    case Comma.Accounts.get_user(owner_user_id) do
      {:ok, %{"email" => email}} -> normalize_email(email)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def owner_email(_owner_user_id), do: nil

  @doc """
  True only when `workspace` has `owner_user_id` as its owner and sole member.
  Only in that single-owner personal Workspace can the Group's still.fail
  station bindings be attributed unambiguously to `owner_user_id`.
  """
  def personal_workspace_owner?(%{"owner_user_id" => owner} = workspace, owner_user_id)
      when is_binary(owner_user_id) and owner == owner_user_id do
    members = workspace["members"] || []
    Enum.map(members, & &1["user_id"]) in [[], [owner_user_id]]
  end

  def personal_workspace_owner?(_workspace, _owner_user_id), do: false

  @doc """
  Bound still.fail owner email per `device_id` attributable to `owner_user_id`
  in `group_id`. Returns `%{}` unless `owner_user_id` is proven to be the sole
  owner and member of `group_id`'s Workspace (fail-closed in shared Workspaces).
  """
  def device_owner_emails(group_id, owner_user_id, workspace \\ nil)

  def device_owner_emails(group_id, owner_user_id, workspace)
      when is_binary(group_id) and is_binary(owner_user_id) do
    resolved_workspace =
      if is_map(workspace) do
        workspace
      else
        case Comma.Workspaces.get_by_group(group_id) do
          {:ok, ws} -> ws
          _ -> nil
        end
      end

    if personal_workspace_owner?(resolved_workspace, owner_user_id) do
      SalixEnv.StillfailDevices.owner_emails_by_device(group_id)
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  def device_owner_emails(_group_id, _owner_user_id, _workspace), do: %{}

  @doc "Lists up to `limit` station Task rows owned by `owner_user_id` in `group_id`."
  def owner_station_rows(group_id, owner_user_id, limit \\ 50, workspace \\ nil)
      when is_binary(group_id) and is_binary(owner_user_id) and is_integer(limit) and limit > 0 do
    case owner_email(owner_user_id) do
      nil ->
        []

      email ->
        device_emails = device_owner_emails(group_id, owner_user_id, workspace)
        scan_limit = min(max(limit * 4, 200), @max_scan_limit)

        group_id
        |> SalixStore.StationTaskIndex.list_group(scan_limit)
        |> Enum.filter(&station_row_owned_by?(&1, email, device_emails))
        |> Enum.take(limit)
    end
  rescue
    _ -> []
  end

  @doc """
  Fail-closed check that `row` was created by the owner (matching `owner_email`,
  or the station's bound `device_emails[device_id]` when the caller has already
  verified the device bindings belong solely to `owner_user_id`).
  Always rejects nil/blank `owner_email` or nil/blank `created_by`.
  """
  def station_row_owned_by?(row, owner_email, device_emails \\ %{})
      when is_map(row) and is_map(device_emails) do
    case {normalize_email(owner_email), normalize_email(field(row, :created_by, "created_by"))} do
      {norm_owner, created_by} when is_binary(norm_owner) and is_binary(created_by) ->
        created_by in matching_emails(row, norm_owner, device_emails)

      _ ->
        false
    end
  end

  @doc "Normalized owner emails valid for `row`'s device; empty when `owner_email` is nil."
  def matching_emails(row, owner_email, device_emails \\ %{})
      when is_map(row) and is_map(device_emails) do
    case normalize_email(owner_email) do
      nil ->
        []

      norm_owner ->
        device_id = field(row, :device_id, "device_id")

        [
          norm_owner,
          if(is_binary(device_id), do: normalize_email(Map.get(device_emails, device_id)))
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    end
  end

  @doc "Normalizes a valid email address to trimmed lowercase, else nil."
  def normalize_email(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.downcase()

    if byte_size(trimmed) <= 200 and Regex.match?(~r/^[^\s@]+@[^\s@]+$/, trimmed),
      do: trimmed,
      else: nil
  end

  def normalize_email(_other), do: nil

  defp field(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end
end
