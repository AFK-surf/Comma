defmodule SalixStore.Stations do
  @moduledoc """
  The station roster Salix keeps as the stations' control plane: the
  still.fail stations of each Group (docs/architecture/DOMAIN_CONCEPTS.md,
  "Station"), keyed by `(tenant_id, group_id)`. A Salix Group is the
  workspace: every station, on someone's machine (`device`) or on the Group's
  Cloud VM (`cloud_vm`), is a station of its Group. The id that workspace
  goes by on the wire is kept per Group (`SalixStore.Stations.Workspaces`).

  It holds no membership logic: who may enroll, rename or remove is decided
  by the caller, through the product's `SalixStore.StationMembers`, and so is
  whether a Group's workspace is in use: a station is served only while it is
  (`active_station/1`). A Group holds at most 64
  non-removed stations. A station is in one Group at a time: admitting it to
  another Group moves it there. Removing a station or moving it deletes the
  Task index it sent (`SalixStore.StationTaskIndex`). The credential keys and
  revocations stations are told live in `SalixStore.Stations.SigningKeys` and
  `SalixStore.Stations.Revocations`.

  This module only stores. Telling connected stations about a change
  (`SalixStore.Stations.Events`) belongs to the caller, from the facts each
  write returns.
  """

  import Ecto.Query

  alias SalixStore.{Repo, StationMembers, StationTaskIndex}
  alias SalixStore.Stations.{Credential, Revocations, SigningKeys, Station, Workspaces}

  @max_stations 64

  @doc "How many non-removed stations a Group holds at most."
  def max_stations, do: @max_stations

  @doc "Whether `value` is a station id: a hex Ed25519 public key."
  def valid_id?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  # ── roster ──────────────────────────────────────────────────────────────

  @doc "Non-removed stations of a Group in enrollment order."
  def roster(tenant_id, group_id) when is_binary(tenant_id) and is_binary(group_id) do
    Repo.all(
      from(s in in_group(tenant_id, group_id),
        order_by: [asc: s.enrolled_at, asc: s.id],
        limit: ^@max_stations
      )
    )
  end

  @doc "The peers a station of the Group is told (presence `peers`)."
  def peers(tenant_id, group_id) do
    Repo.all(
      from(s in in_group(tenant_id, group_id),
        order_by: [asc: s.enrolled_at, asc: s.id],
        limit: ^@max_stations,
        select: %{"id" => s.id, "name" => s.name, "version" => s.version}
      )
    )
  end

  @doc """
  An enrolled, non-removed station of a Group whose workspace is in use, as
  the product that owns the Group answers
  (`SalixStore.StationMembers.workspace_active?/2`). A station of a suspended,
  deleted or archived workspace is answered as a removed one.
  """
  def active_station(station_id) do
    with true <- valid_id?(station_id),
         %Station{} = station <-
           Repo.one(from(s in Station, where: s.id == ^station_id and is_nil(s.removed_at))),
         true <- StationMembers.workspace_active?(station.tenant_id, station.group_id) do
      {:ok, station}
    else
      _ -> {:error, :station_removed}
    end
  end

  @doc """
  `:ok` when the Group has room for one more station, not counting
  `station_id` (a station already there takes no new room).
  """
  def room_for(tenant_id, group_id, station_id \\ nil) do
    query = in_group(tenant_id, group_id)
    query = if station_id, do: from(s in query, where: s.id != ^station_id), else: query

    if Repo.aggregate(query, :count) < @max_stations,
      do: :ok,
      else: {:error, :too_many_stations}
  end

  # ── admission ───────────────────────────────────────────────────────────

  @doc """
  Admits an enrolled device station to the Group, once its enrollment token
  is consumed: a station already in the Group keeps its
  row and only takes the reported version; otherwise it takes room in the
  Group and starts afresh, moved out of the Group it was in.

  `attrs`: `:name` (default "Station"), `:version`, `:enrolled_by` (the
  product user id). Answers `{:ok, station, moved_from}`, `moved_from` being
  `{tenant_id, group_id}` of the Group it left, else nil.
  """
  def admit(tenant_id, group_id, station_id, attrs \\ %{}) do
    with true <- valid_id?(station_id) || {:error, :invalid_request},
         {:ok, name} <- name(Map.get(attrs, :name)) do
      version = version(Map.get(attrs, :version))

      Repo.transaction(fn ->
        existing = lock(station_id)
        now = SystemsClock.utc_now()

        if in_group?(existing, tenant_id, group_id) do
          {:ok, row} =
            Repo.update(Ecto.Changeset.change(existing, version: version || existing.version))

          {row, nil}
        else
          room!(tenant_id, group_id, station_id)

          moved_from =
            if existing && is_nil(existing.removed_at),
              do: {existing.tenant_id, existing.group_id}

          if existing, do: StationTaskIndex.delete_station(station_id)

          row =
            write(existing, station_id, %{
              tenant_id: tenant_id,
              group_id: group_id,
              name: name,
              version: version,
              kind: "device",
              enrolled_by: Map.get(attrs, :enrolled_by),
              enrolled_at: now,
              removed_at: nil,
              last_seen_at: nil,
              index_epoch: nil,
              index_through: nil
            })

          {row, moved_from}
        end
      end)
      |> case do
        {:ok, {row, moved_from}} -> {:ok, row, moved_from}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Places the station of the Group's Cloud VM: no enrollment token, so
  `enrolled_by` is nil. A key placed in another Group is refused
  (`:station_elsewhere`) and never moved. When the VM's key changed, the
  Group's previous Cloud VM station (`previous_station_id`) is removed.
  Answers `{:ok, station, replaced}`, `replaced` being the removed station's
  id, else nil.
  """
  def place_cloud_station(tenant_id, group_id, station_id, previous_station_id, version) do
    with true <- valid_id?(station_id) || {:error, :invalid_request} do
      version = version(version)

      Repo.transaction(fn ->
        existing = lock(station_id)
        now = SystemsClock.utc_now()

        if existing && is_nil(existing.removed_at) &&
             not in_group?(existing, tenant_id, group_id),
           do: Repo.rollback(:station_elsewhere)

        replaced =
          remove_replaced_cloud_station(tenant_id, group_id, station_id, previous_station_id, now)

        row =
          if existing && is_nil(existing.removed_at) do
            Repo.update!(Ecto.Changeset.change(existing, version: version || existing.version))
          else
            room!(tenant_id, group_id, station_id)

            write(existing, station_id, %{
              tenant_id: tenant_id,
              group_id: group_id,
              name: "Cloud VM",
              version: version,
              kind: "cloud_vm",
              enrolled_by: nil,
              enrolled_at: now,
              removed_at: nil,
              last_seen_at: nil,
              index_epoch: nil,
              index_through: nil
            })
          end

        {row, replaced}
      end)
      |> case do
        {:ok, {row, replaced}} -> {:ok, row, replaced}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Only a station the control plane placed in this Group is replaced.
  defp remove_replaced_cloud_station(tenant_id, group_id, station_id, previous_station_id, now)
       when is_binary(previous_station_id) and previous_station_id != station_id do
    case Repo.update_all(
           from(s in in_group(tenant_id, group_id),
             where: s.id == ^previous_station_id and s.kind == "cloud_vm"
           ),
           set: [removed_at: now, updated_at: now]
         ) do
      {1, _} ->
        StationTaskIndex.delete_station(previous_station_id)
        previous_station_id

      {0, _} ->
        nil
    end
  end

  defp remove_replaced_cloud_station(_tenant_id, _group_id, _station_id, _previous, _now),
    do: nil

  # ── changes ─────────────────────────────────────────────────────────────

  @doc "Renames a non-removed station of the Group."
  def rename(tenant_id, group_id, station_id, name) do
    with {:ok, name} <- clean_name(name),
         {1, [station]} <-
           Repo.update_all(
             from(s in in_group(tenant_id, group_id), where: s.id == ^station_id, select: s),
             set: [name: name, updated_at: SystemsClock.timestamp(:utc_datetime_usec)]
           ) do
      {:ok, station}
    else
      {0, _} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Removes a station of the Group: its signed requests answer
  `station_removed`, and the Task index it sent is deleted.
  """
  def remove(tenant_id, group_id, station_id) do
    now = SystemsClock.utc_now()

    Repo.transaction(fn ->
      case Repo.update_all(
             from(s in in_group(tenant_id, group_id), where: s.id == ^station_id),
             set: [removed_at: now, updated_at: now]
           ) do
        {1, _} -> StationTaskIndex.delete_station(station_id)
        {0, _} -> Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── presence ────────────────────────────────────────────────────────────

  @doc """
  The presence `state` frame of a station, read from the owner rows. Its
  `workspace` is the id its Group's stations are told and `workspace_was` the
  ids they were told before (`SalixStore.Stations.Workspaces`);
  `workspace_name` is the name the product that owns the Group gives it
  (`SalixStore.StationMembers`); then its Group's peers, the keys credentials
  are verified with and the Group's revocations. `extra` carries what the
  serving product adds (origin, relay URLs, gateway keys).
  """
  def presence_state(station_id, extra \\ %{}) do
    with {:ok, station} <- active_station(station_id),
         {:ok, _signer} <- SigningKeys.signer() do
      frame =
        extra
        |> Map.merge(workspace(station))
        |> Map.merge(%{
          "type" => "state",
          "name" => station.name,
          "peers" => peers(station.tenant_id, station.group_id),
          "grant_keys" => SigningKeys.grant_keys(),
          "revocations" => Revocations.list(station.tenant_id, station.group_id)
        })

      {:ok, frame, station}
    end
  end

  @doc """
  What a station is told when it is admitted to its Group (the enroll
  answer): its workspace as in the `state` frame, and the keys member
  credentials are verified with. A signer is made first, so the station pins
  a key set that can sign.
  """
  def placement(%Station{} = station) do
    with {:ok, _signer} <- SigningKeys.signer() do
      {:ok,
       Map.merge(workspace(station), %{
         "name" => station.name,
         "station" => station.id,
         "grant_keys" => SigningKeys.grant_keys()
       })}
    end
  end

  # The workspace a station is told it is in: the one place the wire's
  # `workspace` comes from.
  defp workspace(%Station{tenant_id: tenant_id, group_id: group_id}) do
    told = Workspaces.told(tenant_id, group_id)

    %{
      "workspace" => told.id,
      "workspace_was" => told.was,
      "workspace_name" => StationMembers.workspace_name(tenant_id, group_id)
    }
  end

  @doc "The workspace id the Group's stations are told now (`SalixStore.Stations.Workspaces`)."
  def workspace_id(tenant_id, group_id), do: Workspaces.told(tenant_id, group_id).id

  # ── members ─────────────────────────────────────────────────────────────

  @doc """
  A member credential for one client device (contract §4), for a user the
  product that owns the Group gives a role in it (`SalixStore.StationMembers`);
  `{:error, :not_found}` for anyone else. Its `ws` is the workspace id the
  Group's stations are told. `user`
  has `"id"`, `"email"` and `"name"`; `session` has the `"id"` and
  `"expires_at"` (unix seconds) of the product session that asks, so the
  credential ends with that session and a revoked session takes it back.
  """
  def issue_credential(tenant_id, group_id, user, device, session)
      when is_map(user) and is_map(session) do
    with {:ok, role} <- member_role(tenant_id, group_id, user["id"]),
         true <- valid_id?(device) || {:error, :invalid_device} do
      Credential.issue(
        %{
          "sub" => user["id"],
          "email" => user["email"],
          "name" => user["name"] || "",
          "ws" => workspace_id(tenant_id, group_id),
          "role" => role,
          "device" => device,
          "sid" => session["id"]
        },
        session["expires_at"]
      )
    end
  end

  defp member_role(tenant_id, group_id, user_id) do
    case StationMembers.role(tenant_id, group_id, user_id) do
      {:ok, role} -> {:ok, role}
      :none -> {:error, :not_found}
    end
  end

  @doc "A presence socket opened: last seen now, and the version it reports."
  def connected(station_id, version) do
    now = SystemsClock.utc_now()
    set = [last_seen_at: now, updated_at: now]
    set = if v = version(version), do: Keyword.put(set, :version, v), else: set
    Repo.update_all(from(s in Station, where: s.id == ^station_id), set: set)
    :ok
  end

  @doc "A presence socket closed: last seen now."
  def disconnected(station_id) do
    Repo.update_all(from(s in Station, where: s.id == ^station_id),
      set: [last_seen_at: SystemsClock.utc_now()]
    )

    :ok
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp in_group(tenant_id, group_id) do
    from(s in Station,
      where: s.tenant_id == ^tenant_id and s.group_id == ^group_id and is_nil(s.removed_at)
    )
  end

  defp in_group?(%Station{removed_at: nil} = s, tenant_id, group_id),
    do: s.tenant_id == tenant_id and s.group_id == group_id

  defp in_group?(_station, _tenant_id, _group_id), do: false

  defp lock(station_id),
    do: Repo.one(from(s in Station, where: s.id == ^station_id, lock: "FOR UPDATE"))

  defp room!(tenant_id, group_id, station_id) do
    case room_for(tenant_id, group_id, station_id) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp write(nil, station_id, attrs),
    do: Repo.insert!(struct(Station, Map.put(attrs, :id, station_id)))

  defp write(%Station{} = existing, _station_id, attrs),
    do: Repo.update!(Ecto.Changeset.change(existing, attrs))

  defp name(nil), do: {:ok, "Station"}
  defp name(name), do: clean_name(name)

  defp clean_name(value) when is_binary(value) do
    name = value |> String.trim() |> String.replace(~r/\s+/u, " ")

    if name != "" and String.length(name) <= 80,
      do: {:ok, name},
      else: {:error, :invalid_name}
  end

  defp clean_name(_value), do: {:error, :invalid_name}

  defp version(value) when is_binary(value) and value != "", do: String.slice(value, 0, 40)
  defp version(_value), do: nil
end
