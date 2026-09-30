defmodule SalixWeb.TwilioClient do
  @moduledoc """
  Minimal Twilio REST client for voice (docs/messaging-voice.md): end a call
  through the Calls API, and send and check SMS codes through the Verify API.

  There is no official Elixir Twilio SDK. The three requests are plain form
  POSTs with HTTP Basic auth (account SID and auth token from
  `SalixVoice.Settings`), so this adapter uses `Req` and stays isolated here.
  Tests point the base URLs at a local stub through the `:salix_web`
  application env keys `:twilio_api_base_url` and `:twilio_verify_base_url`;
  deployments use the Twilio defaults and have no configuration for them.
  """

  require Logger

  @api_base_url "https://api.twilio.com"
  @verify_base_url "https://verify.twilio.com"
  @timeout_ms 10_000

  @type error ::
          :not_configured
          | :invalid_code
          | :rate_limited
          | {:bad_request, String.t()}
          | {:unavailable, String.t()}

  @doc "True when `settings` hold the account credentials."
  def account_configured?(settings) do
    present?(settings["twilio_account_sid"]) and present?(settings["twilio_auth_token"])
  end

  @doc "True when `settings` can start SMS verifications."
  def verify_configured?(settings),
    do: account_configured?(settings) and present?(settings["twilio_verify_service_sid"])

  @doc "Ends a live call (`Status=completed`). Best effort: callers log the result."
  @spec hangup(map(), String.t()) :: :ok | {:error, error()}
  def hangup(settings, call_sid) when is_binary(call_sid) and call_sid != "" do
    if account_configured?(settings) do
      account = settings["twilio_account_sid"]

      url =
        api_base_url() <>
          "/2010-04-01/Accounts/" <>
          URI.encode(account, &URI.char_unreserved?/1) <>
          "/Calls/" <> URI.encode(call_sid, &URI.char_unreserved?/1) <> ".json"

      case post(url, [{"Status", "completed"}], settings) do
        {:ok, _body} -> :ok
        # The call already ended.
        {:error, {:not_found, _message}} -> :ok
        {:error, _reason} = error -> error
      end
    else
      {:error, :not_configured}
    end
  end

  def hangup(_settings, _call_sid), do: {:error, {:bad_request, "call_sid is required"}}

  @doc "Sends an SMS verification code to `e164`."
  @spec verify_start(map(), String.t()) :: {:ok, map()} | {:error, error()}
  def verify_start(settings, e164) do
    if verify_configured?(settings) do
      case post(
             verify_url(settings, "Verifications"),
             [{"To", e164}, {"Channel", "sms"}],
             settings
           ) do
        {:ok, body} -> {:ok, %{"status" => body["status"] || "pending"}}
        # An unknown Verify service is a platform configuration fault.
        {:error, {:not_found, _message}} -> {:error, :not_configured}
        {:error, _reason} = error -> error
      end
    else
      {:error, :not_configured}
    end
  end

  @doc "Checks `code` for `e164`. `:ok` only when Twilio reports `approved`."
  @spec verify_check(map(), String.t(), String.t()) :: :ok | {:error, error()}
  def verify_check(settings, e164, code) do
    if verify_configured?(settings) do
      case post(
             verify_url(settings, "VerificationCheck"),
             [{"To", e164}, {"Code", code}],
             settings
           ) do
        {:ok, %{"status" => "approved"}} -> :ok
        {:ok, _body} -> {:error, :invalid_code}
        # No pending verification (never started, expired or already used).
        {:error, {:not_found, _message}} -> {:error, :invalid_code}
        {:error, _reason} = error -> error
      end
    else
      {:error, :not_configured}
    end
  end

  defp verify_url(settings, resource) do
    verify_base_url() <>
      "/v2/Services/" <>
      URI.encode(settings["twilio_verify_service_sid"], &URI.char_unreserved?/1) <>
      "/" <> resource
  end

  defp post(url, form, settings) do
    auth = settings["twilio_account_sid"] <> ":" <> settings["twilio_auth_token"]

    case Req.post(url,
           form: form,
           auth: {:basic, auth},
           receive_timeout: @timeout_ms,
           connect_options: [timeout: @timeout_ms],
           retry: false
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, if(is_map(body), do: body, else: %{})}

      {:ok, %Req.Response{status: status, body: body}} ->
        message = if is_map(body), do: to_string(body["message"] || ""), else: ""
        Logger.warning("twilio request failed status=#{status} message=#{inspect(message)}")
        {:error, status_error(status, message)}

      {:error, exception} ->
        Logger.warning("twilio request failed: #{Exception.message(exception)}")
        {:error, {:unavailable, "twilio unreachable"}}
    end
  end

  defp status_error(429, _message), do: :rate_limited
  defp status_error(404, message), do: {:not_found, message}

  defp status_error(400, message),
    do: {:bad_request, if(message == "", do: "twilio rejected the request", else: message)}

  defp status_error(status, _message) when status in [401, 403], do: :not_configured
  defp status_error(status, _message), do: {:unavailable, "twilio returned #{status}"}

  defp api_base_url, do: Application.get_env(:salix_web, :twilio_api_base_url, @api_base_url)

  defp verify_base_url,
    do: Application.get_env(:salix_web, :twilio_verify_base_url, @verify_base_url)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
