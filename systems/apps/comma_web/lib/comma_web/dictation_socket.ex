defmodule CommaWeb.DictationSocket do
  @moduledoc """
  Live dictation, `GET /v1/comma/dictation?ticket=…`: a member's words as they
  speak them, through the meetings' live ASR provider
  (`SalixMeetNative.ASR.provider/0`). The ticket comes from the member's
  session (`POST /v1/comma/me/dictation/tickets`, `Comma.Dictation`); one that
  does not redeem gets HTTP 401 before the upgrade, and with no live ASR
  provider configured the upgrade is refused with 503.

  The client sends binary frames of 16 kHz mono s16le PCM, then a text
  `{"type":"end"}` when the speaker is done. The audio is cut into segments at
  pauses, as a meeting's is (`SalixMeetNative.ASR.Segmenter`). The provider's
  connection for a segment is made before its speech: one waits from the
  socket's start, and the next from each segment's end. It hears nothing until
  the speech, which comes as a segment's always does (the frames just before
  it first). The provider drops a connection that hears nothing for 20 to 30
  seconds, so one still waiting after `@standby_ms` is replaced; one that
  never heard speech is dropped at the end. For each segment
  the socket sends `{"type":"partial","segment":n,"text":…}` as the guess
  changes (the whole segment so far, not a delta) and one
  `{"type":"final","segment":n,"text":…}`. After `end`, once every segment is
  final, it sends `{"type":"done"}` and closes with 1000. A text `ping` is
  answered `pong`. Nothing is stored.

  The live provider knows Mandarin and English only. When a segment is sealed,
  its audio also goes to the platform's transcription model as dictation
  (`Salix.Bindings.AgentAudioTranscriber.transcribe_dictation/1`), which knows
  every language the person may speak: its words are the segment's final
  words. The provider's last guess stays a partial meanwhile, and is the final
  when the transcription fails.

  Bounds: two sockets per member on a node, frames up to 16 KiB, three minutes
  of audio, five minutes of socket, two segments transcribed at once. Close
  codes: 1003 a frame that is not PCM, 4008 thirty seconds without audio, 4009
  the audio or the socket is too long, 4029 the member has two sockets already.
  """
  @behaviour WebSock

  import Plug.Conn

  alias SalixMeetNative.ASR
  alias SalixMeetNative.ASR.{Segment, Segmenter}

  @registry CommaWeb.DictationRegistry
  @sockets_per_member 2
  @max_frame_bytes 16 * 1024
  @max_audio_samples 3 * 60 * 16_000
  @lifetime_ms 5 * 60_000
  @silent_ms 30_000
  @check_ms 5_000
  # A connection waiting for speech is replaced after this, well before the
  # provider drops it (20 to 30 seconds without audio), the check's period included.
  @standby_ms 10_000
  # After `end`, the finals a provider still owes are given this long.
  @end_ms 15_000
  # Segments transcribed at once.
  @transcriptions 2

  @doc "The socket's path, which its ticket authorizes (`CommaWeb.Auth` asks no session)."
  def public_path?(path), do: path == "/v1/comma/dictation"

  def child_spec(_opts),
    do: SystemsRuntime.Registry.child_spec(keys: :duplicate, name: @registry)

  @doc "A ticket for the member's dictation socket: 201 `{url, ticket, expires_at}`."
  def ticket(conn, user, opts \\ []) do
    provider = Keyword.get_lazy(opts, :provider, &ASR.provider/0)

    with true <- provider != nil,
         origin when is_binary(origin) <- CommaWeb.StationOrigin.of(conn),
         {:ok, ticket} <- Comma.Dictation.ticket(user) do
      url =
        origin
        |> String.replace_prefix("https://", "wss://")
        |> String.replace_prefix("http://", "ws://")

      json(conn, 201, Map.put(ticket, "url", url <> "/v1/comma/dictation"))
    else
      {:error, :rate_limited, _} -> json(conn, 429, %{error: "rate_limited"})
      _ -> json(conn, 503, %{error: "dictation_unavailable"})
    end
  end

  def upgrade(conn, opts \\ []) do
    conn = fetch_query_params(conn)
    provider = Keyword.get_lazy(opts, :provider, &ASR.provider/0)

    transcribe =
      Keyword.get(opts, :transcribe, &Salix.Bindings.AgentAudioTranscriber.transcribe_dictation/1)

    result =
      cond do
        not websocket?(conn) -> {:error, 426, "websocket_required"}
        provider == nil -> {:error, 503, "dictation_unavailable"}
        true -> Comma.Dictation.redeem(conn.query_params["ticket"])
      end

    case result do
      {:ok, %{user_id: user_id}} ->
        upgrade_adapter(
          conn,
          :websocket,
          {__MODULE__, %{user_id: user_id, provider: provider, transcribe: transcribe},
           [compress: false, max_frame_size: @max_frame_bytes]}
        )

      {:error, status, error} ->
        reply(conn, status, error)

      {:error, :unavailable} ->
        reply(conn, 503, "dictation_unavailable")

      {:error, _} ->
        reply(conn, 401, "invalid_ticket")
    end
  end

  @impl WebSock
  def init(%{user_id: user_id, provider: provider} = args) do
    {:ok, _} = SystemsRuntime.Registry.register(@registry, user_id, nil)

    if length(SystemsRuntime.Registry.lookup(@registry, user_id)) > @sockets_per_member do
      {:stop, :normal, {4029, "too_many_sockets"}, %{}}
    else
      SystemsClock.send_after(self(), :check, @check_ms)
      SystemsClock.send_after(self(), :lifetime, @lifetime_ms)

      state = %{
        provider: provider,
        # A sealed segment's audio to its words, or nil to keep the provider's.
        transcribe: Map.get(args, :transcribe),
        segmenter: %Segmenter{},
        samples: 0,
        # Where the audio goes: the open segment, or the connection waiting for the next one.
        segment: nil,
        standby: nil,
        standby_at: nil,
        segments: %{},
        next: 0,
        ending?: false,
        observed?: false,
        last_heard: now_ms(),
        started: SystemsClock.monotonic_time()
      }

      {:ok, start_standby(state)}
    end
  end

  @impl WebSock
  def handle_in({"ping", opcode: :text}, state), do: {:push, {:text, "pong"}, state}

  def handle_in({text, opcode: :text}, %{ending?: false} = state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "end"}} ->
        SystemsClock.send_after(self(), :end_timeout, @end_ms)
        {segmenter, actions} = Segmenter.flush(state.segmenter)
        state = apply_actions(%{state | segmenter: segmenter, ending?: true}, actions)
        maybe_done(drop_standby(state), [])

      _ ->
        {:ok, state}
    end
  end

  def handle_in({pcm, opcode: :binary}, %{ending?: false} = state)
      when rem(byte_size(pcm), 2) == 0 do
    samples = state.samples + div(byte_size(pcm), 2)

    if samples > @max_audio_samples do
      stop({4009, "too_long"}, state)
    else
      {segmenter, actions} = Segmenter.push(state.segmenter, state.samples, pcm)

      state =
        apply_actions(
          %{state | segmenter: segmenter, samples: samples, last_heard: now_ms()},
          actions
        )

      {:ok, state}
    end
  end

  def handle_in({_frame, opcode: :binary}, %{ending?: false} = state),
    do: stop({1003, "pcm_expected"}, state)

  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info({:interim, segment, result}, state) do
    case state.segments[segment] do
      %{final?: false} = meta ->
        if meta.text == "", do: observe_first_result(meta)
        state = put_in(state.segments[segment].text, result.text)
        {:push, {:text, frame("partial", meta.index, result.text)}, state}

      _ ->
        {:ok, state}
    end
  end

  # While the segment's transcription is to come, the provider's words stay a partial.
  def handle_info({:final, segment, result}, state) do
    case state.segments[segment] do
      %{final?: false, transcription: pending} = meta when pending in [:queued, :running] ->
        state = put_in(state.segments[segment], %{meta | text: result.text, heard?: true})
        {:push, {:text, frame("partial", meta.index, result.text)}, state}

      %{final?: false} = meta ->
        state = put_in(state.segments[segment], %{meta | text: result.text, heard?: true})
        settle(state, segment, result.text)

      _ ->
        {:ok, state}
    end
  end

  # The transcription's words are the segment's. When it failed, the
  # provider's are, once it has settled them.
  def handle_info({:transcribed, segment, result}, state) do
    case {state.segments[segment], result} do
      {%{final?: false}, {:ok, text}} when is_binary(text) and text != "" ->
        state =
          state |> put_in([:segments, segment, :transcription], :done) |> start_transcriptions()

        settle(state, segment, String.trim(text))

      {%{final?: false} = meta, _failed} ->
        state =
          state |> put_in([:segments, segment, :transcription], :failed) |> start_transcriptions()

        if meta.heard?, do: settle(state, segment, meta.text), else: {:ok, state}

      _ ->
        {:ok, start_transcriptions(state)}
    end
  end

  # A segment the provider gave up on keeps its last guess as its words, unless
  # its transcription is still to come. A waiting connection that failed is made
  # again when speech comes.
  def handle_info({:DOWN, _ref, :process, segment, _reason}, state) do
    state = if state.segment == segment, do: %{state | segment: nil}, else: state

    case state.segments[segment] do
      nil when state.standby == segment ->
        {:ok, %{state | standby: nil}}

      nil ->
        {:ok, state}

      %{final?: true} ->
        maybe_done(%{state | segments: Map.delete(state.segments, segment)}, [])

      %{transcription: pending} = meta when pending in [:queued, :running] ->
        {:ok, put_in(state.segments[segment], %{meta | heard?: true, gone?: true})}

      meta ->
        settle(put_in(state.segments[segment].gone?, true), segment, meta.text)
    end
  end

  def handle_info(:check, %{ending?: false} = state) do
    if now_ms() - state.last_heard > @silent_ms do
      stop({4008, "silent"}, state)
    else
      SystemsClock.send_after(self(), :check, @check_ms)
      {:ok, refresh_standby(state)}
    end
  end

  def handle_info(:lifetime, state), do: stop({4009, "too_long"}, state)
  # Segments the provider has not settled by then keep their last guess as their final words.
  def handle_info(:end_timeout, state) do
    finals =
      state.segments
      |> Map.values()
      |> Enum.reject(& &1.final?)
      |> Enum.sort_by(& &1.index)
      |> Enum.map(&{:text, frame("final", &1.index, &1.text)})

    done(state, finals)
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  # A socket the client closed, or that failed, before it ended on its own.
  def terminate(_reason, %{observed?: false} = state), do: observe(state, "cancelled")
  def terminate(_reason, _state), do: :ok

  defp apply_actions(state, actions) do
    Enum.reduce(actions, state, fn
      # Speech: the waiting connection (made now if there is none) becomes the segment's.
      {:open, _start}, state ->
        state = if state.standby, do: state, else: start_standby(state)

        meta = %{
          index: state.next,
          text: "",
          final?: false,
          # The provider settled its words, or gave up.
          heard?: false,
          gone?: false,
          # The segment's audio, newest first until it is sealed, then whole until transcribed.
          audio: [],
          # :none, :queued, :running, :done or :failed.
          transcription: :none,
          opened: SystemsClock.monotonic_time()
        }

        %{
          state
          | standby: nil,
            segments: Map.put(state.segments, state.segment, meta),
            next: state.next + 1
        }

      {:audio, pcm}, %{segment: segment} = state when is_pid(segment) ->
        Segment.audio(segment, pcm)

        case state.segments[segment] do
          %{audio: audio} when state.transcribe != nil ->
            put_in(state.segments[segment].audio, [pcm | audio])

          _ ->
            state
        end

      # The next segment's connection is made in the pause, unless the speaker is done.
      :seal, %{segment: segment} = state when is_pid(segment) ->
        Segment.seal(segment)
        state = state |> transcribe(segment) |> Map.put(:segment, nil)
        if state.ending?, do: state, else: start_standby(state)

      _action, state ->
        state
    end)
  end

  defp transcribe(%{transcribe: transcribe} = state, segment) when transcribe != nil do
    case state.segments[segment] do
      %{audio: [_ | _] = audio} = meta ->
        pcm = audio |> Enum.reverse() |> IO.iodata_to_binary()
        state = put_in(state.segments[segment], %{meta | audio: pcm, transcription: :queued})
        start_transcriptions(state)

      _ ->
        state
    end
  end

  defp transcribe(state, _segment), do: state

  # At most `@transcriptions` segments are transcribed at once, the earliest first.
  defp start_transcriptions(state) do
    metas = Map.to_list(state.segments)
    running = Enum.count(metas, fn {_segment, meta} -> meta.transcription == :running end)

    metas
    |> Enum.filter(fn {_segment, meta} -> meta.transcription == :queued end)
    |> Enum.sort_by(fn {_segment, meta} -> meta.index end)
    |> Enum.take(max(@transcriptions - running, 0))
    |> Enum.reduce(state, fn {segment, meta}, state ->
      {transcribe, pcm, owner} = {state.transcribe, meta.audio, SystemsRuntime.Proc.self()}

      SystemsRuntime.Task.start(fn ->
        SystemsRuntime.Proc.send(owner, {:transcribed, segment, safely(transcribe, pcm)})
      end)

      put_in(state.segments[segment], %{meta | audio: [], transcription: :running})
    end)
  end

  defp safely(transcribe, pcm) do
    transcribe.(pcm)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The segment's final words; a segment whose provider is gone is done.
  defp settle(state, segment, text) do
    meta = %{state.segments[segment] | text: text, final?: true}

    segments =
      if meta.gone?,
        do: Map.delete(state.segments, segment),
        else: Map.put(state.segments, segment, meta)

    maybe_done(%{state | segments: segments}, [{:text, frame("final", meta.index, text)}])
  end

  defp start_standby(state) do
    {module, config} = state.provider
    {:ok, segment} = Segment.start(provider: module, config: config, interim: true)
    Process.monitor(segment)
    %{state | segment: segment, standby: segment, standby_at: now_ms()}
  end

  # A connection that heard no speech for `@standby_ms` gives way to a new one.
  defp refresh_standby(%{standby: segment, standby_at: at} = state) when is_pid(segment) do
    if now_ms() - at > @standby_ms, do: state |> drop_standby() |> start_standby(), else: state
  end

  defp refresh_standby(state), do: state

  defp drop_standby(%{standby: segment} = state) when is_pid(segment) do
    Process.exit(segment, :kill)
    %{state | segment: nil, standby: nil}
  end

  defp drop_standby(state), do: state

  defp maybe_done(%{ending?: true} = state, frames) do
    if Enum.all?(Map.values(state.segments), & &1.final?),
      do: done(state, frames),
      else: frames(state, frames)
  end

  defp maybe_done(state, frames), do: frames(state, frames)

  defp frames(state, []), do: {:ok, state}
  defp frames(state, frames), do: {:push, frames, state}

  defp done(state, frames) do
    observe(state, "ok")

    {:stop, :normal, 1000, frames ++ [{:text, Jason.encode!(%{"type" => "done"})}],
     %{state | observed?: true}}
  end

  defp stop(close, state) do
    observe(state, "error")
    {:stop, :normal, close, Map.put(state, :observed?, true)}
  end

  defp frame(type, index, text),
    do: Jason.encode!(%{"type" => type, "segment" => index, "text" => text})

  # How long the socket lasted; the provider's usage is counted from its audio.
  defp observe(%{started: started}, outcome) do
    Salix.Telemetry.emit_operation(
      "salix_meet",
      "dictation_stream",
      "comma",
      outcome,
      SystemsClock.monotonic_time() - started
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp observe(_state, _outcome), do: :ok

  # How long after a segment's speech began its first words came.
  defp observe_first_result(%{opened: opened}) do
    Salix.Telemetry.emit_operation(
      "salix_meet",
      "dictation_first_result",
      "comma",
      "ok",
      SystemsClock.monotonic_time() - opened
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp reply(conn, status, error), do: json(conn, status, %{error: error})

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp websocket?(conn) do
    conn.method == "GET" and
      Enum.any?(get_req_header(conn, "upgrade"), &(String.downcase(&1) == "websocket"))
  end

  defp now_ms, do: SystemsClock.monotonic_time(:millisecond)
end
