defmodule SalixWeb.TwilioWebhook do
  @moduledoc """
  Twilio voice webhooks and call admission (docs/messaging-voice.md).

  Twilio sends no bearer token, so `SalixWeb.Auth` lets these paths through
  `admit/1`, which applies a per-source and a global rate limit before the
  body is read.
  Each handler then checks `X-Twilio-Signature` over the configured public
  URL and the exact POST parameters, and answers 403 with no TwiML when it
  fails. The auth token in `SalixVoice.Settings` is the independent
  authority; `SalixVoice.Carrier.Twilio` holds the algorithm.

  An incoming call is admitted when:

    1. the called number (`To`) is a platform line in the voice settings;
    2. the caller (`From`) is a verified number of some Group's voice connect
       on that line (`SalixIM.ProviderConnects.find_voice_connect/3`);
    3. the carrier attested the caller number fully (STIR/SHAKEN
       `TN-Validation-Passed-A`), or the caller enters the number's PIN; a
       wrong PIN counts toward a lockout;
    4. `SalixVoice.admit/1` accepts the call (enabled, capacity, one call per
       Group).

  The answer is `<Connect><Stream>` to `/v1/voice/twilio/stream/<token>`,
  where `SalixWeb.TwilioStreamSocket` attaches the media. Every refusal after
  the signature check is spoken, then the call hangs up.
  """

  import Plug.Conn

  require Logger

  alias Salix.App.RouterInbox.RateLimit
  alias SalixIM.ProviderConnects
  alias SalixVoice.Carrier.Twilio
  alias SalixVoice.Settings

  @incoming "/v1/voice/twilio/incoming"
  @pin "/v1/voice/twilio/pin"
  @status "/v1/voice/twilio/status"
  @full_attestation "TN-Validation-Passed-A"
  @final_statuses ~w(completed busy failed no-answer canceled)
  # One source (`conn.remote_ip`; forwarding headers are never consulted) gets
  # a small share of the generous global cap, so an unsigned flood from one
  # source cannot use up the cap for Twilio. A denied source request does not
  # count toward the global cap. Tests may lower the limits through
  # `:salix_web, :twilio_webhook_rate_limits`.
  @rate_limits [source_per_minute: 600, global_per_minute: 6_000]
  @max_body_bytes 16 * 1024

  @doc "Largest webhook body Salix reads."
  def max_body_bytes, do: @max_body_bytes

  @doc "True for the signed Twilio webhook paths (form POSTs)."
  def webhook_path?(path), do: path in [@incoming, @pin, @status]

  @doc "True for the token-addressed Twilio media stream socket path."
  def stream_path?(path),
    do: Regex.match?(~r|\A/v1/voice/twilio/stream/[A-Za-z0-9_\-.]{16,1024}\z|, path)

  @doc """
  Auth-plug admission for the public Twilio paths: a per-source rate limit,
  then a global one. The signature (webhooks) and the stream token (media
  socket) are checked by the route, after the bounded body is read.
  """
  def admit(conn) do
    limits =
      Keyword.merge(
        @rate_limits,
        Application.get_env(:salix_web, :twilio_webhook_rate_limits, [])
      )

    with :ok <- limit("source:" <> source(conn), limits[:source_per_minute]),
         :ok <- limit("global", limits[:global_per_minute]) do
      put_resp_header(conn, "cache-control", "no-store")
    else
      {:error, {:rate_limited, seconds}} ->
        conn
        |> put_resp_header("retry-after", to_string(seconds))
        |> reply_json(429, %{error: "rate_limited"})
        |> halt()

      {:error, _} ->
        conn |> reply_json(503, %{error: "unavailable"}) |> halt()
    end
  end

  defp source(conn) do
    case :inet.ntoa(conn.remote_ip) do
      {:error, _} -> "unknown"
      address -> to_string(address)
    end
  end

  # -- Webhooks ----------------------------------------------------------------

  @doc "`POST /v1/voice/twilio/incoming`: a call to a platform line."
  def incoming(conn) do
    with_signed(conn, fn settings, params ->
      cond do
        params["To"] not in List.wrap(settings["twilio_numbers"]) ->
          say(conn, "This number is not configured for Comma voice calls.")

        settings["enabled"] != true ->
          say(conn, "Comma voice calls are not available right now.")

        true ->
          case find_connect(params) do
            {:ok, connect} -> authenticate_caller(conn, settings, params, connect)
            {:error, :not_found} -> say(conn, "This number is not registered with Comma.")
            {:error, _reason} -> say(conn, unavailable_text())
          end
      end
    end)
  end

  @doc "`POST /v1/voice/twilio/pin`: the digits a caller entered for the PIN."
  def pin(conn) do
    with_signed(conn, fn settings, params ->
      with true <- params["To"] in List.wrap(settings["twilio_numbers"]),
           {:ok, connect} <- find_connect(params) do
        case ProviderConnects.verify_voice_pin(
               connect["group_id"],
               connect["connect_id"],
               "twilio",
               params["To"],
               params["From"],
               to_string(params["Digits"] || ""),
               max_failures: settings["pin_max_failures"],
               lockout_seconds: settings["pin_lockout_seconds"]
             ) do
          :ok ->
            admit_call(conn, settings, params, connect)

          {:error, {:invalid_pin, remaining}} when is_integer(remaining) and remaining > 0 ->
            gather_pin(
              conn,
              settings,
              "That PIN is not correct. Enter your PIN, then press pound."
            )

          {:error, {:invalid_pin, _remaining}} ->
            say(conn, locked_text())

          {:error, {:locked, _until}} ->
            say(conn, locked_text())

          {:error, :pin_not_configured} ->
            say(conn, unverified_text())

          {:error, :not_found} ->
            say(conn, "This number is not registered with Comma.")

          {:error, _reason} ->
            say(conn, unavailable_text())
        end
      else
        false -> say(conn, "This number is not configured for Comma voice calls.")
        {:error, :not_found} -> say(conn, "This number is not registered with Comma.")
        {:error, _reason} -> say(conn, unavailable_text())
      end
    end)
  end

  @doc """
  `POST /v1/voice/twilio/status`: call status callbacks. The media socket
  ends an attached call when Twilio closes it. A call that finished before
  its stream attached (the caller hung up while it connected) is ended here,
  so its Group is free before the attach timeout.
  """
  def status(conn) do
    with_signed(conn, fn _settings, params ->
      Logger.debug(
        "twilio voice status call=#{inspect(params["CallSid"])} status=#{inspect(params["CallStatus"])}"
      )

      with status when status in @final_statuses <- params["CallStatus"],
           sid when is_binary(sid) and sid != "" <- params["CallSid"],
           {:ok, connect} <- find_connect(params) do
        SalixVoice.abandon_carrier_call(connect["group_id"], sid, :caller_hangup)
      end

      send_resp(conn, 204, "")
    end)
  end

  defp authenticate_caller(conn, settings, params, connect) do
    number = connect["number"] || %{}

    cond do
      params["StirVerstat"] == @full_attestation ->
        admit_call(conn, settings, params, connect)

      is_integer(number["pin_locked_until"]) ->
        say(conn, locked_text())

      number["pin_configured"] == true ->
        gather_pin(conn, settings, "Enter your Comma PIN, then press pound.")

      true ->
        say(conn, unverified_text())
    end
  end

  defp admit_call(conn, settings, params, connect) do
    attrs = %{
      carrier: :twilio,
      tenant_id: connect["tenant_id"],
      group_id: connect["group_id"],
      connect_id: connect["connect_id"],
      caller: %{"kind" => "e164", "value" => params["From"]},
      carrier_call_id: params["CallSid"],
      audio_format: :pcmu_8k,
      key_id: nil,
      display_name: nil
    }

    case SalixVoice.admit(attrs) do
      {:ok, %{token: token}} when is_binary(token) ->
        twiml(conn, Twilio.connect_stream_twiml(stream_url(settings, token)))

      {:ok, _other} ->
        say(conn, unavailable_text())

      {:error, reason} ->
        say(conn, admit_error_text(reason))
    end
  end

  defp gather_pin(conn, settings, prompt) do
    twiml(
      conn,
      Twilio.gather_pin_twiml(public_base_url(settings) <> @pin, prompt,
        num_digits: 8,
        timeout: 10,
        retry_text: "No PIN was entered. Goodbye."
      )
    )
  end

  defp find_connect(%{"To" => line, "From" => from}) when is_binary(line) and is_binary(from) do
    case ProviderConnects.find_voice_connect("twilio", line, from) do
      {:ok, connect} -> {:ok, connect}
      {:error, {:bad_request, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_connect(_params), do: {:error, :not_found}

  # -- Signature ---------------------------------------------------------------

  defp with_signed(conn, fun) do
    cond do
      conn.assigns[:raw_body_too_large] == true ->
        send_resp(conn, 413, "")

      true ->
        case Settings.get() do
          {:ok, settings} ->
            params = signed_params(conn)

            if Twilio.valid_signature?(
                 signed_url(conn, settings),
                 params,
                 signature_header(conn),
                 settings["twilio_auth_token"]
               ) do
              fun.(settings, Map.new(params))
            else
              Logger.warning("twilio voice webhook signature rejected path=#{conn.request_path}")
              send_resp(conn, 403, "")
            end

          {:error, reason} ->
            Logger.warning("voice settings unavailable: #{inspect(reason)}")
            send_resp(conn, 503, "")
        end
    end
  end

  # The exact parameters Twilio signed, repeated names included. The raw body
  # is cached by `SalixWeb.Router.cache_raw_body/2`.
  defp signed_params(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) and body != "" -> body |> URI.query_decoder() |> Enum.to_list()
      _ -> []
    end
  end

  defp signed_url(conn, settings) do
    query = if conn.query_string in [nil, ""], do: "", else: "?" <> conn.query_string
    public_base_url(settings) <> conn.request_path <> query
  end

  defp signature_header(conn) do
    case get_req_header(conn, "x-twilio-signature") do
      [signature] -> signature
      _ -> nil
    end
  end

  # -- URLs --------------------------------------------------------------------

  @doc "The public HTTPS base Twilio reaches: the settings override, else the deployment's."
  def public_base_url(settings) do
    case settings["public_base_url"] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> SalixWeb.Application.public_base_url()
    end
  end

  @doc "The WebSocket form of `public_base_url/1`."
  def public_ws_base_url(settings), do: ws_url(public_base_url(settings))

  @doc false
  def ws_url("https://" <> rest), do: "wss://" <> rest
  def ws_url("http://" <> rest), do: "ws://" <> rest
  def ws_url(url), do: url

  defp stream_url(settings, token),
    do: public_ws_base_url(settings) <> "/v1/voice/twilio/stream/" <> token

  # -- Replies -----------------------------------------------------------------

  defp say(conn, text), do: twiml(conn, Twilio.say_hangup_twiml(text))

  defp twiml(conn, body) do
    conn
    |> put_resp_content_type("text/xml")
    |> send_resp(200, body)
  end

  defp reply_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp admit_error_text(%{"error_class" => "billing_unavailable", "message" => message}),
    do: message

  defp admit_error_text(:busy), do: "The assistant is on another call. Please try again later."
  defp admit_error_text(:node_full), do: "All lines are busy. Please try again later."

  defp admit_error_text(:draining),
    do: "The service is restarting. Please call back in a minute."

  defp admit_error_text(:disabled), do: "Comma voice calls are not available right now."
  defp admit_error_text(_reason), do: unavailable_text()

  defp unavailable_text,
    do: "Comma voice calls are not available right now. Please try again later."

  defp locked_text,
    do: "Too many wrong PIN entries. PIN entry is locked for now. Please try again later."

  defp unverified_text,
    do:
      "This call could not be verified. Set a PIN for this number in Comma settings to call from it."

  defp limit(bucket, count) do
    case RateLimit.hit("twilio-voice:" <> bucket, 60_000, count) do
      {:allow, _} -> :ok
      {:deny, ms} -> {:error, {:rate_limited, max(1, div(ms + 999, 1000))}}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
