defmodule SalixVoice.Carrier.Twilio do
  @moduledoc """
  Twilio Media Streams codec, TwiML builders and webhook signature check
  (docs/messaging-voice.md).

  There is no official Elixir Twilio SDK; the formats below follow Twilio's
  published Media Streams message and webhook security references.

  Media Streams: Twilio sends `connected`, `start`, `media`, `mark`, `stop` and
  `dtmf` JSON text frames; Salix sends `media`, `mark` and `clear` with the
  stream's `streamSid`. Audio is base64 mu-law 8 kHz in both directions and
  passes to GPT-Live without transcoding.

  Signature: `X-Twilio-Signature` is base64(HMAC-SHA1(auth token, URL <>
  each POST parameter name and value sorted by name)). Threat: a forged
  webhook could start paid calls or skip caller checks. The independent
  authority is the Twilio auth token held only by Twilio and the platform
  settings; the webhook route owns the check and answers 403 with no TwiML on
  failure.
  """

  @behaviour SalixVoice.Carrier

  @doc "Codec state for one media stream."
  def new, do: %{stream_sid: nil, call_sid: nil, account_sid: nil}

  # -- Media Streams ----------------------------------------------------------

  @impl SalixVoice.Carrier
  def decode({:text, payload}, state) do
    case Jason.decode(IO.iodata_to_binary(payload)) do
      {:ok, %{"event" => event} = message} -> decode_event(event, message, state)
      _ -> {:error, :bad_frame}
    end
  end

  def decode(_frame, _state), do: {:error, :bad_frame}

  defp decode_event("connected", _message, state), do: {:ok, [:connected], state}

  defp decode_event("start", %{"start" => start} = message, state) when is_map(start) do
    stream_sid = start["streamSid"] || message["streamSid"]

    info = %{
      stream_sid: stream_sid,
      call_sid: start["callSid"],
      account_sid: start["accountSid"],
      tracks: start["tracks"] || [],
      media_format: start["mediaFormat"] || %{},
      custom_parameters: start["customParameters"] || %{}
    }

    {:ok, [{:start, info}],
     %{state | stream_sid: stream_sid, call_sid: info.call_sid, account_sid: info.account_sid}}
  end

  defp decode_event("media", %{"media" => %{"payload" => payload} = media}, state)
       when is_binary(payload) do
    cond do
      media["track"] not in [nil, "inbound", "inbound_track"] ->
        {:ok, [], state}

      true ->
        case Base.decode64(payload) do
          {:ok, audio} -> {:ok, [{:audio, audio}], state}
          :error -> {:error, :bad_frame}
        end
    end
  end

  defp decode_event("mark", %{"mark" => %{"name" => name}}, state) when is_binary(name),
    do: {:ok, [{:mark_played, name}], state}

  defp decode_event("stop", _message, state), do: {:ok, [{:hangup, :caller_hangup}], state}

  defp decode_event("dtmf", %{"dtmf" => %{"digit" => digit}}, state) when is_binary(digit),
    do: {:ok, [{:dtmf, digit}], state}

  defp decode_event(event, _message, _state)
       when event in ["start", "media", "mark", "dtmf"],
       do: {:error, :bad_frame}

  defp decode_event(_event, _message, state), do: {:ok, [], state}

  @impl SalixVoice.Carrier
  def encode(_command, %{stream_sid: nil} = state), do: {[], state}

  def encode({:audio, audio}, state) when is_binary(audio) and audio != "" do
    {[
       json(%{
         "event" => "media",
         "streamSid" => state.stream_sid,
         "media" => %{"payload" => Base.encode64(audio)}
       })
     ], state}
  end

  def encode(:clear, state),
    do: {[json(%{"event" => "clear", "streamSid" => state.stream_sid})], state}

  def encode({:mark, name}, state) when is_binary(name) do
    {[json(%{"event" => "mark", "streamSid" => state.stream_sid, "mark" => %{"name" => name}})],
     state}
  end

  # Twilio has no transcript channel, and a call ends when the socket closes:
  # `<Connect><Stream>` then continues to the next TwiML verb, and there is none.
  def encode(_command, state), do: {[], state}

  defp json(map), do: {:text, Jason.encode!(map)}

  # -- TwiML ------------------------------------------------------------------

  @doc """
  `<Connect><Stream>` TwiML that bridges the call to `stream_url` (a `wss://`
  URL). `parameters` become `<Parameter>` entries, returned to Salix in
  `start.customParameters`.
  """
  @spec connect_stream_twiml(String.t(), map()) :: String.t()
  def connect_stream_twiml(stream_url, parameters \\ %{}) when is_binary(stream_url) do
    params =
      parameters
      |> Enum.sort()
      |> Enum.map_join(fn {name, value} ->
        ~s(<Parameter name="#{xml(name)}" value="#{xml(value)}"/>)
      end)

    response(~s(<Connect><Stream url="#{xml(stream_url)}">#{params}</Stream></Connect>))
  end

  @doc "TwiML that speaks `text` and hangs up."
  @spec say_hangup_twiml(String.t(), keyword()) :: String.t()
  def say_hangup_twiml(text, opts \\ []) when is_binary(text) do
    response(say(text, opts) <> "<Hangup/>")
  end

  @doc "TwiML that rejects the call without answering (no charge to the caller)."
  @spec reject_twiml(String.t()) :: String.t()
  def reject_twiml(reason \\ "rejected") when reason in ["rejected", "busy"],
    do: response(~s(<Reject reason="#{reason}"/>))

  @doc """
  TwiML that gathers a DTMF PIN and posts it to `action_url`.

  Options: `:num_digits` (default 6), `:timeout` seconds (default 10),
  `:retry_text` spoken when no digits arrive before hanging up, `:language`,
  `:voice`.
  """
  @spec gather_pin_twiml(String.t(), String.t(), keyword()) :: String.t()
  def gather_pin_twiml(action_url, prompt, opts \\ [])
      when is_binary(action_url) and is_binary(prompt) do
    digits = Keyword.get(opts, :num_digits, 6)
    timeout = Keyword.get(opts, :timeout, 10)
    retry = Keyword.get(opts, :retry_text, "No PIN was entered. Goodbye.")

    response(
      ~s(<Gather input="dtmf" numDigits="#{digits}" timeout="#{timeout}" finishOnKey="#" ) <>
        ~s(action="#{xml(action_url)}" method="POST">) <>
        say(prompt, opts) <> "</Gather>" <> say(retry, opts) <> "<Hangup/>"
    )
  end

  defp say(text, opts) do
    attrs =
      [language: opts[:language], voice: opts[:voice]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(fn {key, value} -> ~s( #{key}="#{xml(value)}") end)

    "<Say#{attrs}>#{xml(text)}</Say>"
  end

  defp response(body), do: ~s(<?xml version="1.0" encoding="UTF-8"?><Response>#{body}</Response>)

  defp xml(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  # -- Webhook signature ------------------------------------------------------

  @doc """
  Expected `X-Twilio-Signature` for `url` and form `params` (a map or a list of
  `{name, value}` pairs, so repeated names keep every value).
  """
  @spec signature(String.t(), map() | [{String.t(), String.t()}], String.t()) :: String.t()
  def signature(url, params, auth_token) do
    data =
      params
      |> Enum.map(fn {name, value} -> {to_string(name), to_string(value)} end)
      |> Enum.sort()
      |> Enum.reduce(url, fn {name, value}, acc -> acc <> name <> value end)

    :crypto.mac(:hmac, :sha, auth_token, data) |> Base.encode64()
  end

  @doc """
  Constant-time check of an `X-Twilio-Signature` header. `url` is the public
  URL Twilio called (the configured public base URL plus path and query).
  Twilio may sign with or without the default port, so both forms are tried.
  """
  @spec valid_signature?(String.t(), map() | list(), String.t() | nil, String.t() | nil) ::
          boolean()
  def valid_signature?(url, params, signature, auth_token)
      when is_binary(url) and is_binary(signature) and signature != "" and
             is_binary(auth_token) and auth_token != "" do
    url
    |> url_variants()
    |> Enum.any?(fn candidate ->
      constant_time_equal?(signature(candidate, params, auth_token), signature)
    end)
  end

  def valid_signature?(_url, _params, _signature, _auth_token), do: false

  defp constant_time_equal?(left, right),
    do: byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)

  defp url_variants(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, port: port} = uri when scheme in ["https", "http"] ->
        default = if scheme == "https", do: 443, else: 80
        without = uri |> Map.put(:port, nil) |> URI.to_string()
        with_port = with_explicit_port(uri, port || default)
        Enum.uniq([url, without, with_port])

      _ ->
        [url]
    end
  end

  defp with_explicit_port(%URI{} = uri, port) do
    authority = "#{uri.host}:#{port}"
    query = if uri.query, do: "?" <> uri.query, else: ""
    "#{uri.scheme}://#{authority}#{uri.path}#{query}"
  end
end
