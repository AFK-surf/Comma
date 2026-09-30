defmodule SalixVoice.Model.GptLive do
  @moduledoc """
  GPT-Live voice model over its WebSocket event API (docs/messaging-voice.md).

  There is no official Elixir SDK, so this adapter speaks the documented JSON
  events directly with `websockex`: connect with `Authorization: Bearer`, send
  `session.start` with client delegation and the call's audio format, stream
  `session.input_audio.append`, and normalize server events for the owning
  `SalixVoice.CallActor`:

  | Server event | Normalized event |
  | --- | --- |
  | `session.started` | `{:started, session.id}` |
  | `session.output_audio.delta` | `{:audio, bytes}` |
  | `session.input_transcript.delta` | `{:input_transcript, delta, true, start_ms}` |
  | `session.output_transcript.delta` | `{:output_transcript, delta, true}` |
  | `session.delegation.created` | `{:delegation, delegation.id, offset_ms}` |
  | `session.closed` | `{:closed, reason, usage}` |
  | `error` | `{:error, error}` |

  Transcript deltas are committed fragments, so they are final. GPT-Live has no
  documented speech-started event. Barge-in is derived from transcript timing:
  a caller fragment that starts at or after the start of the agent's current
  speaking run (its first output transcript fragment) means the caller spoke
  while that run's audio was queued or playing, and the adapter emits
  `:speech_started` once for that run. Comparing against the run's end would
  miss real interruptions: the live service delivers agent fragments about a
  second after their timeline position, and it stops generating speech as soon
  as the caller talks, so the last agent fragment received can end before the
  caller's first one starts while its audio is still playing. Only a new caller
  utterance counts: a fragment that starts before the run began, or that
  continues the caller's speech with less than 500 ms of silence (the caller
  finishing a sentence the agent answered early), is not a barge-in. Output audio deltas carry no timing. An explicit
  `*.speech_started` event, if the service sends one, is honored too.

  `session.usage.updated` keeps the latest cumulative usage, so a transport
  loss without `session.closed` still reports the last known billed seconds.
  """

  @behaviour SalixVoice.Model

  use WebSockex

  require Logger

  @close_timeout_ms 5_000
  # Caller silence before a fragment that makes it a new utterance. Live
  # transcripts put words within a sentence at most a few hundred ms apart.
  @new_utterance_gap_ms 500

  @impl SalixVoice.Model
  def start_link(opts) do
    settings = opts.settings
    url = present(settings["gpt_live_url"]) || SalixVoice.Settings.default_gpt_live_url()

    state = %{
      owner: opts.owner,
      ref: opts.ref,
      session: session_config(opts),
      started?: false,
      closing?: false,
      closed_sent?: false,
      usage: %{},
      output_run_start_ms: nil,
      input_end_ms: nil,
      event_seq: 0
    }

    headers = [{"authorization", "Bearer " <> (present(settings["openai_api_key"]) || "")}]

    WebSockex.start_link(
      url,
      __MODULE__,
      state,
      [
        extra_headers: headers,
        async: true,
        handle_initial_conn_failure: true,
        socket_connect_timeout: 10_000,
        socket_recv_timeout: 30_000
      ] ++ tls_options(url)
    )
  end

  @impl SalixVoice.Model
  def send_audio(pid, audio) when is_binary(audio), do: WebSockex.cast(pid, {:audio, audio})

  @impl SalixVoice.Model
  def append(pid, kind, delegation_id, text)
      when kind in [:commentary, :thinking, :instructions] and is_binary(text),
      do: WebSockex.cast(pid, {:append, kind, delegation_id, text})

  @impl SalixVoice.Model
  def close(pid), do: WebSockex.cast(pid, :close)

  @doc """
  The `session` object of `session.start` for `opts`. The configuration is
  strict upstream, so only documented fields are sent.
  """
  def session_config(opts) do
    settings = opts.settings

    audio =
      %{}
      |> maybe_put("format", audio_format(opts.audio_format))
      |> maybe_put("output", voice(settings["gpt_live_voice"]))

    %{
      "model" => present(settings["gpt_live_model"]) || "gpt-live-1",
      "instructions" => opts.instructions,
      "delegation" => %{"type" => "client"}
    }
    |> maybe_put("audio", if(audio == %{}, do: nil, else: audio))
  end

  # Twilio's mu-law passes through unchanged. PCM16 24 kHz is the service
  # default, so it needs no format entry.
  defp audio_format(:pcmu_8k), do: %{"type" => "audio/pcmu", "rate" => 8000}
  defp audio_format(_pcm16_24k), do: nil

  defp voice(voice) do
    case present(voice) do
      nil -> nil
      voice -> %{"voice" => voice}
    end
  end

  # -- WebSockex callbacks ---------------------------------------------------

  @impl WebSockex
  def handle_connect(_conn, state) do
    send(self(), :send_session_start)
    {:ok, state}
  end

  @impl WebSockex
  def handle_info(:send_session_start, state) do
    {:reply, text(%{"type" => "session.start", "session" => state.session}), state}
  end

  def handle_info(:close_timeout, state), do: {:close, state}
  def handle_info(_message, state), do: {:ok, state}

  @impl WebSockex
  def handle_cast({:audio, audio}, state) do
    {:reply, text(%{"type" => "session.input_audio.append", "audio" => Base.encode64(audio)}),
     state}
  end

  def handle_cast({:append, kind, delegation_id, content}, state) do
    {event_id, state} = next_event_id(state)

    {:reply,
     text(%{
       "type" => "session.#{kind}.append",
       "event_id" => event_id,
       "delegation_id" => delegation_id,
       "content" => content
     }), state}
  end

  def handle_cast(:close, %{closing?: true} = state), do: {:ok, state}

  def handle_cast(:close, state) do
    Process.send_after(self(), :close_timeout, @close_timeout_ms)
    {:reply, text(%{"type" => "session.close"}), %{state | closing?: true}}
  end

  @impl WebSockex
  def handle_frame({:text, payload}, state) do
    case Jason.decode(payload) do
      {:ok, %{"type" => type} = event} when is_binary(type) -> handle_event(type, event, state)
      _ -> {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl WebSockex
  def handle_disconnect(status, state) do
    unless state.started? or state.closed_sent? do
      notify(state, {:error, {:disconnected, disconnect_reason(status)}})
    end

    unless state.closed_sent? do
      notify(state, {:closed, "connection_lost", state.usage})
    end

    {:ok, %{state | closed_sent?: true}}
  end

  @impl WebSockex
  def terminate(_reason, _state), do: :ok

  # The key is only in the connection's upgrade headers, which WebSockex
  # status never shows; the module state holds no secret. The long session
  # instructions are left out.
  @impl WebSockex
  def format_status(_opt, [_pdict, state]), do: [data: [{"State", Map.delete(state, :session)}]]

  # -- Server events ---------------------------------------------------------

  defp handle_event("session.started", event, state) do
    notify(state, {:started, get_in(event, ["session", "id"])})
    {:ok, %{state | started?: true}}
  end

  defp handle_event("session.output_audio.delta", %{"delta" => delta}, state)
       when is_binary(delta) do
    case Base.decode64(delta) do
      {:ok, audio} ->
        notify(state, {:audio, audio})
        {:ok, state}

      :error ->
        {:ok, state}
    end
  end

  defp handle_event("session.input_transcript.delta", %{"delta" => delta} = event, state)
       when is_binary(delta) do
    start_ms = integer(event["start_ms"])
    state = maybe_barge_in(state, start_ms)
    state = %{state | input_end_ms: integer(event["end_ms"]) || start_ms || state.input_end_ms}
    notify(state, {:input_transcript, delta, true, start_ms})
    {:ok, state}
  end

  defp handle_event("session.output_transcript.delta", %{"delta" => delta} = event, state)
       when is_binary(delta) do
    notify(state, {:output_transcript, delta, true})
    {:ok, track_output_run(state, event)}
  end

  defp handle_event("session.delegation.created", event, state) do
    case get_in(event, ["delegation", "id"]) do
      id when is_binary(id) and id != "" ->
        notify(state, {:delegation, id, integer(event["offset_ms"])})

      _ ->
        :ok
    end

    {:ok, state}
  end

  defp handle_event("session.usage.updated", %{"usage" => usage}, state) when is_map(usage),
    do: {:ok, %{state | usage: usage}}

  defp handle_event("session.closed", event, state) do
    usage = if is_map(event["usage"]), do: event["usage"], else: state.usage
    notify(state, {:closed, event["reason"] || "closed", usage})
    {:close, %{state | closed_sent?: true, usage: usage}}
  end

  defp handle_event("error", event, state) do
    error = if is_map(event["error"]), do: event["error"], else: %{"message" => "error"}

    Logger.warning("GPT-Live error code=#{inspect(error["code"])} type=#{inspect(error["type"])}")

    notify(state, {:error, error})
    {:ok, state}
  end

  defp handle_event(type, _event, state) do
    if String.ends_with?(type, "speech_started") do
      notify(state, :speech_started)
      {:ok, %{state | output_run_start_ms: nil}}
    else
      {:ok, state}
    end
  end

  # The first timed agent fragment after a barge-in (or session start) opens
  # a speaking run.
  defp track_output_run(%{output_run_start_ms: nil} = state, event) do
    case integer(event["start_ms"]) do
      start_ms when is_integer(start_ms) -> %{state | output_run_start_ms: start_ms}
      _ -> state
    end
  end

  defp track_output_run(state, _event), do: state

  # One `:speech_started` per speaking run: the first new caller utterance
  # that starts at or after the run's start.
  defp maybe_barge_in(%{output_run_start_ms: run_start} = state, start_ms)
       when is_integer(run_start) and is_integer(start_ms) and start_ms >= run_start do
    if new_utterance?(state.input_end_ms, start_ms) do
      notify(state, :speech_started)
      %{state | output_run_start_ms: nil}
    else
      state
    end
  end

  defp maybe_barge_in(state, _start_ms), do: state

  defp new_utterance?(nil, _start_ms), do: true

  defp new_utterance?(input_end_ms, start_ms),
    do: start_ms - input_end_ms >= @new_utterance_gap_ms

  # -- Helpers ----------------------------------------------------------------

  defp notify(state, event), do: send(state.owner, {:voice_model, state.ref, event})

  defp text(map), do: {:text, Jason.encode!(map)}

  defp next_event_id(state) do
    seq = state.event_seq + 1
    {"evt_" <> Integer.to_string(seq), %{state | event_seq: seq}}
  end

  defp disconnect_reason(%{reason: {:remote, code, _message}}), do: {:remote, code}
  defp disconnect_reason(%{reason: %{__exception__: true} = error}), do: error.__struct__
  defp disconnect_reason(%{reason: reason}), do: reason
  defp disconnect_reason(_status), do: :unknown

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: trunc(value)
  defp integer(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_value), do: nil

  defp tls_options("wss://" <> _rest) do
    [
      insecure: false,
      ssl_options: [
        cacerts: :public_key.cacerts_get(),
        verify: :verify_peer,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp tls_options(_url), do: []
end
