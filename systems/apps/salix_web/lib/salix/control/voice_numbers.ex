defmodule Salix.Control.VoiceNumbers do
  @moduledoc """
  Caller numbers, PINs and readiness of a Group's voice connect
  (docs/messaging-voice.md), for the Salix control API, the Comma settings API
  and the Salix dashboard.

  A caller number is bound after an SMS code sent by Twilio Verify is
  approved: `verify_start/3` checks that the number is free on the platform
  line and sends the code; `verify_check/3` checks it and binds the number
  through `SalixIM.ProviderConnects.confirm_voice_number/5`, which takes the
  global reservation. A number held by another Group is
  `:voice_number_in_use`. The connect record and its reservations stay owned
  by `SalixIM.VoiceConnects`; this module adds only the verification step and
  a projection. PIN hashes never leave `salix_im`.

  `line` is the platform Twilio number the caller dials. It may be omitted
  when the platform has exactly one line.
  """

  alias Salix.App.RouterInbox.RateLimit
  alias Salix.Control.Groups
  alias SalixIM.ProviderConnects
  alias SalixVoice.Settings
  alias SalixWeb.TwilioClient

  @carrier "twilio"
  # SMS codes cost money and reach a third party's phone: bounded per Group
  # and per number. Tests may raise the bounds through
  # `:salix_web, :voice_verify_rate_limits`.
  @verify_limits [group_per_hour: 10, number_per_hour: 5]
  @hour_ms 3_600_000

  @type error ::
          :not_found
          | :not_configured
          | :voice_number_in_use
          | :rate_limited
          | :invalid_code
          | {:bad_request, String.t()}
          | {:unavailable, String.t()}

  @doc """
  The Group's voice status: `"lines"` (platform lines), `"numbers"` (the
  connect's public number projections), `"connect"` (the public connect or
  nil), `"readiness"` (`%{"ready", "reason"}`) and `"urls"` (see
  `voice_urls/1`).
  """
  @spec status(String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def status(group_id, tenant_id) do
    with {:ok, _group} <- group(group_id, tenant_id),
         {:ok, settings} <- settings() do
      connect =
        case ProviderConnects.get_voice_im_connect(tenant_id, group_id) do
          {:ok, connect} -> connect
          _ -> nil
        end

      {:ok,
       %{
         "group_id" => group_id,
         "lines" => List.wrap(settings["twilio_numbers"]),
         "numbers" => if(connect, do: connect["numbers"] || [], else: []),
         "connect" => connect,
         "readiness" => readiness(settings),
         "urls" => voice_urls(group_id)
       }}
    end
  end

  @doc "Sends an SMS code to `attrs[\"e164\"]` after checking the number is free on the line."
  @spec verify_start(String.t(), String.t(), map()) :: {:ok, map()} | {:error, error()}
  def verify_start(group_id, tenant_id, attrs) when is_map(attrs) do
    with {:ok, _group} <- group(group_id, tenant_id),
         {:ok, settings} <- settings(),
         {:ok, e164} <- e164(attrs["e164"]),
         {:ok, line} <- line(settings, attrs["line"]),
         :ok <- verify_configured(settings),
         :ok <-
           ProviderConnects.check_voice_number_available(
             tenant_id,
             group_id,
             @carrier,
             line,
             e164
           ),
         :ok <- limit("group:" <> group_id, verify_limit(:group_per_hour)),
         :ok <- limit("number:" <> e164, verify_limit(:number_per_hour)),
         {:ok, _result} <- TwilioClient.verify_start(settings, e164) do
      {:ok, %{"e164" => e164, "line" => line, "status" => "pending"}}
    end
  end

  def verify_start(_group_id, _tenant_id, _attrs),
    do: {:error, {:bad_request, "invalid request body"}}

  @doc "Checks the SMS code and binds the number. Returns `status/2`."
  @spec verify_check(String.t(), String.t(), map()) :: {:ok, map()} | {:error, error()}
  def verify_check(group_id, tenant_id, attrs) when is_map(attrs) do
    with {:ok, _group} <- group(group_id, tenant_id),
         {:ok, settings} <- settings(),
         {:ok, e164} <- e164(attrs["e164"]),
         {:ok, code} <- code(attrs["code"]),
         {:ok, line} <- line(settings, attrs["line"]),
         :ok <- verify_configured(settings),
         :ok <- TwilioClient.verify_check(settings, e164, code),
         {:ok, _connect} <-
           ProviderConnects.confirm_voice_number(tenant_id, group_id, @carrier, line, e164) do
      status(group_id, tenant_id)
    end
  end

  def verify_check(_group_id, _tenant_id, _attrs),
    do: {:error, {:bad_request, "invalid request body"}}

  @doc """
  Unbinds `e164` from the Group on every line and ends that number's live
  phone call as revoked. Returns `status/2`.
  """
  @spec remove_number(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def remove_number(group_id, tenant_id, e164) do
    with {:ok, _group} <- group(group_id, tenant_id),
         {:ok, e164} <- e164(e164),
         {:ok, _connect} <- ProviderConnects.remove_voice_number(tenant_id, group_id, e164) do
      SalixVoice.revoke_caller(group_id, e164)
      status(group_id, tenant_id)
    end
  end

  @doc "Sets (or with an empty `pin` clears) the PIN of `e164`. Returns `status/2`."
  @spec set_pin(String.t(), String.t(), map()) :: {:ok, map()} | {:error, error()}
  def set_pin(group_id, tenant_id, attrs) when is_map(attrs) do
    pin = attrs["pin"]

    with {:ok, _group} <- group(group_id, tenant_id),
         {:ok, e164} <- e164(attrs["e164"]),
         true <- is_nil(pin) or is_binary(pin),
         {:ok, _connect} <- ProviderConnects.set_voice_number_pin(tenant_id, group_id, e164, pin) do
      status(group_id, tenant_id)
    else
      false -> {:error, {:bad_request, "pin must be a string of 4 to 8 digits"}}
      other -> other
    end
  end

  def set_pin(_group_id, _tenant_id, _attrs), do: {:error, {:bad_request, "invalid request body"}}

  @doc """
  Public voice API URLs of a Group: `"readiness_url"` (HTTPS) and
  `"sessions_url"` (the `comma.voice.v1` WebSocket).
  """
  @spec voice_urls(String.t()) :: map()
  def voice_urls(group_id) do
    base =
      case Settings.get() do
        {:ok, settings} -> SalixWeb.TwilioWebhook.public_base_url(settings)
        _ -> SalixWeb.Application.public_base_url()
      end

    path = "/v1/agent-groups/" <> group_id <> "/voice"

    %{
      "readiness_url" => base <> path,
      "sessions_url" => SalixWeb.TwilioWebhook.ws_url(base) <> path <> "/sessions"
    }
  end

  @doc """
  Platform readiness for phone calls: voice enabled and configured on this
  node, Twilio credentials present, and at least one platform line.
  """
  @spec readiness(map()) :: map()
  def readiness(settings) do
    reason =
      case SalixVoice.readiness() do
        {:error, reason} ->
          Atom.to_string(reason)

        :ok ->
          cond do
            not TwilioClient.account_configured?(settings) -> "twilio_not_configured"
            List.wrap(settings["twilio_numbers"]) == [] -> "no_platform_lines"
            true -> nil
          end
      end

    %{"ready" => is_nil(reason), "reason" => reason}
  end

  # ---- internal ----

  defp group(group_id, tenant_id) do
    case Groups.get(group_id, tenant_id) do
      {:ok, group} -> {:ok, group}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, {:unavailable, "group store unavailable"}}
    end
  end

  defp settings do
    case Settings.get() do
      {:ok, settings} -> {:ok, settings}
      {:error, _reason} -> {:error, {:unavailable, "voice settings unavailable"}}
    end
  end

  defp verify_configured(settings) do
    if TwilioClient.verify_configured?(settings), do: :ok, else: {:error, :not_configured}
  end

  defp e164(value) when is_binary(value) do
    value = String.trim(value)

    if Settings.e164?(value),
      do: {:ok, value},
      else: {:error, {:bad_request, "e164 must be an E.164 number such as +15551234567"}}
  end

  defp e164(_value),
    do: {:error, {:bad_request, "e164 must be an E.164 number such as +15551234567"}}

  defp code(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A\d{4,10}\z/, value),
      do: {:ok, value},
      else: {:error, {:bad_request, "code must be 4 to 10 digits"}}
  end

  defp code(_value), do: {:error, {:bad_request, "code must be 4 to 10 digits"}}

  defp line(settings, nil) do
    case List.wrap(settings["twilio_numbers"]) do
      [line] -> {:ok, line}
      [] -> {:error, :not_configured}
      _lines -> {:error, {:bad_request, "line is required: name one of the platform lines"}}
    end
  end

  defp line(settings, line) when is_binary(line) do
    line = String.trim(line)

    if line in List.wrap(settings["twilio_numbers"]),
      do: {:ok, line},
      else: {:error, {:bad_request, "line must be one of the platform lines"}}
  end

  defp line(_settings, _line), do: {:error, {:bad_request, "line must be a string"}}

  defp verify_limit(name) do
    :salix_web
    |> Application.get_env(:voice_verify_rate_limits, [])
    |> Keyword.get(name, Keyword.fetch!(@verify_limits, name))
  end

  defp limit(bucket, count) do
    case RateLimit.hit("voice-verify:" <> bucket, @hour_ms, count) do
      {:allow, _} -> :ok
      {:deny, _ms} -> {:error, :rate_limited}
    end
  rescue
    _ -> {:error, {:unavailable, "rate limiter unavailable"}}
  catch
    :exit, _ -> {:error, {:unavailable, "rate limiter unavailable"}}
  end
end
