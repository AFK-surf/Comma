defmodule Comma.Stations do
  @moduledoc """
  The station wire Comma serves (`/v1/comma/stations/*`, provider `comma`):
  enrollment, the presence socket's state, member credentials and the roster
  its clients see (docs/architecture/DOMAIN_CONCEPTS.md, "Station").

  Salix keeps the roster, the credential keys and the revocations
  (`SalixStore.Stations`). A station belongs to a Salix Group. The
  `workspace` id stations and credentials carry is the one Salix keeps for
  the Group (`SalixStore.Stations.Workspaces`); nothing here computes it. Who may do what in a
  Group is the answer of the product that owns it
  (`SalixStore.StationMembers`), so a BridgeForTeams Project's members are
  served as a Comma Workspace's are.

  For one release, servers of the release before still write Comma's own
  station tables: `Comma.Stations.Window` merges what they wrote into Salix
  before each read here, until the move is marked complete.

  Comma's own part is its sessions: a client names a Comma Workspace, the
  Auth Session must be unrestricted and in scope for it, and the Workspace
  gives the Group. Restricted sessions never pass.
  """

  import Ecto.Query

  alias Comma.Accounts.User
  alias Comma.Auth.OneTimeCredentials
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.Repo
  alias Comma.Stations.{Config, Signature, Window}
  alias SalixStore.StationMembers
  alias SalixStore.Stations, as: Roster
  alias SalixStore.Stations.{Events, Station}

  @enroll_purpose "station_enroll"
  @enroll_ttl_seconds 3600
  @relay_purpose "station_relay"
  @relay_ttl_seconds 60
  @workspace_limit 100

  # ── access ─────────────────────────────────────────────────────────────

  @doc """
  The caller's role in the Group of a Comma Workspace, for a session that may
  act there. Answers the Workspace too: its `salix_tenant_id` and
  `salix_group_id` name the Group.
  """
  def member(user, session, workspace_id) when is_binary(workspace_id) do
    with :ok <- unrestricted(session),
         :ok <- Comma.Workspaces.session_scope(session, workspace_id, nil),
         %Workspace{} = workspace <- Repo.get(Workspace, workspace_id),
         :ok <- Window.workspace(workspace),
         {:ok, role} <-
           StationMembers.role(workspace.salix_tenant_id, workspace.salix_group_id, user["id"]) do
      {:ok, workspace, role}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def member(_user, _session, _workspace_id), do: {:error, :not_found}

  defp manager(user, session, workspace_id) do
    with {:ok, workspace, role} <- member(user, session, workspace_id) do
      if manager?(workspace.salix_tenant_id, workspace.salix_group_id, user["id"]),
        do: {:ok, workspace, role},
        else: {:error, :forbidden}
    end
  end

  defp manager?(tenant_id, group_id, user_id),
    do: StationMembers.manager?(tenant_id, group_id, user_id)

  # Who may enroll a station: any member but a read-only one. The station is
  # theirs (`enrolled_by`), with access off until they set it.
  defp enroller(user, session, workspace_id) do
    with {:ok, workspace, role} <- member(user, session, workspace_id) do
      if Comma.Stations.Members.read_only_role?(role),
        do: {:error, :forbidden},
        else: {:ok, workspace, role}
    end
  end

  defp enroller?(tenant_id, group_id, user_id),
    do: StationMembers.enroller?(tenant_id, group_id, user_id)

  defp unrestricted(%{"restricted" => true}), do: {:error, :forbidden}
  defp unrestricted(%{"id" => id}) when is_binary(id), do: :ok
  defp unrestricted(_session), do: {:error, :forbidden}

  defp available do
    if Config.enabled?(), do: :ok, else: {:error, :stations_unavailable}
  end

  # ── enrollment ─────────────────────────────────────────────────────────

  @doc """
  A single-use, one-hour enrollment token and the install command that redeems
  it. `origin` is the public origin stations reach this server at: the
  configured one, else the request's own (`Comma.Stations.Config.origin/1`).
  """
  def create_enrollment(user, session, workspace_id, attrs, origin \\ Config.origin()) do
    with :ok <- available(),
         {:ok, workspace, _role} <- enroller(user, session, workspace_id),
         :ok <- Roster.room_for(workspace.salix_tenant_id, workspace.salix_group_id),
         {:ok, name} <- enrollment_name(attrs["name"]) do
      issue_enrollment(workspace, user["id"], name, origin)
    end
  end

  defp issue_enrollment(_workspace, _user_id, _name, origin) when not is_binary(origin),
    do: {:error, :stations_unavailable}

  defp issue_enrollment(workspace, user_id, name, origin) do
    tenant_id = workspace.salix_tenant_id
    group_id = workspace.salix_group_id

    with {:ok, grant} <-
           OneTimeCredentials.issue(
             @enroll_purpose,
             %{
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "user_id" => user_id,
               "name" => name
             },
             @enroll_ttl_seconds,
             user_id
           ) do
      # The Group and enroller lead the token so admission can be checked
      # before the single-use grant is consumed. They carry no authority: the
      # consumed grant must name the same Group and enroller.
      token = Enum.join([tenant_id, group_id, user_id, grant.id, grant.secret], ".")

      {:ok,
       %{
         "token" => token,
         "command" => "curl -fsSL #{origin}/stations/install.sh | sh -s -- #{token}",
         "expires_at" => grant.expires_at
       }}
    end
  end

  defp enrollment_name(nil), do: {:ok, "Station"}
  defp enrollment_name(name), do: clean_name(name)

  @doc """
  A station redeems an enrollment token, proving its key over
  `comma-station-enroll-v1:<origin>:<token>:<station>`. The signature is checked
  before the token is consumed, and so are the Group's station limit and the
  enroller's role, so a refusal does not burn the token.
  Re-enrolling into the same Group keeps the station as it is; into another
  Group moves it.
  """
  def enroll(input, origin \\ Config.origin())

  def enroll(%{"token" => token, "station" => station, "signature" => signature} = input, origin)
      when is_binary(token) and byte_size(token) <= 400 and is_binary(signature) and
             is_binary(origin) do
    started = SystemsClock.monotonic_time()

    result =
      with :ok <- available(),
           true <- Signature.valid_id?(station) || {:error, :invalid_request},
           true <-
             Signature.verify(
               station,
               signature,
               Signature.enroll_message(origin, token, station)
             ) || {:error, :invalid_signature},
           {:ok, group, user_id, id, secret} <- parse_token(token),
           :ok <- admissible(group, user_id, station),
           {:ok, grant} <- consume_enrollment(group, user_id, id, secret),
           {:ok, row, moved_from} <- admit(group, grant, station, input["version"]) do
        with {_tenant_id, left} <- moved_from, do: Events.roster_changed(left)
        Events.roster_changed(row.group_id)
        Events.station_changed(row.id)
        placement(row)
      end

    emit(:station_enroll, result, started)
    result
  end

  def enroll(_input, origin) when not is_binary(origin), do: {:error, :stations_unavailable}
  def enroll(_input, _origin), do: {:error, :invalid_request}

  defp parse_token(token) do
    case String.split(token, ".") do
      [tenant_id, group_id, user_id, id, secret]
      when tenant_id != "" and group_id != "" and user_id != "" ->
        {:ok, {tenant_id, group_id}, user_id, id, secret}

      _ ->
        {:error, :token_expired_or_used}
    end
  end

  # Admission as the token's enroller, read without consuming the token.
  defp admissible({tenant_id, group_id}, user_id, station_id) do
    :ok = Window.station(station_id)
    :ok = Window.group(tenant_id, group_id)

    if enroller?(tenant_id, group_id, user_id),
      do: Roster.room_for(tenant_id, group_id, station_id),
      else: {:error, :token_expired_or_used}
  end

  defp consume_enrollment({tenant_id, group_id}, user_id, id, secret) do
    case OneTimeCredentials.consume(@enroll_purpose, id, secret) do
      {:ok, %{"tenant_id" => ^tenant_id, "group_id" => ^group_id, "user_id" => ^user_id} = grant} ->
        {:ok, grant}

      {:error, :auth_unavailable} ->
        {:error, :stations_unavailable}

      _ ->
        {:error, :token_expired_or_used}
    end
  end

  # The enroller must still be a member who may enroll when the token is redeemed.
  defp admit({tenant_id, group_id}, grant, station_id, version) do
    if enroller?(tenant_id, group_id, grant["user_id"]) do
      Roster.admit(tenant_id, group_id, station_id, %{
        name: grant["name"],
        version: version,
        enrolled_by: grant["user_id"]
      })
    else
      {:error, :token_expired_or_used}
    end
  end

  # What a station is placed with: Salix's part and this server's.
  defp placement(%Station{} = station) do
    with {:ok, place} <- Roster.placement(station) do
      {:ok,
       Map.merge(place, %{
         "provider" => "comma",
         "relay_urls" => Config.relay_urls(),
         "gateway_keys" => Config.gateway_keys()
       })}
    end
  end

  # ── Cloud VM stations ──────────────────────────────────────────────────

  @doc """
  Places the station of a Group's Cloud VM in that Group
  (`SalixStore.Stations.place_cloud_station/5`). The control plane created
  that station, so no enrollment token is redeemed and no member is asked:
  every Group has a roster. The product that owns the Group must have its
  workspace in use (`{:error, :not_found}` otherwise). Answers what the station is placed with (the
  `enroll/2` answer and `"origin"`: the configured one, else `origin`, where
  the station reaches this server).
  """
  def admit_cloud_station(
        tenant_id,
        group_id,
        station_id,
        previous_station_id,
        version,
        origin \\ nil
      ) do
    with {:ok, admission} <-
           prepare_cloud_station(
             tenant_id,
             group_id,
             station_id,
             previous_station_id,
             version,
             origin
           ),
         :ok <- publish_cloud_station(admission) do
      {:ok, admission.place}
    end
  end

  @doc """
  Prepares the local roster write and placement for a managed Station. The
  caller can include this write in its owner transaction. Publish the returned
  admission with `publish_cloud_station/1` only after that transaction commits.
  """
  def prepare_cloud_station(
        tenant_id,
        group_id,
        station_id,
        previous_station_id,
        version,
        origin \\ nil
      ) do
    # The configured origin, else the one the station reaches this server at.
    origin = Config.origin(origin)

    with :ok <- available(),
         true <- is_binary(origin) || {:error, :stations_unavailable},
         true <- (is_binary(tenant_id) and is_binary(group_id)) || {:error, :invalid_request},
         true <- StationMembers.workspace_active?(tenant_id, group_id) || {:error, :not_found},
         :ok <- Window.station(station_id),
         :ok <- Window.group(tenant_id, group_id),
         {:ok, row, replaced} <-
           Roster.place_cloud_station(
             tenant_id,
             group_id,
             station_id,
             previous_station_id,
             version
           ),
         {:ok, place} <- placement(row) do
      {:ok,
       %{
         place: Map.put(place, "origin", origin),
         station_id: row.id,
         previous_station_id: replaced,
         group_id: group_id
       }}
    end
  end

  @doc "Publishes a managed Station admission after its local writes commit."
  def publish_cloud_station(%{
        station_id: station,
        previous_station_id: previous,
        group_id: group
      }) do
    if previous, do: Events.station_removed(previous)
    Events.roster_changed(group)
    Events.station_changed(station)
    :ok
  end

  @doc """
  An enrollment command issued for a member that the caller has already
  authorized (the device-install surfaces of `CommaWeb.Stations.DeviceInstall`).
  The member must not be a read-only one, as for `create_enrollment/4`.
  """
  def create_member_enrollment(workspace_id, user_id, name, origin \\ Config.origin())

  def create_member_enrollment(workspace_id, user_id, name, origin)
      when is_binary(workspace_id) and is_binary(user_id) do
    with :ok <- available(),
         %Workspace{} = workspace <- Repo.get(Workspace, workspace_id) || {:error, :forbidden},
         :ok <- Window.workspace(workspace),
         true <-
           enroller?(workspace.salix_tenant_id, workspace.salix_group_id, user_id) ||
             {:error, :forbidden},
         :ok <- Roster.room_for(workspace.salix_tenant_id, workspace.salix_group_id),
         {:ok, name} <- enrollment_name(name) do
      issue_enrollment(workspace, user_id, name, origin)
    end
  end

  def create_member_enrollment(_workspace_id, _user_id, _name, _origin), do: {:error, :forbidden}

  # ── the client relay ─────────────────────────────────────────────────

  @doc """
  A one-minute, single-use ticket for the client relay socket
  (`CommaWeb.ClientRelaySocket`): Salix carries the iroh packets of the
  member's device to the Workspace's stations, as it does between stations.
  Any member may have one, for a session that may act in the Workspace.
  """
  def relay_ticket(user, session, workspace_id) do
    with :ok <- available(),
         {:ok, workspace, _role} <- member(user, session, workspace_id),
         {:ok, grant} <-
           OneTimeCredentials.issue(
             @relay_purpose,
             %{
               "tenant_id" => workspace.salix_tenant_id,
               "group_id" => workspace.salix_group_id,
               "user_id" => user["id"]
             },
             @relay_ttl_seconds,
             user["id"]
           ) do
      {:ok, %{"ticket" => grant.id <> "." <> grant.secret, "expires_at" => grant.expires_at}}
    end
  end

  @doc """
  Redeems a relay ticket once: the Group the socket carries packets in, while
  the member who asked for it still belongs to it.
  """
  def redeem_relay_ticket(ticket) when is_binary(ticket) do
    with [id, secret] <- String.split(ticket, ".", parts: 2),
         {:ok, %{"tenant_id" => tenant_id, "group_id" => group_id, "user_id" => user_id}} <-
           OneTimeCredentials.consume(@relay_purpose, id, secret),
         {:ok, _role} <- StationMembers.role(tenant_id, group_id, user_id) do
      {:ok, %{tenant_id: tenant_id, group_id: group_id, user_id: user_id, ticket_id: id}}
    else
      {:error, :auth_unavailable} -> {:error, :stations_unavailable}
      _ -> {:error, :invalid_ticket}
    end
  end

  def redeem_relay_ticket(_ticket), do: {:error, :invalid_ticket}

  @doc "Whether the member a relay socket was redeemed for still belongs to its Group."
  def relay_member?(%{tenant_id: tenant_id, group_id: group_id, user_id: user_id}),
    do: match?({:ok, _}, StationMembers.role(tenant_id, group_id, user_id))

  # ── stations themselves ───────────────────────────────────────────────

  @doc "An enrolled, non-removed station."
  def active_station(station_id) do
    :ok = Window.station(station_id)
    Roster.active_station(station_id)
  end

  @doc """
  The presence `state` frame (contract §3), read from the owner rows. Its
  `workspace` is the id Salix keeps for the station's Group, with the ids the
  Group was told before as `workspace_was`.
  """
  def presence_state(station_id, origin \\ Config.origin()) do
    with :ok <- available(),
         :ok <- Window.station(station_id) do
      Roster.presence_state(station_id, %{
        "origin" => origin,
        "relay_urls" => Config.relay_urls(),
        "gateway_keys" => Config.gateway_keys()
      })
    end
  end

  defdelegate connected(station_id, version), to: Roster
  defdelegate disconnected(station_id), to: Roster

  def emit_connect(outcome, started), do: emit(:station_connect, outcome, started)

  # ── clients ────────────────────────────────────────────────────────────

  @doc "Stations of a Workspace's Group for its members, in enrollment order."
  def list(user, session, workspace_id) do
    with {:ok, workspace, _role} <- member(user, session, workspace_id) do
      {:ok, Roster.roster(workspace.salix_tenant_id, workspace.salix_group_id)}
    end
  end

  def rename(user, session, workspace_id, station_id, attrs) do
    with {:ok, workspace, _role} <- manager(user, session, workspace_id),
         {:ok, station} <-
           Roster.rename(
             workspace.salix_tenant_id,
             workspace.salix_group_id,
             station_id,
             attrs["name"]
           ) do
      Events.roster_changed(station.group_id)
      Events.station_changed(station.id)
      {:ok, station}
    end
  end

  @doc "Removes a station: its socket closes with 4004 and it is told `station_removed`."
  def remove(user, session, workspace_id, station_id) do
    with {:ok, workspace, _role} <- manager(user, session, workspace_id),
         :ok <- Roster.remove(workspace.salix_tenant_id, workspace.salix_group_id, station_id) do
      Events.station_removed(station_id)
      Window.tell_removed(station_id)
      Events.roster_changed(workspace.salix_group_id)
      :ok
    end
  end

  @doc "A member credential for one client device (contract §4); its `ws` is the workspace id Salix keeps for the Group."
  def issue_credential(user, session, workspace_id, attrs) do
    started = SystemsClock.monotonic_time()

    result =
      with :ok <- available(),
           {:ok, workspace, _role} <- member(user, session, workspace_id),
           {:ok, issued} <-
             Roster.issue_credential(
               workspace.salix_tenant_id,
               workspace.salix_group_id,
               user,
               attrs["device"],
               session
             ) do
        {:ok, Map.put(issued, "relay_urls", Config.relay_urls())}
      end

    emit(:station_credential, result, started)
    result
  end

  @doc "The account and its Workspaces as station clients see them (contract §5)."
  def me(user, session) do
    with :ok <- unrestricted(session) do
      workspaces =
        Repo.all(
          from(w in Workspace,
            join: m in WorkspaceMembership,
            on: m.workspace_id == w.id,
            where: m.user_id == ^user["id"] and m.status == "active" and w.status == "active",
            order_by: [asc: w.inserted_at, asc: w.id],
            limit: ^@workspace_limit,
            select: %{"id" => w.id, "name" => w.name, "role" => m.role}
          )
        )
        |> Enum.filter(&scoped?(session, &1["id"]))

      {:ok,
       %{
         "user" => %{"id" => user["id"], "email" => user["email"], "name" => user["name"]},
         "workspaces" => workspaces,
         "relay_urls" => Config.relay_urls()
       }}
    end
  end

  defp scoped?(session, workspace_id),
    do: Comma.Workspaces.session_scope(session, workspace_id, nil) == :ok

  @doc """
  The active Comma Workspace that is a Group, with its active members by
  normalized email (push recipients); nil when the Group is not one.
  """
  def workspace_members_by_email(tenant_id, group_id, emails) when is_list(emails) do
    case Repo.one(
           from(w in Workspace,
             where:
               w.salix_tenant_id == ^tenant_id and w.salix_group_id == ^group_id and
                 w.status == "active",
             select: w.id
           )
         ) do
      nil ->
        nil

      workspace_id ->
        members =
          Repo.all(
            from(u in User,
              join: m in WorkspaceMembership,
              on: m.user_id == u.id,
              where:
                m.workspace_id == ^workspace_id and m.status == "active" and u.status == "active" and
                  u.email in ^emails,
              select: {u.email, u.id}
            )
          )

        {workspace_id, Map.new(members)}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp clean_name(value) when is_binary(value) do
    name = value |> String.trim() |> String.replace(~r/\s+/u, " ")

    if name != "" and String.length(name) <= 80,
      do: {:ok, name},
      else: {:error, :invalid_name}
  end

  defp clean_name(_value), do: {:error, :invalid_name}

  defp emit(operation, result, started) do
    CommaProduct.Telemetry.emit_operation(
      operation,
      outcome(result),
      SystemsClock.monotonic_time() - started
    )
  end

  defp outcome(:ok), do: :ok
  defp outcome({:ok, _}), do: :ok
  defp outcome({:ok, _, _}), do: :ok
  defp outcome({:error, :stations_unavailable}), do: :unavailable
  defp outcome({:error, :station_removed}), do: :not_found
  defp outcome({:error, :not_found}), do: :not_found
  defp outcome({:error, :too_many_stations}), do: :conflict
  defp outcome({:error, :rate_limited, _}), do: :rate_limited
  defp outcome({:error, _}), do: :rejected
  defp outcome(_), do: :other
end
