defmodule SalixMeetNative.Session do
  @moduledoc false
  use GenServer, restart: :temporary

  require Logger

  alias SalixMeetNative.{
    Codec,
    Device,
    Events,
    Frames,
    MediaSession,
    Recorder,
    Rpc,
    SyncLoop,
    TokenFactory,
    TokenSource,
    Transport,
    Wire
  }

  alias SalixMeetNative.Events.Event

  @collections_timeout_ms 8_000
  @captions_ready_timeout_ms 8_000
  @knock_timeout_ms 600_000
  @stable_connection_ms 60_000
  @max_consecutive_attempts 4
  @max_total_attempts 20
  @join_complete_attempts 12
  @join_complete_poll_ms 3_000

  @stop_reasons %{
    "denied" => :admission_denied,
    "denied_full" => :meeting_full,
    "ejected" => :removed_from_meeting
  }

  @handoff_retry_ms 2_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def send_chat(pid, text, message_id \\ nil),
    do: SystemsClock.call(pid, {:send_chat, text, message_id}, 5_000)

  def send_reaction(pid, emoji), do: SystemsClock.call(pid, {:send_reaction, emoji}, 5_000)
  def raise_hand(pid), do: SystemsClock.call(pid, :raise_hand, 30_000)

  def set_caption_lang(pid, display, spoken \\ nil),
    do: SystemsClock.call(pid, {:set_caption_lang, display, spoken || display}, 5_000)

  def participants(pid), do: SystemsClock.call(pid, :participants, 5_000)
  def status(pid), do: SystemsClock.call(pid, :status, 5_000)
  def leave(pid), do: SystemsClock.call(pid, :leave, 15_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    url = Keyword.fetch!(opts, :url)
    subscriber = Keyword.fetch!(opts, :subscriber)
    Process.monitor(subscriber)

    state = %{
      url: url,
      subscriber: subscriber,
      profile: Keyword.get(opts, :profile),
      captions: Keyword.get(opts, :captions, [{"en-US", "en-US"}]),
      native: native_config(opts),
      total: 0,
      consecutive: 0,
      last_error: nil,
      chat_dedupe: %{},
      roster: [],
      attempt: nil,
      recorder: start_recorder(Keyword.get(opts, :recording_dir), url, opts[:subscriber])
    }

    {:ok, state, {:continue, :attempt}}
  end

  @impl true
  def handle_continue(:attempt, state) do
    total = state.total + 1
    consecutive = state.consecutive + 1

    if total > @max_total_attempts or consecutive > @max_consecutive_attempts do
      finish(state, {:gave_up, state.last_error})
    else
      Logger.info("meet native: attempt #{total} (consecutive #{consecutive})")
      status(state, :resolving_space)
      task = Task.async(fn -> bootstrap_native(state) end)

      {:noreply,
       %{state | total: total, consecutive: consecutive, attempt: new_attempt(task, :bootstrap)}}
    end
  end

  @impl true
  def handle_call({:send_chat, text, ""}, from, state),
    do: handle_call({:send_chat, text, nil}, from, state)

  def handle_call({:send_chat, text, message_id}, _from, state) do
    case {message_id && Map.fetch(state.chat_dedupe, message_id), state.attempt} do
      {{:ok, ^text}, _} ->
        {:reply, :ok, state}

      {{:ok, _other}, _} ->
        {:reply, {:error, :message_id_reused}, state}

      {_, %{transport: transport} = a} when is_pid(transport) ->
        seq = a.chat_seq + 1

        case Transport.send_data(
               transport,
               "meet_messages",
               Frames.chat(seq, SystemsClock.system_time(:millisecond), text)
             ) do
          :ok ->
            dedupe =
              if message_id,
                do: Map.put(state.chat_dedupe, message_id, text),
                else: state.chat_dedupe

            {:reply, :ok, %{state | attempt: %{a | chat_seq: seq}, chat_dedupe: dedupe}}

          error ->
            {:reply, error, state}
        end

      _ ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:send_reaction, emoji}, _from, %{attempt: %{transport: t} = a} = state)
      when is_pid(t) do
    seq = a.reaction_seq + 1
    reply = Transport.send_data(t, "reactions", Frames.reaction(seq, emoji))
    {:reply, reply, %{state | attempt: %{a | reaction_seq: seq}}}
  end

  def handle_call(:raise_hand, _from, %{attempt: %{client: client}} = state)
      when is_map(client),
      do: {:reply, Device.create_hand_raise(client), state}

  def handle_call(
        {:set_caption_lang, display, spoken},
        _from,
        %{attempt: %{transport: t} = a} = state
      )
      when is_pid(t) do
    req = 9100 + a.caption_req + 1

    reply =
      with :ok <- Transport.open_channel(t, "captions"),
           do:
             Transport.send_data(t, "media-session", Frames.caption_enable(req, display, spoken))

    captions = if reply == :ok, do: [{display, spoken}], else: state.captions
    {:reply, reply, %{state | captions: captions, attempt: %{a | caption_req: a.caption_req + 1}}}
  end

  def handle_call(:participants, _from, state), do: {:reply, state.roster, state}

  def handle_call(:status, _from, %{attempt: a} = state),
    do:
      {:reply,
       %{phase: a && a.phase, self_device: a && a.self_device, self_state: a && a.self_state},
       state}

  def handle_call(:leave, from, state) do
    GenServer.reply(from, :ok)
    state = state |> leave(:requested) |> finish_recording()
    send(state.subscriber, {:meet_native, self(), {:ended, :left}})
    {:stop, :normal, state}
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :not_connected}, state}

  @impl true
  def handle_info({ref, result}, %{attempt: %{task: %Task{ref: ref}, step: step}} = state) do
    Process.demonitor(ref, [:flush])
    step_result(put_attempt(state, task: nil), step, result)
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{attempt: %{task: %Task{ref: ref}, step: step}} = state
      ),
      do: crashed_step(put_attempt(state, task: nil), step, reason)

  def handle_info({:meet_transport, t, msg}, %{attempt: %{transport: t}} = state),
    do: transport_msg(state, msg)

  def handle_info({:meet_transport, _stale, _msg}, state), do: {:noreply, state}

  def handle_info({:meet_sync, pid, msg}, %{attempt: %{sync: pid}} = state),
    do: sync_msg(state, msg)

  def handle_info({:meet_sync, _stale, _msg}, state), do: {:noreply, state}

  def handle_info(
        {:join_complete, attempt_id, mode, result},
        %{attempt: %{id: attempt_id}} = state
      ) do
    Logger.info("meet native: join completion #{mode} #{inspect(result)}")
    task_field = if mode == :gated, do: :gated_task, else: :prereq_task
    {:noreply, put_attempt(state, [{task_field, nil}])}
  end

  def handle_info({:timer, attempt_id, name}, %{attempt: %{id: attempt_id}} = state),
    do: timer(state, name)

  def handle_info({:retry_attempt, attempt_id}, %{attempt: %{id: attempt_id}} = state),
    do: handle_continue(:attempt, %{state | attempt: nil})

  def handle_info({:retry_attempt, _stale}, state), do: {:noreply, state}

  def handle_info({:timer, _stale, _name}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{attempt: %{transport: pid}} = state)
      when reason != :normal,
      do: rejoin_or_finish(put_attempt(state, transport: nil), {:transport_crashed, reason})

  def handle_info({:EXIT, pid, reason}, %{attempt: %{sync: pid}} = state)
      when reason not in [:normal, :killed] do
    Logger.warning("meet native: sync loop exited #{inspect(reason)}")
    {:noreply, put_attempt(state, sync: nil)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscriber: pid} = state),
    do: {:stop, :normal, state |> leave(:subscriber_down) |> finish_recording()}

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{recorder: pid} = state) do
    Logger.warning("meet native: recording stopped #{inspect(reason)}")
    {:noreply, %{state | recorder: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = if state.attempt, do: leave_attempt(state), else: state
    finish_recording(state)
    :ok
  end

  defp step_result(state, :bootstrap, {:ok, ctx}), do: create_media_session_native(state, ctx)

  defp step_result(%{last_error: last} = state, :bootstrap, {:error, reason}) when last != nil do
    if transient_native_error?(reason),
      do: retry_handoff(state, {:native, reason}),
      else: finish(state, {:native, reason})
  end

  defp step_result(state, :bootstrap, {:error, reason}), do: finish(state, {:native, reason})

  defp step_result(state, :media_session, {:ok, 200, body, headers}) do
    with {:ok, answer} <- decode_answer(body),
         :ok <- Transport.connect(state.attempt.transport, answer) do
      msid = MediaSession.media_session_id(answer)
      status(state, {:media_session, msid})

      state =
        put_attempt(state,
          msid: msid,
          compass: Rpc.header(headers, "x-compass-routing-destination")
        )

      register_device(state)
    else
      {:error, reason} -> fail_attempt(state, {:create_media_session, reason})
    end
  end

  defp step_result(state, :media_session, {:ok, status, body, _headers}),
    do: fail_attempt(state, {:create_media_session, status, snippet(body)})

  defp step_result(state, :media_session, {:error, reason}),
    do: fail_attempt(state, {:create_media_session, reason})

  defp step_result(state, :device, result), do: device_registered(state, result)

  defp retry_handoff(state, reason) do
    %{attempt: a} = state = leave_attempt(state)
    Logger.warning("meet native: handoff failed #{inspect(reason)}, retrying")
    status(state, {:rejoining, reason})
    SystemsClock.send_after(self(), {:retry_attempt, a.id}, @handoff_retry_ms * state.consecutive)
    {:noreply, %{state | last_error: reason}}
  end

  defp native_config(opts) do
    %{token_opts: Keyword.take(opts, [:bearer, :master_token_factory])}
  end

  defp bootstrap_native(state) do
    with {:ok, code} <- meeting_code(state.url),
         {:ok, bearer} <- TokenSource.fetch_bearer(state.profile, state.native.token_opts),
         {:ok, space, token} <- resolve_space(bearer, code) do
      {:ok,
       %{
         bearer: bearer,
         code: code,
         space: space,
         meeting_token: token,
         identifier: space_identifier(space),
         debugid: Rpc.debug_id()
       }}
    end
  end

  defp meeting_code(url) do
    case TokenFactory.normalize_meeting_url(url) do
      {:ok, normalized} -> {:ok, normalized |> URI.parse() |> Map.get(:path) |> String.trim("/")}
      other -> {:error, {:bad_meeting_url, other}}
    end
  end

  defp resolve_space(bearer, code) do
    body = Codec.encode(%Wire.ResolveMeetingSpaceRequest{meeting_code: code})

    case Rpc.call_http("ResolveMeetingSpace", "MeetingSpaceService", body, bearer) do
      {:ok, 200, resp, headers} ->
        case Codec.decode_rpc_response(Wire.ResolveMeetingSpaceResponse, resp) do
          {:ok, %Wire.ResolveMeetingSpaceResponse{space: space}}
          when is_binary(space) and space != "" ->
            {:ok, space, Rpc.header(headers, "x-goog-meeting-token")}

          _ ->
            {:error, :resolve_no_space}
        end

      {:ok, status, body, _headers} ->
        {:error, {:resolve, status, snippet(body)}}

      {:error, reason} ->
        {:error, {:resolve, reason}}
    end
  end

  defp space_identifier(space) do
    sid = String.replace_prefix(space, "spaces/", "")

    %Wire.MeetingIdentifier{
      identifier_kind: :MEETING_IDENTIFIER_KIND_SPACE_SHORT_ID,
      space_id: sid
    }
    |> Codec.encode()
    |> Base.encode64()
  end

  defp transient_native_error?(reason) do
    case reason do
      :timeout -> true
      {:token_factory_unreachable, _} -> true
      {:token_factory_status, status} -> status == 429 or status >= 500
      {:resolve, status, _} when is_integer(status) -> status >= 500
      {:resolve, _} -> true
      _ -> false
    end
  end

  defp create_media_session_native(state, ctx) do
    sink = if state.recorder, do: {state.recorder, state.attempt.id}
    {:ok, transport} = Transport.start_link(owner: self(), rtp_sink: sink)
    params = Transport.local_params(transport)

    state =
      put_attempt(state,
        transport: transport,
        native: ctx,
        dcrpc_request_id: Frames.dcrpc_request_id(),
        phase: :creating_media_session
      )

    case MediaSession.build_offer(offer_template(), params.fingerprint, params.ufrag, params.pwd) do
      {:ok, offer} ->
        cx = %{
          token: ctx.meeting_token,
          identifier: ctx.identifier,
          debugid: ctx.debugid,
          code: ctx.code
        }

        run_step(state, :media_session, fn ->
          Rpc.call_meet("CreateMediaSession", "MediaSessionService", offer, {:api_key, nil}, cx)
        end)

      {:error, reason} ->
        fail_attempt(state, {:create_media_session, reason})
    end
  end

  defp offer_template do
    :salix_meet_native
    |> Application.app_dir("priv/createmediasession-offer.bin.gz")
    |> File.read!()
  end

  defp crashed_step(state, :device, reason),
    do: rejoin_or_finish(state, {:device, {:crashed, reason}})

  defp crashed_step(state, step, reason), do: fail_attempt(state, {step, {:crashed, reason}})

  defp fail_attempt(state, reason) do
    Logger.warning("meet native: attempt failed #{inspect(reason)}")
    finish(leave_attempt(state), reason)
  end

  defp run_step(state, step, fun),
    do: {:noreply, put_attempt(state, task: Task.async(fun), step: step)}

  defp decode_answer(body) do
    case MediaSession.decode_answer(body) do
      {:ok, answer} -> {:ok, answer}
      :error -> {:error, :undecodable_answer}
    end
  end

  defp register_device(%{attempt: %{native: ctx} = a} = state) do
    body = Device.create_body(ctx.space, a.msid)

    cx = %{
      token: ctx.meeting_token,
      identifier: ctx.identifier,
      debugid: ctx.debugid,
      code: ctx.code,
      compass: a.compass
    }

    run_step(state, :device, fn ->
      Rpc.call_meet(
        "CreateMeetingDevice",
        "MeetingDeviceService",
        body,
        {:bearer, ctx.bearer},
        cx
      )
    end)
  end

  defp device_registered(%{attempt: %{native: ctx}} = state, result) do
    with {:ok, 200, resp, headers} <- result do
      compass = Rpc.header(headers, "x-compass-routing-destination") || state.attempt.compass
      token = Rpc.header(headers, "x-goog-meeting-token") || ctx.meeting_token

      client = %{
        bearer: ctx.bearer,
        token: token,
        identifier: ctx.identifier,
        compass: compass,
        debugid: ctx.debugid,
        space: ctx.space
      }

      state =
        put_attempt(state,
          client: client,
          compass: compass,
          phase: :registered,
          registered_at: now()
        )

      finalize_registration(state, resp, &start_sync_native(&1, ctx, token, compass))
    else
      {:ok, status, body, _headers} ->
        rejoin_or_finish(state, {:device_register, status, snippet(body)})

      {:error, reason} ->
        rejoin_or_finish(state, {:device_register, reason})
    end
  end

  defp finalize_registration(state, resp, sync_fun) do
    state =
      case Device.decode_registered(resp) do
        {:ok, self_device} ->
          state = put_attempt(state, self_device: self_device.name)
          status(state, {:self_device, self_device.name})

          self_state = self_status(self_device.join_state)

          state =
            if self_state,
              do: self_state_changed(state, self_state, :registration),
              else: arm_knock_timer(state)

          if self_state == "joined", do: state, else: complete_join_if_gated(state)

        :error ->
          state
      end

    state
    |> sync_fun.()
    |> open_captions()
    |> schedule(:collections_timeout, @collections_timeout_ms)
    |> schedule(:dcrpc_search, 0)
    |> then(&{:noreply, &1})
  end

  defp start_sync_native(state, ctx, token, compass) do
    headers =
      %{
        "x-goog-meeting-rtcclient" => Rpc.rtcclient(),
        "x-goog-meeting-debugid" => ctx.debugid,
        "x-goog-encode-response-if-executable" => "base64"
      }
      |> maybe_put("x-goog-meeting-identifier", ctx.identifier)
      |> maybe_put("x-compass-routing-destination", compass)
      |> maybe_put("x-goog-meeting-token", token || ctx.meeting_token)

    template = %SyncLoop{
      url: Rpc.base_url() <> "MeetingSpaceService/SyncMeetingSpaceCollections",
      headers: headers,
      user_agent: Rpc.safari_ua(),
      space: ctx.space,
      first_body: nil,
      bearer: ctx.bearer
    }

    {:ok, pid} = SyncLoop.start_link(self(), template)
    put_attempt(state, sync: pid)
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp open_captions(%{captions: []} = state), do: state

  defp open_captions(%{attempt: a} = state) do
    Transport.open_channel(a.transport, "captions")
    state = put_attempt(state, captions_opened?: true)

    if a.ms_generation > 0,
      do: send_captions(state),
      else: schedule(state, :captions_ready_timeout, @captions_ready_timeout_ms)
  end

  defp send_captions(%{attempt: %{captions_sent?: true}} = state), do: state

  defp send_captions(%{attempt: a} = state) do
    state.captions
    |> Enum.with_index(9000)
    |> Enum.each(fn {{display, spoken}, req} ->
      Transport.send_data(
        a.transport,
        "media-session",
        Frames.caption_enable(req, display, spoken)
      )
    end)

    put_attempt(state, captions_sent?: true)
  end

  defp transport_msg(state, {:channel_open, label}) do
    t = state.attempt.transport

    case label do
      "media-session" ->
        Transport.send_data(t, label, Frames.media_session_initial(1))
        {:noreply, schedule(state, :media_session_keepalive, 30_000)}

      "media-director" ->
        Transport.send_data(t, label, Frames.media_director_initial_go())
        {:noreply, schedule(state, :media_director_video, 300)}

      "meeting-agent" ->
        {:noreply, schedule(state, :heartbeat, 1_000)}

      "collections" ->
        status(state, :collections_open)
        {:noreply, put_attempt(state, collections_open?: true)}

      _ ->
        {:noreply, state}
    end
  end

  defp transport_msg(state, {:data, label, data}) do
    state = observe(state, label, data)
    if label == "collections" and state.recorder, do: record_audio_sources(state.recorder, data)

    if label in ["collections", "captions"],
      do: Logger.debug("meet native #{label} frame #{Base.encode16(data, case: :lower)}")

    {:noreply, label |> Events.decode(data) |> Enum.reduce(state, &handle_event(&2, &1))}
  end

  defp transport_msg(state, {:failed, reason}) do
    if state.attempt.phase in [:registered, :in_meeting] do
      rejoin_or_finish(leave_attempt(state), {:connection_failed, reason})
    else
      {:noreply, state}
    end
  end

  defp transport_msg(state, {:ice, ice_state}) do
    status(state, {:ice, ice_state})
    {:noreply, state}
  end

  defp transport_msg(state, msg) when msg in [:dtls_connected, :sctp_connected] do
    status(state, msg)
    {:noreply, state}
  end

  defp transport_msg(state, _msg), do: {:noreply, state}

  defp observe(%{attempt: a} = state, "media-session", data) when byte_size(data) > 64 do
    gen =
      case Frames.media_session_generation(data) do
        {:ok, g} -> max(g, a.ms_generation)
        :error -> a.ms_generation
      end

    if gen > 0 do
      Transport.send_data(a.transport, "media-session", Frames.media_session_ack(gen))
      state = put_attempt(state, ms_generation: gen)
      if a.ms_generation == 0 and a.captions_opened?, do: send_captions(state), else: state
    else
      state
    end
  end

  defp observe(%{attempt: a} = state, "media-director", data) when byte_size(data) > 64 do
    seq = a.md_seq + 1
    Transport.send_data(a.transport, "media-director", Frames.media_director_video(seq))
    put_attempt(state, md_seq: seq)
  end

  defp observe(%{attempt: a} = state, "dcrpc", data) do
    with {:ok, req_id, counter} <- Frames.dcrpc_search_response(data),
         {kind, pending} when kind != nil <- Map.pop(a.dcrpc_pending, req_id) do
      put_attempt(state,
        dcrpc_pending: pending,
        dcrpc_counters: Map.put(a.dcrpc_counters, kind, counter)
      )
    else
      _ -> state
    end
  end

  defp observe(state, _label, _data), do: state

  defp sync_msg(state, {:events, events}),
    do: {:noreply, Enum.reduce(events, state, &handle_event(&2, &1))}

  defp sync_msg(state, {:roster, roster}) do
    if roster_view(roster) != roster_view(state.roster),
      do: Logger.info("meet native: roster #{inspect(roster_view(roster))}")

    send(state.subscriber, {:meet_native, self(), {:roster, roster}})

    {:noreply, %{state | roster: roster}}
  end

  defp sync_msg(%{attempt: %{client: client}} = state, {:token, token}) when is_map(client),
    do: {:noreply, put_attempt(state, client: %{client | token: token})}

  defp sync_msg(state, other) do
    Logger.debug("meet native sync: #{inspect(other)}")
    {:noreply, state}
  end

  defp handle_event(state, %Event{} = event) do
    send(state.subscriber, {:meet_native, self(), {:event, event}})

    with %Event{type: "participant", payload: %{"device" => dev, "name" => name}}
         when is_pid(state.recorder) <- event do
      Recorder.set_participant_name(state.recorder, dev, name)
    end

    case event do
      %Event{type: "participant", payload: %{"device" => dev} = p}
      when dev == state.attempt.self_device and dev != nil ->
        case p["state"] do
          st when is_binary(st) and st != "" and st != state.attempt.self_state ->
            self_state_changed(state, st)

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp self_state_changed(%{attempt: a} = state, st, origin \\ :event) do
    state = put_attempt(state, self_state: st)

    cond do
      reason = @stop_reasons[st] ->
        send(self(), {:timer, a.id, {:stop, reason}})
        put_attempt(state, ending: reason)

      st == "joined" ->
        if a.knock_timer, do: SystemsClock.cancel_timer(a.knock_timer)
        status(state, %{self: st})
        put_attempt(state, knock_timer: nil, phase: :in_meeting)

      true ->
        # Any other state (knocking, lobby, waiting, missing_cse_key, error, ...)
        # is not admitted; the admission timeout bounds how long the bot waits.
        status(state, %{self: st})
        state = arm_knock_timer(state)

        if st == "missing_prerequisites" and origin == :event,
          do: clear_prerequisites(state),
          else: state
    end
  end

  defp arm_knock_timer(%{attempt: %{knock_timer: ref}} = state) when ref != nil, do: state

  defp arm_knock_timer(state),
    do: schedule(state, :knock_timeout, @knock_timeout_ms, :knock_timer)

  defp complete_join_if_gated(state),
    do: put_attempt(state, gated_task: start_complete_join(state, :gated))

  defp clear_prerequisites(%{attempt: %{prereq_task: pid}} = state) when is_pid(pid), do: state

  defp clear_prerequisites(state),
    do: put_attempt(state, prereq_task: start_complete_join(state, :admitted))

  defp start_complete_join(%{attempt: a}, mode) do
    parent = self()
    %{client: client, self_device: device, msid: msid, id: id} = a

    {:ok, pid} =
      Task.start_link(fn ->
        result = complete_join(client, device, msid, mode, MapSet.new(), 0)
        send(parent, {:join_complete, id, mode, result})
      end)

    pid
  end

  defp complete_join(_client, _device, _msid, :gated, _acked, attempt)
       when attempt >= @join_complete_attempts,
       do: :gave_up

  defp complete_join(client, device, msid, mode, acked, attempt) do
    case Device.pending_acks(client, device) do
      {:ok, _ops, :DEVICE_JOIN_STATE_JOINED} ->
        :joined

      {:ok, _ops, js}
      when mode == :admitted and
             js not in [:DEVICE_JOIN_STATE_KNOCKING, :DEVICE_JOIN_STATE_MISSING_PREREQUISITES] ->
        {:left_lobby, js}

      {:ok, ops, _js} ->
        acked =
          Enum.reduce(ops, acked, fn op, acc ->
            if op in acc or Device.acknowledge_operation(client, device, op) != :ok,
              do: acc,
              else: MapSet.put(acc, op)
          end)

        if MapSet.size(acked) > 0, do: Device.mark_joined(client, device, msid)
        SystemsClock.sleep(@join_complete_poll_ms)
        complete_join(client, device, msid, mode, acked, attempt + 1)

      {:error, _reason} ->
        SystemsClock.sleep(@join_complete_poll_ms)
        complete_join(client, device, msid, mode, acked, attempt + 1)
    end
  end

  defp timer(%{attempt: a} = state, :heartbeat) do
    Transport.send_data(
      a.transport,
      "meeting-agent",
      Frames.meeting_agent_heartbeat(SystemsClock.system_time(:second))
    )

    {:noreply, schedule(state, :heartbeat, 1_000)}
  end

  defp timer(%{attempt: a} = state, :media_session_keepalive) do
    Transport.send_data(
      a.transport,
      "media-session",
      Frames.media_session_outbound(a.ms_seq, a.ms_generation + 1)
    )

    {:noreply,
     state |> put_attempt(ms_seq: a.ms_seq + 1) |> schedule(:media_session_keepalive, 30_000)}
  end

  defp timer(%{attempt: a} = state, :media_director_video) do
    Transport.send_data(a.transport, "media-director", Frames.media_director_video(1))
    {:noreply, state}
  end

  defp timer(state, :captions_ready_timeout), do: {:noreply, send_captions(state)}

  defp timer(%{attempt: %{collections_open?: true}} = state, :collections_timeout),
    do: {:noreply, state}

  defp timer(state, :collections_timeout),
    do: rejoin_or_finish(leave_attempt(state), :collections_down)

  defp timer(%{attempt: a} = state, :knock_timeout) do
    if a.self_state != "joined",
      do: finish(leave_attempt(state), :admission_timeout),
      else: {:noreply, put_attempt(state, knock_timer: nil)}
  end

  defp timer(state, {:stop, reason}), do: finish(leave_attempt(state), reason)

  defp timer(%{attempt: a} = state, :dcrpc_search) do
    if Transport.channel_open?(a.transport, "dcrpc") do
      counters = if rem(a.dcrpc_cycle, 3) == 0, do: %{}, else: a.dcrpc_counters
      kinds = if rem(a.dcrpc_cycle, 2) == 1, do: [2, 1], else: [1, 2]

      {seq, pending} =
        Enum.reduce(kinds, {a.dcrpc_seq, a.dcrpc_pending}, fn kind, {seq, pending} ->
          seq = seq + 1

          frame =
            Frames.dcrpc_refresh(
              seq,
              a.msid,
              Frames.refresh_client_info(),
              kind,
              Map.get(counters, kind)
            )

          Transport.send_data(a.transport, "dcrpc", frame)
          {seq, Map.put(pending, seq, kind)}
        end)

      # Declare the bot's own (muted) send streams so the SFU registers it in the media graph.
      pub_seq = seq + 1

      Transport.send_data(
        a.transport,
        "dcrpc",
        Frames.publish(pub_seq, a.msid, a.dcrpc_request_id)
      )

      state =
        put_attempt(state,
          dcrpc_seq: pub_seq,
          dcrpc_pending: pending,
          dcrpc_cycle: a.dcrpc_cycle + 1
        )

      {:noreply, schedule(state, :dcrpc_search, 30_000)}
    else
      {:noreply, schedule(state, :dcrpc_search, 1_000)}
    end
  end

  defp rejoin_or_finish(%{attempt: %{ending: ending}} = state, _reason) when ending != nil,
    do: finish(leave_attempt(state), ending)

  defp rejoin_or_finish(state, reason) do
    %{attempt: a} = state = leave_attempt(state)
    Logger.warning("meet native: attempt failed #{inspect(reason)}")
    stable? = a.registered_at != nil and now() - a.registered_at > @stable_connection_ms

    state = %{
      state
      | last_error: reason,
        consecutive: if(stable?, do: 0, else: state.consecutive)
    }

    status(state, {:rejoining, reason})
    {:noreply, %{state | attempt: nil}, {:continue, :attempt}}
  end

  defp finish(state, reason) do
    Logger.info("meet native: ended #{inspect(reason)}")
    state = finish_recording(state)
    send(state.subscriber, {:meet_native, self(), {:ended, reason}})
    {:stop, :normal, state}
  end

  defp record_audio_sources(recorder, data) do
    for %{device: device, ssrc: stream} <- Frames.media_streams(data, :audio) do
      Logger.debug("meet native: audio source #{stream} -> #{device}")
      Recorder.set_audio_source(recorder, stream, device)
    end
  end

  defp start_recorder(nil, _url, _subscriber), do: nil

  defp start_recorder(dir, url, subscriber) do
    code =
      case TokenFactory.normalize_meeting_url(url) do
        {:ok, normalized} -> normalized |> URI.parse() |> Map.get(:path) |> String.trim("/")
        _ -> ""
      end

    case Recorder.start(dir, meeting_code: code, owner: self(), asr_subscriber: subscriber) do
      {:ok, recorder} ->
        Process.monitor(recorder)
        recorder

      {:error, reason} ->
        Logger.warning("meet native: recording unavailable #{inspect(reason)}")
        nil
    end
  end

  defp finish_recording(%{recorder: nil} = state), do: state

  defp finish_recording(%{recorder: recorder} = state) do
    case safe_finish(recorder) do
      {:ok, %{} = files} -> send(state.subscriber, {:meet_native, self(), {:recording, files}})
      other -> Logger.info("meet native: no recording #{inspect(other)}")
    end

    %{state | recorder: nil}
  end

  defp safe_finish(recorder) do
    Recorder.finish(recorder)
  catch
    :exit, reason -> {:error, reason}
  end

  defp leave(%{attempt: nil} = state, _reason), do: state
  defp leave(state, _reason), do: leave_attempt(state)

  defp leave_attempt(%{attempt: %{phase: :left}} = state), do: state

  defp leave_attempt(%{attempt: a} = state) do
    if a.task, do: Task.shutdown(a.task, :brutal_kill)

    for pid <- [a.prereq_task, a.gated_task], is_pid(pid) do
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end

    if state.recorder, do: Recorder.end_attempt(state.recorder, a.id)

    if a.client && a.self_device do
      result = Device.mark_left(a.client, a.self_device, timeout_ms: 5_000)
      Logger.info("meet native: left #{a.self_device} #{inspect(result)}")
    end

    if a.sync, do: Process.unlink(a.sync) && Process.exit(a.sync, :kill)

    if a.transport && Process.alive?(a.transport) do
      Process.unlink(a.transport)

      try do
        Transport.close(a.transport)
      catch
        :exit, _ -> :ok
      end
    end

    for {_name, ref} <- a.timers, do: SystemsClock.cancel_timer(ref)
    if a.knock_timer, do: SystemsClock.cancel_timer(a.knock_timer)

    put_attempt(state,
      task: nil,
      prereq_task: nil,
      gated_task: nil,
      transport: nil,
      sync: nil,
      timers: %{},
      knock_timer: nil,
      phase: :left
    )
  end

  defp schedule(state, name, ms, key \\ nil) do
    ref = SystemsClock.send_after(self(), {:timer, state.attempt.id, name}, ms)

    if key do
      put_attempt(state, [{key, ref}])
    else
      put_attempt(state, timers: Map.put(state.attempt.timers, name, ref))
    end
  end

  defp new_attempt(task, step) do
    %{
      id: make_ref(),
      task: task,
      step: step,
      phase: :bootstrap,
      native: nil,
      dcrpc_request_id: nil,
      transport: nil,
      sync: nil,
      client: nil,
      msid: nil,
      compass: nil,
      self_device: nil,
      self_state: nil,
      ending: nil,
      registered_at: nil,
      collections_open?: false,
      captions_sent?: false,
      captions_opened?: false,
      prereq_task: nil,
      gated_task: nil,
      knock_timer: nil,
      timers: %{},
      chat_seq: 0,
      reaction_seq: 0,
      caption_req: 0,
      ms_seq: 2,
      ms_generation: 0,
      md_seq: 0,
      dcrpc_seq: 0,
      dcrpc_cycle: 0,
      dcrpc_pending: %{},
      dcrpc_counters: %{}
    }
  end

  defp put_attempt(%{attempt: a} = state, kv), do: %{state | attempt: Enum.into(kv, a)}

  defp status(state, status) do
    Logger.info("meet native: #{inspect(status)}")
    send(state.subscriber, {:meet_native, self(), {:status, status}})
  end

  defp roster_view(roster),
    do: roster |> Enum.map(&{&1["device"], &1["name"], &1["state"]}) |> Enum.sort()

  defp self_status(js) when is_atom(js) do
    case Events.join_state(js) do
      "state" <> _ -> nil
      st -> st
    end
  end

  defp self_status(_js), do: nil

  defp snippet(body), do: binary_part(body, 0, min(byte_size(body), 200))
  defp now, do: SystemsClock.monotonic_time(:millisecond)
end
