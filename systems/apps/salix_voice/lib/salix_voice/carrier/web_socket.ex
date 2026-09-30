defmodule SalixVoice.Carrier.WebSocket do
  @moduledoc """
  `comma.voice.v1` WebSocket voice codec (docs/messaging-voice.md).

  Every text frame is a JSON object that names its message in `type`. Binary
  frames are raw audio in the agreed format, at most 16 KB each; paced silence
  frames are audio too. The first client frame must be `session.start`
  `{audio_format, client, display_name?}`, where `client` names the client and
  version (for example `comma-voice/1.0.0`). `error.code` is the integer close
  code that follows the error. Unknown fields and message types are ignored in
  both directions.

  | Close code | Reason atoms |
  | --- | --- |
  | 1000 | normal ends (`:completed`, `:caller_hangup`, `:agent_hangup`, `:max_duration`) |
  | 4400 | `:bad_frame`, `:too_fast` |
  | 4401 | `:revoked` |
  | 4408 | `:start_timeout`, `:idle_timeout`, `:pong_timeout` |
  | 4409 | `:busy` |
  | 4410 | `:slow_reader` |
  | 4503 | `:draining`, `:model_error`, `:unavailable`, `:node_full`, `:disabled`, `:not_configured` |
  """

  @behaviour SalixVoice.Carrier

  @subprotocol "comma.voice.v1"
  @max_frame_bytes 16 * 1024
  @max_text_bytes 16 * 1024
  @formats %{"pcmu_8k" => :pcmu_8k, "pcm16_24k" => :pcm16_24k}

  @doc "The WebSocket subprotocol this codec speaks."
  def subprotocol, do: @subprotocol

  @doc "Largest binary audio frame in either direction."
  def max_frame_bytes, do: @max_frame_bytes

  @doc "Accepted `audio_format` names."
  def audio_formats, do: Map.keys(@formats)

  @doc "Codec state for one session."
  def new, do: %{phase: :await_start, audio_format: nil}

  @impl SalixVoice.Carrier
  def decode({:text, payload}, state) do
    payload = IO.iodata_to_binary(payload)

    with true <- byte_size(payload) <= @max_text_bytes,
         {:ok, %{"type" => type} = message} when is_binary(type) <- Jason.decode(payload) do
      decode_message(type, message, state)
    else
      _ -> {:error, {:bad_frame, "text frames must be JSON objects with a type"}}
    end
  end

  def decode({:binary, payload}, %{phase: :started, audio_format: format} = state) do
    audio = IO.iodata_to_binary(payload)

    cond do
      byte_size(audio) > @max_frame_bytes ->
        {:error, {:bad_frame, "audio frames must be at most #{@max_frame_bytes} bytes"}}

      format == :pcm16_24k and rem(byte_size(audio), 2) != 0 ->
        {:error, {:bad_frame, "pcm16_24k frames must hold whole 16-bit samples"}}

      audio == "" ->
        {:ok, [], state}

      true ->
        {:ok, [{:audio, audio}], state}
    end
  end

  def decode({:binary, _payload}, _state),
    do: {:error, {:bad_frame, "audio before session.start"}}

  def decode(_frame, _state), do: {:error, {:bad_frame, "unsupported frame"}}

  defp decode_message("session.start", message, %{phase: :await_start} = state) do
    with {:ok, format} <- Map.fetch(@formats, message["audio_format"]),
         client when is_binary(client) and client != "" and byte_size(client) <= 128 <-
           message["client"],
         {:ok, display_name} <- display_name(message["display_name"]) do
      {:ok, [{:start, %{audio_format: format, client: client, display_name: display_name}}],
       %{state | phase: :started, audio_format: format}}
    else
      _ ->
        {:error,
         {:bad_frame, "session.start needs audio_format (pcmu_8k or pcm16_24k) and a client name"}}
    end
  end

  defp decode_message("session.start", _message, _state),
    do: {:error, {:bad_frame, "session.start was already received"}}

  defp decode_message(_type, _message, %{phase: :await_start}),
    do: {:error, {:bad_frame, "the first frame must be session.start"}}

  defp decode_message("output.played", %{"name" => name}, state) when is_binary(name),
    do: {:ok, [{:mark_played, name}], state}

  defp decode_message("session.end", _message, state),
    do: {:ok, [{:hangup, :caller_hangup}], state}

  defp decode_message(_type, _message, state), do: {:ok, [], state}

  defp display_name(nil), do: {:ok, nil}

  defp display_name(name) when is_binary(name) and byte_size(name) <= 128 do
    case String.trim(name) do
      "" -> {:ok, nil}
      name -> {:ok, name}
    end
  end

  defp display_name(_name), do: :error

  @impl SalixVoice.Carrier
  def encode({:started, info}, state) when is_map(info) do
    {[
       json(%{
         "type" => "session.started",
         "call_id" => info[:call_id],
         "audio_format" => format_name(info[:audio_format]),
         "max_duration_s" => info[:max_duration_s]
       })
     ], state}
  end

  def encode({:audio, audio}, state) when is_binary(audio) do
    {chunks(audio, []), state}
  end

  def encode(:clear, state), do: {[json(%{"type" => "output.clear"})], state}

  def encode({:mark, name}, state) when is_binary(name),
    do: {[json(%{"type" => "output.mark", "name" => name})], state}

  def encode({:transcript, role, text, final?}, state) when is_binary(text) do
    {[
       json(%{
         "type" => "transcript",
         "role" => to_string(role),
         "text" => text,
         "final" => final?
       })
     ], state}
  end

  def encode({:end, reason}, state), do: encode({:end, reason, nil}, state)

  def encode({:end, reason, duration_s}, state) do
    {[
       json(
         %{"type" => "session.ended", "reason" => reason_name(reason)}
         |> put_present("duration_s", duration_s)
       )
     ], %{state | phase: :ended}}
  end

  # `code` is the integer close code that follows the frame; a reason atom is
  # mapped with `close_code/1`.
  def encode({:error, code, message}, state) do
    code = if is_integer(code), do: code, else: close_code(code)
    {[json(%{"type" => "error", "code" => code, "message" => message})], state}
  end

  def encode(_command, state), do: {[], state}

  @doc """
  The WebSocket close code for an end or error reason. Unknown reasons map to
  1000 for a clean end.
  """
  @spec close_code(atom()) :: 1000 | 4400 | 4401 | 4408 | 4409 | 4410 | 4503
  def close_code(reason) when reason in [:bad_frame, :too_fast], do: 4400
  def close_code(:revoked), do: 4401
  def close_code(reason) when reason in [:start_timeout, :idle_timeout, :pong_timeout], do: 4408
  def close_code(:busy), do: 4409
  def close_code(:slow_reader), do: 4410

  def close_code(reason)
      when reason in [
             :draining,
             :model_error,
             :unavailable,
             :node_full,
             :disabled,
             :not_configured
           ],
      do: 4503

  def close_code(_reason), do: 1000

  @doc "Wire name of an end reason."
  def reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_name(reason) when is_binary(reason), do: reason
  def reason_name(_reason), do: "other"

  defp format_name(format) when is_atom(format) and not is_nil(format), do: Atom.to_string(format)
  defp format_name(format), do: format

  defp chunks(<<>>, acc), do: Enum.reverse(acc)

  defp chunks(<<chunk::binary-size(@max_frame_bytes), rest::binary>>, acc),
    do: chunks(rest, [{:binary, chunk} | acc])

  defp chunks(rest, acc), do: Enum.reverse([{:binary, rest} | acc])

  defp json(map), do: {:text, Jason.encode!(map)}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
