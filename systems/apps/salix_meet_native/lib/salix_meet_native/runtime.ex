defmodule SalixMeetNative.Runtime do
  @moduledoc false
  use GenServer, restart: :temporary, shutdown: 20_000

  require Logger

  alias SalixMeetNative.Events.Event
  alias SalixMeetNative.{CodeClaim, Session, Transcript}

  @empty_grace_ms 45_000
  @alone_timeout_ms 600_000
  @caption_batch_max 20
  @caption_batch_ms 2_000
  @callback_timeout_ms 180_000
  @artifact_callback_timeout_ms 450_000
  @backoff_start_ms 500
  @backoff_double_below_ms 30_000

  @stop_reasons ~w(admission_denied meeting_full removed_from_meeting admission_timeout)a
  @stop_messages %{
    admission_denied: "admission_denied: meeting admission was denied",
    meeting_full: "meeting_full: meeting admission was denied because the meeting is full",
    removed_from_meeting: "removed_from_meeting: bot was removed from the meeting",
    admission_timeout: "admission_timeout: no admit within 10m0s"
  }

  @caption_langs ~w(cmn-Hans-CN cmn-Hant-TW de-DE en en-GB en-US es-ES es-MX fr-FR ja ja-JP ko ko-KR ru-RU zh zh-Hant zh-TW)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def send_chat(pid, text, message_id),
    do: SystemsClock.call(pid, {:send_chat, text, message_id}, 15_000)

  def leave(pid) do
    SystemsClock.call(pid, :leave, 15_000)
  catch
    :exit, _ -> :ok
  end

  @spec caption_language(String.t() | nil) :: String.t()
  def caption_language(lang) do
    case String.trim(lang || "") do
      "English" ->
        "en-US"

      "Chinese, Mandarin (Simplified)" ->
        "cmn-Hans-CN"

      code ->
        if Regex.match?(~r/^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$/, code), do: code, else: "en-US"
    end
  end

  @impl true
  def init(opts) do
    case Keyword.get(opts, :code_name) do
      {:global, key} ->
        case CodeClaim.claim(key, self()) do
          {:ok, claim} -> start(Keyword.put(opts, :code_claim, claim))
          {:taken, owner} -> {:stop, {:already_started, owner}}
        end

      _ ->
        start(opts)
    end
  end

  defp start(opts) do
    Process.flag(:trap_exit, true)
    request = Keyword.fetch!(opts, :request)
    meeting_id = Map.fetch!(request, "meeting_id")
    lang = caption_language(request["caption_language"])

    base_session_opts =
      [
        url: request["meet_url"],
        subscriber: self(),
        guest_name: blank_or(request["bot_name"], "Cirno"),
        captions: [{lang, lang}]
      ] ++ Keyword.take(opts, [:recording_dir])

    session_opts = base_session_opts ++ Keyword.get(opts, :session, [])

    session_module = Keyword.get(opts, :session_module, Session)
    {:ok, session} = session_module.start_link(session_opts)

    state = %{
      meeting_id: meeting_id,
      name: Keyword.get(opts, :name),
      code_claim: Keyword.get(opts, :code_claim),
      on_finished: Keyword.get(opts, :on_finished, fn -> :ok end),
      deliver: Keyword.fetch!(opts, :deliver),
      session_module: session_module,
      empty_grace_ms: Keyword.get(opts, :empty_grace_ms, @empty_grace_ms),
      alone_timeout_ms: Keyword.get(opts, :alone_timeout_ms, @alone_timeout_ms),
      recording_dir: Keyword.get(opts, :recording_dir),
      session: session,
      base_session_opts: base_session_opts,
      fallback: Keyword.get(opts, :fallback),
      self_device: nil,
      ever_joined?: false,
      draining?: false,
      reported_self: nil,
      names: %{},
      roster: [],
      captions: [],
      seen_chat: MapSet.new(),
      grace: nil,
      recording: nil,
      leave_waiters: [],
      finished?: false,
      queue: :queue.new(),
      batch_seq: 0,
      sending: nil,
      sending_pid: nil,
      retry: nil,
      guest_noticed?: false,
      closed?: false
    }

    {:ok, if(Keyword.get(opts, :guest_fallback), do: guest_notice(state), else: state)}
  end

  @impl true
  def handle_call({:send_chat, text, message_id}, _from, %{finished?: false} = state),
    do:
      {:reply, safe(fn -> state.session_module.send_chat(state.session, text, message_id) end),
       state}

  def handle_call({:send_chat, _text, _message_id}, _from, state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call(:leave, from, %{finished?: false} = state) do
    request_leave(state)
    {:noreply, %{state | leave_waiters: [from | state.leave_waiters]}}
  end

  def handle_call(:leave, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:meet_native, session, msg}, %{session: session} = state),
    do: {:noreply, session_msg(state, msg)}

  def handle_info({:meet_asr, caption}, %{finished?: false} = state),
    do: {:noreply, enqueue_caption(%{state | captions: state.captions ++ [caption]}, caption)}

  def handle_info({:EXIT, session, reason}, %{session: session, finished?: false} = state)
      when reason != :normal,
      do: {:noreply, finish(state, {:error, {:runtime_crashed, reason}})}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:drain, %{finished?: false} = state) do
    request_leave(state)
    {:noreply, %{state | draining?: true}}
  end

  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info(:grace, state) do
    state = %{state | grace: nil}
    if online_others(state) == 0, do: request_leave(state)
    {:noreply, state}
  end

  def handle_info(:flush, %{retry: {:flush, _}} = state),
    do: {:noreply, pump(%{state | retry: nil})}

  def handle_info(:flush, state), do: {:noreply, state}

  def handle_info({:retry_item, item, attempt, deadline}, state),
    do: {:noreply, start_send(%{state | retry: nil}, item, attempt, deadline)}

  def handle_info(:stop_after_drain, %{closed?: true, sending: nil, retry: nil} = state) do
    if :queue.is_empty(state.queue), do: {:stop, :normal, state}, else: {:noreply, pump(state)}
  end

  def handle_info(:stop_after_drain, state), do: {:noreply, state}

  def handle_info({ref, result}, %{sending: {ref, item, attempt, deadline}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     delivered(%{state | sending: nil, sending_pid: nil}, item, attempt, deadline, result)}
  end

  def handle_info({:deliver_timeout, ref}, %{sending: {ref, item, attempt, deadline}} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(state.sending_pid, :kill)

    {:noreply,
     delivered(
       %{state | sending: nil, sending_pid: nil},
       item,
       attempt,
       deadline,
       {:error, :timeout}
     )}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{sending: {ref, item, attempt, deadline}} = state
      ),
      do:
        {:noreply,
         delivered(
           %{state | sending: nil, sending_pid: nil},
           item,
           attempt,
           deadline,
           {:error, {:deliver_crashed, reason}}
         )}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.session) and Process.alive?(state.session),
      do: safe(fn -> state.session_module.leave(state.session) end)

    if state.recording_dir, do: File.rm_rf(state.recording_dir)
    :ok
  end

  defp session_msg(state, {:event, %Event{} = event}) do
    state
    |> learn_name(event)
    |> observe(event)
    |> record_caption(event)
    |> forward_chat(event)
  end

  defp session_msg(state, {:status, %{self: st}}) when st in ["knocking", "joined"] do
    status = if st == "joined", do: "in_meeting", else: "waiting_room"

    if state.reported_self == status do
      state
    else
      joiner =
        if status == "in_meeting",
          do: %{"type" => "status", "status" => status, "timestamp" => now_s()},
          else: %{"type" => "status", "status" => status}

      state = %{
        state
        | reported_self: status,
          ever_joined?: state.ever_joined? or status == "in_meeting"
      }

      state
      |> enqueue_joiner(joiner)
      |> start_alone_timer()
    end
  end

  defp session_msg(state, {:status, {:self_device, device}}), do: %{state | self_device: device}
  defp session_msg(state, {:status, :guest_fallback}), do: guest_notice(state)
  defp session_msg(state, {:recording, files}), do: %{state | recording: files}
  defp session_msg(state, {:roster, roster}), do: %{state | roster: roster}
  defp session_msg(state, {:ended, :left}), do: finish(state, :ok)

  defp session_msg(
         %{fallback: {module, opts}, ever_joined?: false, finished?: false, draining?: false} =
           state,
         {:ended, reason}
       ) do
    if login_failure?(reason),
      do: start_fallback(state, module, opts),
      else: session_msg(%{state | fallback: nil}, {:ended, reason})
  end

  defp session_msg(state, {:ended, reason}) when reason in @stop_reasons,
    do: finish(state, {:stop, reason})

  defp session_msg(state, {:ended, reason}), do: finish(state, {:error, reason})
  defp session_msg(state, _msg), do: state

  # The account cannot sign in: the master-token-factory has no ready account for the
  # profile, or Google rejects the ya29 it signed.
  defp login_failure?({:native, {:token_factory_status, status}}), do: status in [401, 404]
  defp login_failure?({:native, {:resolve, 401, _body}}), do: true
  defp login_failure?(_reason), do: false

  # The native session already stopped; join once as a guest instead.
  defp start_fallback(state, module, opts) do
    Logger.warning("meet native: Google account cannot sign in, joining as a guest")
    {:ok, session} = module.start_link(state.base_session_opts ++ opts)

    %{state | session: session, session_module: module, fallback: nil, recording: nil}
    |> guest_notice()
  end

  defp learn_name(state, %Event{type: "participant", payload: %{"device" => dev, "name" => name}})
       when name != "",
       do: %{state | names: Map.put(state.names, dev, name)}

  defp learn_name(state, _event), do: state

  defp observe(state, %Event{type: "participant", payload: %{"device" => dev} = payload}) do
    cond do
      dev == state.self_device ->
        state

      payload["state"] == "joined" ->
        stop_grace(state)

      payload["state"] == "left" and online_others(state) == 0 ->
        start_grace(state, state.empty_grace_ms)

      true ->
        state
    end
  end

  defp observe(state, _event), do: state

  defp record_caption(
         state,
         %Event{type: "caption", payload: %{"final" => true} = payload} = event
       ) do
    case payload["text"] do
      text when is_binary(text) and text != "" ->
        caption = %{
          "speaker" => display_name(event, state.names),
          "text" => text,
          "timestamp" => now_s(),
          "timestamp_ms" => SystemsClock.system_time(:millisecond),
          "source" => "captions"
        }

        enqueue_caption(%{state | captions: state.captions ++ [caption]}, caption)

      _ ->
        state
    end
  end

  defp record_caption(state, _event), do: state

  defp forward_chat(state, %Event{type: "chat", payload: payload} = event) do
    id = payload["id"] || ""

    cond do
      payload["device"] not in [nil, ""] and payload["device"] == state.self_device ->
        state

      id != "" and MapSet.member?(state.seen_chat, id) ->
        state

      true ->
        text = payload["text"] || ""

        state =
          if id != "", do: %{state | seen_chat: MapSet.put(state.seen_chat, id)}, else: state

        internal_command(state, text)

        enqueue_joiner(state, %{
          "type" => "chat_message",
          "sender" => display_name(event, state.names),
          "text" => text,
          "timestamp" => now_s()
        })
    end
  end

  defp forward_chat(state, _event), do: state

  defp internal_command(state, text) do
    case text |> String.trim() |> String.split() do
      ["/leave" | _] ->
        request_leave(state)

      ["/listlang" | _] ->
        safe(fn ->
          state.session_module.send_chat(
            state.session,
            "Available caption languages: " <> Enum.join(@caption_langs, ", "),
            nil
          )
        end)

      ["/setlang", spec | _] ->
        {display, spoken} =
          case String.split(spec, ":", parts: 2) do
            [display, spoken] when display != "" -> {display, spoken}
            _ -> {spec, ""}
          end

        display = caption_language(display)
        spoken = if spoken == "", do: display, else: caption_language(spoken)

        safe(fn -> state.session_module.set_caption_lang(state.session, display, spoken) end)

      _ ->
        :ok
    end
  end

  defp finish(%{finished?: true} = state, _outcome), do: state

  defp finish(state, outcome) do
    state = stop_grace(%{state | finished?: true})
    release_name(state.name)
    if state.code_claim, do: safe(fn -> CodeClaim.release(state.code_claim) end)
    safe(state.on_finished)
    reason = reason_code(outcome)

    outcome =
      cond do
        outcome == {:stop, :removed_from_meeting} and state.ever_joined? -> :ok
        # A bot drained before admission failed this join attempt; the join
        # retry can place the Meeting on another node.
        outcome == :ok and state.draining? and not state.ever_joined? -> {:error, :node_draining}
        true -> outcome
      end

    {state, terminal} =
      case outcome do
        :ok when state.ever_joined? ->
          state = enqueue_joiner(state, put_reason(%{"type" => "meeting_ended"}, reason))
          {state, runtime_update(state, "done", nil, artifacts(state))}

        :ok ->
          {state, runtime_update(state, "cancelled", nil, [])}

        error ->
          message = error_message(error, state.guest_noticed?)

          state =
            enqueue_joiner(
              state,
              put_reason(%{"type" => "status", "status" => "error", "message" => message}, reason)
            )

          # Results captured before a failure are still the meeting's record.
          artifacts = if state.ever_joined?, do: artifacts(state), else: []
          {state, runtime_update(state, "failed", message, artifacts)}
      end

    for waiter <- state.leave_waiters, do: GenServer.reply(waiter, :ok)

    %{state | leave_waiters: []}
    |> enqueue({:terminal, put_reason(terminal, reason)})
    |> Map.put(:closed?, true)
    |> pump()
  end

  defp release_name({:global, key}), do: :global.unregister_name(key)
  defp release_name(_name), do: :ok

  defp reason_code({:stop, reason}), do: Atom.to_string(reason)
  defp reason_code({:error, :google_login_required}), do: "google_login_required"

  defp reason_code({:error, {:native, _} = reason}),
    do: if(login_failure?(reason), do: "google_login_required")

  defp reason_code(_outcome), do: nil

  defp error_message({:error, {:token_factory, {:http, _, _, "meet-rejected", _}}}, true),
    do: "This meeting can't be joined as a guest."

  defp error_message(error, _guest?), do: error_message(error)

  defp guest_notice(%{guest_noticed?: true} = state), do: state

  defp guest_notice(state) do
    %{state | guest_noticed?: true}
    |> enqueue_joiner(%{"type" => "status", "status" => "guest_fallback"})
  end

  defp error_message({:stop, reason}), do: @stop_messages[reason]
  defp error_message({:error, :google_login_required}), do: "Google login required (remote)"

  defp error_message({:error, {:token_factory, {:http, _, _, "meet-rejected", _}}}),
    do: "Google Meet refused to let the assistant join."

  defp error_message({:error, {:token_factory, {:token_factory_unreachable, _}}}),
    do: "Could not reach the meeting join service"

  defp error_message({:error, {:token_factory, {:http, _, _, "timeout", _}}}),
    do: "Timed out while opening the meeting"

  defp error_message({:error, {:token_factory, _}}),
    do: "The meeting join service could not open the meeting"

  defp error_message({:error, {:native, reason}}) do
    cond do
      login_failure?({:native, reason}) ->
        "Google login required (remote)"

      match?({:token_factory_unreachable, _}, reason) ->
        "Could not reach the meeting join service"

      match?({:token_factory_status, _}, reason) ->
        "Could not reach the meeting join service"

      true ->
        "The assistant could not open the meeting"
    end
  end

  defp error_message({:error, {:gave_up, _}}),
    do: "Lost the connection to the meeting and could not rejoin"

  defp error_message({:error, reason})
       when is_tuple(reason) and tuple_size(reason) in [2, 3] and
              elem(reason, 0) in [:create_media_session, :device_register, :device],
       do: "Google Meet did not accept the assistant's connection"

  defp error_message({:error, :node_draining}),
    do: "The meeting assistant restarted before it was admitted"

  defp error_message({:error, {:runtime_crashed, _}}),
    do: "The meeting assistant stopped unexpectedly"

  defp error_message({:error, reason}), do: inspect(reason)

  defp put_reason(map, nil), do: map
  defp put_reason(map, reason), do: Map.put(map, "reason_code", reason)

  defp artifacts(state) do
    transcript =
      case Transcript.build(state.captions) do
        "" ->
          []

        text ->
          [
            %{
              "kind" => "transcript",
              "filename" => "transcript.txt",
              "content_type" => "text/plain; charset=utf-8",
              "data_b64" => Base.encode64(text)
            }
          ]
      end

    audio =
      with %{audio: path} when is_binary(path) <- state.recording,
           {:ok, %File.Stat{size: size}} when size > 0 <- File.stat(path) do
        [
          %{
            "kind" => "audio",
            "filename" => "audio.ogg",
            "content_type" => "audio/ogg",
            "src_path" => path
          }
        ]
      else
        _ -> []
      end

    transcript ++ audio
  end

  defp runtime_update(state, status, error, artifacts) do
    %{
      "type" => "meeting_runtime_update",
      "meeting_id" => state.meeting_id,
      "event_id" => "#{state.meeting_id}:runtime:#{status}",
      "status" => status
    }
    |> then(fn u -> if error, do: Map.put(u, "error", error), else: u end)
    |> then(fn u ->
      case artifacts do
        [] ->
          u

        list ->
          u
          |> Map.put("artifacts", list)
          |> then(
            &if(Enum.any?(list, fn a -> a["kind"] == "transcript" end),
              do: Map.put(&1, "transcript_source", "captions"),
              else: &1
            )
          )
      end
    end)
  end

  defp enqueue_joiner(state, joiner) do
    key = joiner["status"] || joiner["type"]

    event_id =
      if joiner["type"] in ["caption", "chat_message", "chat_sent"],
        do:
          "#{state.meeting_id}:#{joiner["type"]}:#{SystemsClock.system_time(:nanosecond)}-#{SystemsRuntime.Proc.unique_integer([:positive, :monotonic])}",
        else: "#{state.meeting_id}:#{key}"

    enqueue(
      state,
      {:event,
       %{
         "type" => "joiner_event",
         "meeting_id" => state.meeting_id,
         "event_id" => event_id,
         "joiner_event" => joiner
       }}
    )
  end

  defp enqueue_caption(%{closed?: true} = state, _caption), do: state

  defp enqueue_caption(state, caption) do
    state = cancel_flush(state)

    case :queue.peek_r(state.queue) do
      {:value, {:captions, id, captions, created}} when length(captions) < @caption_batch_max ->
        queue =
          :queue.in({:captions, id, captions ++ [caption], created}, :queue.drop_r(state.queue))

        pump(%{state | queue: queue})

      _ ->
        seq = state.batch_seq + 1
        item = {:captions, "#{state.meeting_id}:captions:#{seq}", [caption], now_ms()}
        pump(%{state | batch_seq: seq, queue: :queue.in(item, state.queue)})
    end
  end

  defp enqueue(%{closed?: true} = state, _item), do: state

  defp enqueue(state, item),
    do: state |> cancel_flush() |> Map.put(:queue, :queue.in(item, state.queue)) |> pump()

  defp cancel_flush(%{retry: {:flush, ref}} = state) do
    SystemsClock.cancel_timer(ref)
    %{state | retry: nil}
  end

  defp cancel_flush(state), do: state

  defp pump(%{sending: sending} = state) when sending != nil, do: state
  defp pump(%{retry: retry} = state) when retry != nil, do: state

  defp pump(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        if state.closed?, do: send(self(), :stop_after_drain)
        state

      {{:value, {:captions, _id, captions, created} = item}, rest} ->
        wait = @caption_batch_ms - (now_ms() - created)

        if length(captions) < @caption_batch_max and not state.closed? and :queue.is_empty(rest) and
             wait > 0 do
          %{state | retry: {:flush, SystemsClock.send_after(self(), :flush, wait)}}
        else
          start_send(%{state | queue: rest}, item, 1, nil)
        end

      {{:value, item}, rest} ->
        start_send(%{state | queue: rest}, item, 1, nil)
    end
  end

  defp start_send(state, item, attempt, deadline) do
    event = item_event(state, item)

    deadline =
      deadline ||
        now_ms() +
          if(event["artifacts"], do: @artifact_callback_timeout_ms, else: @callback_timeout_ms)

    deliver = state.deliver
    task = Task.async(fn -> deliver.(event) end)
    Process.unlink(task.pid)
    SystemsClock.send_after(self(), {:deliver_timeout, task.ref}, max(deadline - now_ms(), 0))
    %{state | sending: {task.ref, item, attempt, deadline}, sending_pid: task.pid}
  end

  # A recording that cannot be stored must not cost the meeting its terminal
  # status and transcript: retry once without the streamed artifacts.
  defp delivered(state, {:terminal, event} = item, attempt, deadline, {:error, reason} = result) do
    lighter = drop_streamed_artifacts(event)

    if lighter != event and (permanent_artifact_failure?(reason) or deadline - now_ms() <= 0) do
      Logger.warning(
        "meet native runtime: delivering #{event["event_id"]} without its recording #{inspect(reason)}"
      )

      start_send(state, {:terminal, lighter}, 1, nil)
    else
      deliver_result(state, item, attempt, deadline, result)
    end
  end

  defp delivered(state, item, attempt, deadline, result),
    do: deliver_result(state, item, attempt, deadline, result)

  defp permanent_artifact_failure?({:permanent, _reason}), do: true

  defp permanent_artifact_failure?({:artifact_ingest_failed, _kind, reason}),
    do: reason in [:artifact_too_large, :artifact_path_invalid, :enoent]

  defp permanent_artifact_failure?(_reason), do: false

  defp drop_streamed_artifacts(%{"artifacts" => artifacts} = event) do
    case Enum.reject(artifacts, &Map.has_key?(&1, "src_path")) do
      ^artifacts -> event
      [] -> Map.drop(event, ["artifacts", "transcript_source"])
      kept -> Map.put(event, "artifacts", kept)
    end
  end

  defp drop_streamed_artifacts(event), do: event

  defp deliver_result(state, item, attempt, deadline, result) do
    case result do
      :ok ->
        after_item(state, item)

      {:error, {:permanent, reason}} ->
        Logger.warning(
          "meet native runtime: callback rejected #{item_id(state, item)} #{inspect(reason)}"
        )

        after_item(state, item)

      {:error, reason} ->
        remaining = deadline - now_ms()

        if remaining <= 0 do
          Logger.warning(
            "meet native runtime: callback gave up #{item_id(state, item)} #{inspect(reason)}"
          )

          after_item(state, item)
        else
          SystemsClock.send_after(
            self(),
            {:retry_item, item, attempt + 1, deadline},
            min(backoff(attempt), remaining)
          )

          %{state | retry: :waiting}
        end
    end
  end

  defp backoff(attempt) do
    Enum.reduce(2..attempt//1, @backoff_start_ms, fn _, ms ->
      if ms < @backoff_double_below_ms, do: ms * 2, else: ms
    end)
  end

  defp after_item(state, {:terminal, _}) do
    send(self(), :stop_after_drain)
    state
  end

  defp after_item(state, _item), do: pump(state)

  defp item_event(state, {:captions, id, captions, _created}),
    do: %{
      "type" => "meeting_runtime_update",
      "meeting_id" => state.meeting_id,
      "event_id" => id,
      "captions" => captions
    }

  defp item_event(_state, {:event, event}), do: event
  defp item_event(_state, {:terminal, event}), do: event

  defp item_id(state, item), do: item_event(state, item)["event_id"]

  defp request_leave(state) do
    %{session: session, session_module: module} = state
    Task.start(fn -> safe(fn -> module.leave(session) end) end)
    :ok
  end

  defp online_others(state) do
    Enum.count(state.roster, &(&1["state"] == "joined" and &1["device"] != state.self_device))
  end

  defp start_alone_timer(%{reported_self: "in_meeting"} = state) do
    if online_others(state) == 0, do: start_grace(state, state.alone_timeout_ms), else: state
  end

  defp start_alone_timer(state), do: state

  defp start_grace(%{grace: nil} = state, ms),
    do: %{state | grace: SystemsClock.send_after(self(), :grace, ms)}

  defp start_grace(state, _ms), do: state

  defp stop_grace(%{grace: nil} = state), do: state

  defp stop_grace(state) do
    SystemsClock.cancel_timer(state.grace)
    %{state | grace: nil}
  end

  @spec display_name(%Event{}, map()) :: String.t()
  def display_name(%Event{actor: actor, payload: payload}, names) do
    device = payload["device"]

    cond do
      is_binary(device) and device != "" and Map.get(names, device, "") != "" -> names[device]
      actor not in [nil, ""] and Map.get(names, actor, "") != "" -> names[actor]
      actor not in [nil, ""] -> short_actor(actor)
      true -> "?"
    end
  end

  defp short_actor(actor) do
    case actor |> String.split("/") |> Enum.reverse() do
      [last, _ | _] when last != "" -> "…/" <> last
      _ -> actor
    end
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :not_connected}
  end

  defp blank_or(value, fallback) when value in [nil, ""], do: fallback
  defp blank_or(value, _fallback), do: value

  defp now_s, do: SystemsClock.system_time(:second)
  defp now_ms, do: SystemsClock.monotonic_time(:millisecond)
end
