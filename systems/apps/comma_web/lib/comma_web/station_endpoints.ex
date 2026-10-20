defmodule CommaWeb.StationEndpoints do
  require SystemsRuntime.Proc

  @moduledoc """
  HTTP surface of the station control plane (station↔Comma contract §1–§7).

  Station-facing paths carry no Comma session: `/stations/install.sh`,
  `/stations/releases/station.json` and enrollment are public, presence and
  notify are station-signed. `CommaWeb.Auth` admits exactly those paths via
  `public_path?/1`. Everything else here needs a Comma session and a role in
  the Workspace's Group (`Comma.Stations.member/3`). The roster, keys and
  revocations behind every path are Salix's (`SalixStore.Stations`).
  """
  import Plug.Conn

  alias Comma.Stations
  alias Comma.Stations.{Config, Notices, Signature}
  alias SalixStore.Stations.Events
  alias CommaWeb.{StationPresence, StationReleases}

  @install_script_path Path.expand("../../priv/stations/install.sh", __DIR__)
  @external_resource @install_script_path
  @install_script File.read!(@install_script_path)
  @notify_tag "comma-station-notify-v1"
  @max_notify_bytes 256 * 1024

  @public_paths [
    "/stations/install.sh",
    "/stations/releases/station.json",
    "/stations/releases/station-beta.json",
    "/v1/comma/stations/enroll",
    "/v1/comma/stations/connect",
    "/v1/comma/stations/notify",
    # The ticket in the query authorizes the client relay socket.
    "/v1/comma/station-relay"
  ]

  def public_path?(path), do: path in @public_paths

  # ── public and station-signed ──────────────────────────────────────────

  def install_script(conn) do
    with origin when is_binary(origin) <- CommaWeb.StationOrigin.of(conn),
         {:ok, manifest} <- StationReleases.manifest(),
         {:ok, values} <- pinned(manifest) do
      script =
        Enum.reduce(
          [{"__ORIGIN__", origin}, {"__RELEASES__", Config.release_base_url()} | values],
          @install_script,
          fn {key, value}, script -> String.replace(script, key, value) end
        )

      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("text/x-shellscript")
      |> send_resp(200, script)
    else
      _ -> json(conn, 503, %{error: "stations_unavailable"})
    end
  end

  @platforms [
    {"darwin-arm64", "DARWIN_ARM64"},
    {"linux-x64", "LINUX_X64"},
    {"linux-arm64", "LINUX_ARM64"}
  ]

  # What the installer downloads for the pinned release: the manifest's own
  # `artifacts.<platform>.{url, sha256}` when it names them, else the bundle at
  # the release base, accepted only when it is built from the pinned `commit`.
  # Every value is checked to be shell-safe before it is written into the script.
  defp pinned(manifest) do
    base = Config.release_base_url()
    artifacts = if is_map(manifest["artifacts"]), do: manifest["artifacts"], else: %{}

    platform_values =
      Enum.flat_map(@platforms, fn {platform, key} ->
        artifact = if is_map(artifacts[platform]), do: artifacts[platform], else: %{}

        [
          {"__URL_#{key}__", artifact["url"] || "#{base}/stillfail-station-#{platform}.tar.gz"},
          {"__SHA_#{key}__", artifact["sha256"] || ""}
        ]
      end)

    values =
      [
        {"__VERSION__", manifest["version"]},
        {"__COMMIT__", if(is_binary(manifest["commit"]), do: manifest["commit"], else: "")}
        | platform_values
      ]

    if Enum.all?(values, fn {key, value} -> safe?(key, value) end),
      do: {:ok, values},
      else: {:error, :release_unavailable}
  end

  defp safe?("__URL_" <> _, url),
    do:
      is_binary(url) and
        Regex.match?(~r{\Ahttps://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~/%+-]*\z}, url)

  defp safe?("__SHA_" <> _, sha),
    do: is_binary(sha) and Regex.match?(~r/\A([0-9a-f]{64})?\z/, sha)

  defp safe?("__COMMIT__", commit),
    do: is_binary(commit) and Regex.match?(~r/\A([0-9a-f]{7,40})?\z/, commit)

  defp safe?("__VERSION__", version),
    do: is_binary(version) and Regex.match?(~r/\A[0-9A-Za-z.+-]{1,40}\z/, version)

  def releases(conn) do
    case StationReleases.manifest() do
      {:ok, manifest} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(200, manifest)

      {:error, _} ->
        json(conn, 503, %{error: "release_unavailable"})
    end
  end

  @doc "Comma stations follow the stable channel only; the beta feed is absent."
  def beta_releases(conn), do: json(conn, 404, %{error: "release_not_found"})

  def enroll(conn) do
    case Stations.enroll(conn.body_params || %{}, CommaWeb.StationOrigin.of(conn)) do
      {:ok, response} -> json(conn, 200, response)
      {:error, :invalid_request} -> json(conn, 400, %{error: "invalid_request"})
      {:error, :invalid_signature} -> json(conn, 401, %{error: "invalid_signature"})
      {:error, :token_expired_or_used} -> json(conn, 410, %{error: "token_expired_or_used"})
      {:error, :too_many_stations} -> json(conn, 429, %{error: "too_many_stations"})
      {:error, _} -> json(conn, 503, %{error: "stations_unavailable"})
    end
  end

  def connect(conn), do: CommaWeb.StationSocket.upgrade(conn)

  def notify(conn) do
    body = conn.assigns[:raw_body] || ""

    with true <- Config.enabled?() || {:error, :stations_unavailable},
         true <- byte_size(body) <= @max_notify_bytes || {:error, :too_large},
         :ok <-
           Signature.verify_request(
             @notify_tag,
             CommaWeb.StationOrigin.of(conn),
             header(conn, "station"),
             header(conn, "ts"),
             header(conn, "signature"),
             body
           ),
         {:ok, response} <- Notices.deliver(header(conn, "station"), conn.body_params || %{}) do
      json(conn, 200, response)
    else
      {:error, :station_removed} -> json(conn, 404, %{error: "station_removed"})
      {:error, :invalid_signature} -> json(conn, 401, %{error: "invalid_signature"})
      {:error, :too_large} -> json(conn, 413, %{error: "too_large"})
      {:error, :stations_unavailable} -> json(conn, 503, %{error: "stations_unavailable"})
      {:error, _} -> json(conn, 400, %{error: "invalid_request"})
    end
  end

  # ── Comma session ──────────────────────────────────────────────────────

  def create_enrollment(conn, workspace_id) do
    with_user(conn, fn user, session ->
      case Stations.create_enrollment(
             user,
             session,
             workspace_id,
             conn.body_params || %{},
             CommaWeb.StationOrigin.of(conn)
           ) do
        {:ok, enrollment} -> json(conn, 200, enrollment)
        {:error, :rate_limited, _} -> json(conn, 429, %{error: "rate_limited"})
        error -> error(conn, error)
      end
    end)
  end

  # A ticket for the client relay socket (`CommaWeb.ClientRelaySocket`), and where to open it.
  def relay_ticket(conn, workspace_id) do
    with_user(conn, fn user, session ->
      with origin when is_binary(origin) <- CommaWeb.StationOrigin.of(conn),
           {:ok, ticket} <- Stations.relay_ticket(user, session, workspace_id) do
        url =
          origin
          |> String.replace_prefix("https://", "wss://")
          |> String.replace_prefix("http://", "ws://")

        json(conn, 200, Map.put(ticket, "url", url <> "/v1/comma/station-relay"))
      else
        nil -> json(conn, 503, %{error: "stations_unavailable"})
        {:error, :rate_limited, _} -> json(conn, 429, %{error: "rate_limited"})
        error -> error(conn, error)
      end
    end)
  end

  def relay(conn), do: CommaWeb.ClientRelaySocket.upgrade(conn)

  def me(conn) do
    with_user(conn, fn user, session ->
      case Stations.me(user, session) do
        {:ok, me} -> json(conn, 200, me)
        error -> error(conn, error)
      end
    end)
  end

  def list(conn, workspace_id) do
    with_user(conn, fn user, session ->
      case Stations.list(user, session, workspace_id) do
        {:ok, stations} ->
          presence = presence(stations)
          json(conn, 200, %{stations: Enum.map(stations, &view(&1, presence))})

        error ->
          error(conn, error)
      end
    end)
  end

  def rename(conn, workspace_id, station_id) do
    with_user(conn, fn user, session ->
      case Stations.rename(user, session, workspace_id, station_id, conn.body_params || %{}) do
        {:ok, station} -> json(conn, 200, view(station, presence([station])))
        error -> error(conn, error)
      end
    end)
  end

  def delete(conn, workspace_id, station_id) do
    with_user(conn, fn user, session ->
      case Stations.remove(user, session, workspace_id, station_id) do
        :ok -> json(conn, 200, %{})
        error -> error(conn, error)
      end
    end)
  end

  def credential(conn, workspace_id) do
    with_user(conn, fn user, session ->
      case Stations.issue_credential(user, session, workspace_id, conn.body_params || %{}) do
        {:ok, credential} -> json(conn, 200, credential)
        error -> error(conn, error)
      end
    end)
  end

  @doc """
  `event: station` when a station goes on- or offline, `event: stations` when
  the list changed; a comment every 25 seconds, which also re-checks the
  caller's Membership so a revoked session or removed member stops streaming.
  """
  def events(conn, workspace_id) do
    with_user(conn, fn user, session ->
      case Stations.member(user, session, workspace_id) do
        {:ok, workspace, _role} ->
          group_id = workspace.salix_group_id
          Events.subscribe(Events.group_topic(group_id))
          Events.subscribe(Events.presence_topic(group_id))

          conn =
            conn
            |> put_resp_header("cache-control", "no-cache")
            |> put_resp_header("x-accel-buffering", "no")
            |> put_resp_content_type("text/event-stream")
            |> send_chunked(200)

          case chunk(conn, ": connected\n\n") do
            {:ok, conn} ->
              SystemsClock.send_after(
                SystemsRuntime.Proc.self(),
                :station_events_tick,
                heartbeat_ms()
              )

              events_loop(conn, user, session, {workspace.id, group_id})

            {:error, _} ->
              conn
          end

        error ->
          error(conn, error)
      end
    end)
  end

  # `scope` is the Workspace the caller named and its Group, which the events are of.
  defp events_loop(conn, user, session, {workspace_id, group_id} = scope) do
    SystemsRuntime.Proc.receive do
      {:comma_station_presence, station_id} ->
        case station_event(group_id, station_id) do
          nil -> events_loop(conn, user, session, scope)
          data -> send_event(conn, "station", data, user, session, scope)
        end

      {:comma_station_ws, :roster} ->
        send_event(conn, "stations", %{}, user, session, scope)

      # A timer, not quiet time, drives the recheck: steady event traffic
      # cannot postpone it.
      :station_events_tick ->
        with {:ok, _workspace, _role} <- Stations.member(user, session, workspace_id),
             {:ok, _user, _session} <- Comma.Accounts.resolve_session_id(session["id"]),
             {:ok, conn} <- chunk(conn, ": heartbeat\n\n") do
          SystemsClock.send_after(
            SystemsRuntime.Proc.self(),
            :station_events_tick,
            heartbeat_ms()
          )

          events_loop(conn, user, session, scope)
        else
          _ -> conn
        end

      _other ->
        events_loop(conn, user, session, scope)
    end
  end

  defp send_event(conn, event, data, user, session, scope) do
    case chunk(conn, "event: #{event}\ndata: #{Jason.encode!(data)}\n\n") do
      {:ok, conn} -> events_loop(conn, user, session, scope)
      {:error, _} -> conn
    end
  end

  defp station_event(group_id, station_id) do
    case Stations.active_station(station_id) do
      {:ok, %{group_id: ^group_id} = station} ->
        Map.merge(
          %{
            "id" => station.id,
            "online" => StationPresence.online?(group_id, station.id),
            "name" => station.name,
            "version" => station.version
          },
          Map.get(StationPresence.reach(group_id), station.id, %{})
        )

      _ ->
        nil
    end
  end

  defp heartbeat_ms,
    do: SystemsRuntime.get_env(:comma_web, :station_events_heartbeat_ms, 25_000)

  # ── helpers ────────────────────────────────────────────────────────────

  # Presence is tracked per Group; the listed stations are of one Group.
  # Which are online, and where those that said so may be reached (hints).
  defp presence([station | _]),
    do: {StationPresence.online(station.group_id), StationPresence.reach(station.group_id)}

  defp presence([]), do: {MapSet.new(), %{}}

  defp view(station, {online, reach}) do
    Map.merge(
      %{
        "id" => station.id,
        "name" => station.name,
        "version" => station.version,
        "online" => MapSet.member?(online, station.id),
        "enrolled_at" => DateTime.to_unix(station.enrolled_at),
        "enrolled_by" => station.enrolled_by
      },
      Map.get(reach, station.id, %{})
    )
  end

  defp with_user(conn, fun) do
    case conn.assigns do
      %{comma_user: user, comma_session: session} when is_map(user) and is_map(session) ->
        fun.(user, session)

      _ ->
        json(conn, 401, %{error: "unauthorized"})
    end
  end

  defp error(conn, {:error, :not_found}), do: json(conn, 404, %{error: "not_found"})
  defp error(conn, {:error, :forbidden}), do: json(conn, 403, %{error: "forbidden"})
  defp error(conn, {:error, :invalid_name}), do: json(conn, 400, %{error: "invalid_name"})
  defp error(conn, {:error, :invalid_device}), do: json(conn, 400, %{error: "invalid_device"})

  defp error(conn, {:error, :too_many_stations}),
    do: json(conn, 429, %{error: "too_many_stations"})

  defp error(conn, _error), do: json(conn, 503, %{error: "stations_unavailable"})

  defp header(conn, name) do
    case get_req_header(conn, "x-stillfail-" <> name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
