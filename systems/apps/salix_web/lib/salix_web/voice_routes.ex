defmodule SalixWeb.VoiceRoutes do
  @moduledoc """
  Route handlers for voice (docs/messaging-voice.md), called from
  `SalixWeb.Router` so every route stays in the router's inventory:

    * `GET /v1/agent-groups/:group_id/voice` and `.../voice/sessions`: the
      `comma.voice.v1` readiness and session routes, opened only by a voice
      agent key (`salix_vk_`) of the path Group;
    * `GET /v1/voice/twilio/stream/:token`: the Twilio media socket;
    * `/v1/runtime/agent-groups/:group_id/im-connects/voice/...`: caller
      numbers, SMS verification and PINs (`Salix.Control.VoiceNumbers`);
    * `/v1/admin/voice/settings`: platform voice settings.
  """

  import Plug.Conn

  require Logger

  alias Salix.Control.VoiceNumbers
  alias SalixVoice.Carrier.WebSocket
  alias SalixVoice.Settings

  @subprotocol "comma.voice.v1"

  # -- comma.voice.v1 ------------------------------------------------------------

  @doc "Readiness, accepted formats and limits, without starting a session."
  def readiness(conn, group_id) do
    with {:ok, _key} <- voice_key(conn, group_id) do
      settings =
        case Settings.get() do
          {:ok, settings} -> settings
          _ -> Settings.defaults()
        end

      reason =
        case SalixVoice.readiness() do
          :ok -> nil
          {:error, reason} -> Atom.to_string(reason)
        end

      send_json(conn, 200, %{
        "ready" => is_nil(reason),
        "reason" => reason,
        "group_id" => group_id,
        "busy" => SalixVoice.group_busy?(group_id),
        "subprotocol" => @subprotocol,
        "audio_formats" => WebSocket.audio_formats() |> Enum.sort(),
        "max_frame_bytes" => WebSocket.max_frame_bytes(),
        "max_duration_s" => settings["max_call_seconds"],
        "sessions_url" => VoiceNumbers.voice_urls(group_id)["sessions_url"]
      })
    end
  end

  @doc "Upgrades to a `comma.voice.v1` session after the key and Group checks."
  def session(conn, group_id) do
    with {:ok, key} <- voice_key(conn, group_id),
         :ok <- subprotocol(conn),
         :ok <- not_draining(conn),
         {:ok, connect} <- voice_connect(conn, key, group_id) do
      conn
      |> put_resp_header("sec-websocket-protocol", @subprotocol)
      |> WebSockAdapter.upgrade(
        SalixWeb.VoiceSocket,
        %{
          tenant_id: key["tenant_id"],
          group_id: group_id,
          connect_id: connect["connect_id"],
          key: key
        },
        compress: false,
        # The socket owns its idle, start and pong timers; this is a backstop.
        timeout: 120_000,
        # Above the 16 KB protocol limit, so an oversized frame reaches the
        # codec and closes with 4400; only a frame over 64 KB closes with
        # 1009 at the adapter.
        max_frame_size: 4 * WebSocket.max_frame_bytes()
      )
    end
  rescue
    error in WebSockAdapter.UpgradeError ->
      send_json(conn, 400, %{error: "websocket_upgrade_required", message: error.message})
  end

  # The Auth plug admitted only a valid, active voice key; the key's Group
  # must also be the path Group.
  defp voice_key(conn, group_id) do
    case conn.assigns do
      %{auth_role: :voice_key, group_api_key: %{"group_id" => ^group_id} = key} -> {:ok, key}
      _ -> send_json(conn, 401, %{error: "unauthorized"})
    end
  end

  defp subprotocol(conn) do
    offered =
      conn
      |> get_req_header("sec-websocket-protocol")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)

    if @subprotocol in offered,
      do: :ok,
      else: send_json(conn, 400, %{error: "subprotocol_required", subprotocol: @subprotocol})
  end

  defp not_draining(conn) do
    if SalixCluster.NodeLifecycle.draining?(),
      do: send_json(conn, 503, %{error: "draining"}),
      else: :ok
  end

  defp voice_connect(conn, key, group_id) do
    case SalixIM.ProviderConnects.ensure_voice_im_connect(key["tenant_id"], group_id) do
      {:ok, connect} ->
        {:ok, connect}

      {:error, reason} ->
        Logger.warning("voice connect unavailable group=#{group_id} reason=#{inspect(reason)}")
        send_json(conn, 503, %{error: "unavailable"})
    end
  end

  # -- Twilio media stream -----------------------------------------------------

  @doc "Upgrades the Twilio media socket named by a valid stream token."
  def twilio_stream(conn, token) do
    case SalixVoice.StreamToken.verify(token, System.system_time(:second)) do
      {:ok, claims} ->
        WebSockAdapter.upgrade(
          conn,
          SalixWeb.TwilioStreamSocket,
          %{token: token, call_id: claims["call_id"]},
          compress: false,
          timeout: 60_000,
          max_frame_size: 64 * 1024
        )

      {:error, _reason} ->
        send_json(conn, 404, %{error: "not_found"})
    end
  rescue
    error in WebSockAdapter.UpgradeError ->
      send_json(conn, 400, %{error: "websocket_upgrade_required", message: error.message})
  end

  # -- Control routes ----------------------------------------------------------

  @doc "Sends a `Salix.Control.VoiceNumbers` result."
  def send_numbers_result(conn, {:ok, body}), do: send_json(conn, 200, body)
  def send_numbers_result(conn, {:error, reason}), do: send_numbers_error(conn, reason)

  defp send_numbers_error(conn, reason) do
    case reason do
      {:bad_request, message} -> send_json(conn, 400, %{error: message})
      :not_found -> send_json(conn, 404, %{error: "not_found"})
      :voice_number_in_use -> send_json(conn, 409, %{error: "voice_number_in_use"})
      :invalid_code -> send_json(conn, 422, %{error: "invalid_code"})
      :rate_limited -> send_json(conn, 429, %{error: "rate_limited"})
      :not_configured -> send_json(conn, 503, %{error: "voice_not_configured"})
      {:unavailable, _message} -> send_json(conn, 503, %{error: "unavailable"})
      other -> send_json(conn, 500, %{error: inspect(other)})
    end
  end

  # -- Admin settings ----------------------------------------------------------

  @doc "`GET /v1/admin/voice/settings`: the redacted platform settings."
  def get_settings(conn) do
    case Settings.redacted() do
      {:ok, settings} -> send_json(conn, 200, settings)
      {:error, reason} -> send_json(conn, 503, %{error: inspect(reason)})
    end
  end

  @doc "`PUT /v1/admin/voice/settings`: merge a partial update; secrets are write-only."
  def put_settings(conn) do
    case Settings.update(conn.body_params) do
      {:ok, settings} -> send_json(conn, 200, settings)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :conflict} -> send_json(conn, 409, %{error: "conflict"})
      {:error, reason} -> send_json(conn, 503, %{error: inspect(reason)})
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
