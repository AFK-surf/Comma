defmodule SalixVoice.Preview do
  @moduledoc """
  A short spoken sample of a call voice, for Settings › Voice
  (docs/messaging-voice.md#call-preferences).

  GPT-Live offers no preview of a voice: its preset and prompt-made voices
  speak only in a session, and the Text to Speech API does not take them. So
  each sample is a short session of its own, made when asked for and kept by
  the client that asked (the server keeps none): the model
  (`SalixVoice.Model.impl/0`) starts with the voice, hears silence at real
  time (its timeline moves only on input audio), is told to say one fixed
  sentence, and its audio (PCM16 24 kHz) is kept until it has been quiet for
  `quiet_ms` after speaking, the session closes, or `max_ms` passes; asked to
  close, the model gets `close_ms`, then it is killed. The answer is that
  audio as a WAV file.

  A task of `SalixVoice.TaskSupervisor` owns the session to its end, so a
  caller that goes away does not leave the model running. A custom voice's
  sample is admitted as a call is and billed to its Group (source key
  `voice:preview:<id>`); the preset and platform voices' are the platform's.

  Bounds: one model session per sample, at most 15 s of audio, `max_ms` and
  `close_ms` of waiting. How often a Group may ask is the caller's to bound
  (`Salix.Control.VoiceNumbers`).
  """

  require SystemsRuntime.Proc

  alias SalixVoice.{Model, Profile, Settings}

  @model_setting_fields ~w(gpt_live_url gpt_live_model gpt_live_voice openai_api_key)
  @sample_rate 24_000
  # 15 s of PCM16 mono at 24 kHz.
  @max_audio_bytes 15 * @sample_rate * 2
  @input_frame_ms 20
  @silence :binary.copy(<<0, 0>>, div(@sample_rate * @input_frame_ms, 1000))
  # GPT-Live's adapter gives the service 5 s to close before it stops.
  @timers [quiet_ms: 1_500, max_ms: 20_000, close_ms: 6_000]

  @instructions "This is a preview of your voice on a settings page, not a call: nobody " <>
                  "is listening live and nobody will answer. Speak only when told to, say " <>
                  "only what you are told to, and never ask a question."

  @lines %{
    "en" => "Hello, I'm Comma, and this is how I sound on calls.",
    "zh" => "你好，我是 Comma，这是我在通话里的声音。"
  }

  @type error :: :disabled | :not_configured | :draining | :node_full | :unavailable | map()

  @doc """
  A WAV sample of `voice` (`SalixVoice.Voices.session_voice/1`: a preset
  name, `%{"id" => id}`, or nil for the platform voice) speaking `language`
  (a language code `SalixVoice.Profile` knows; English otherwise).

  Options: `:group_id`, the Group a custom voice's sample is billed to; and
  `:admit`, run before the session starts (a rate limit), answering `:ok` or
  an error. A billing refusal is `SalixAgent.BillingAvailability.error/1`'s
  map.
  """
  @spec sample(String.t() | map() | nil, String.t() | nil, keyword()) ::
          {:ok, binary()} | {:error, term()}
  def sample(voice, language, opts \\ []) do
    language = if Profile.language?(language), do: language, else: "en"
    group_id = opts[:group_id]

    with {:ok, settings} <- settings(),
         :ok <- (opts[:admit] || fn -> :ok end).(),
         :ok <- SalixVoice.readiness(),
         :ok <- authorize(group_id, settings) do
      make(voice, language, settings, group_id)
    end
  end

  # A custom voice's sample is its Group's, admitted as a call is.
  defp authorize(nil, _settings), do: :ok

  defp authorize(group_id, settings),
    do: SalixVoice.authorize(%{group_id: group_id, sku: settings["gpt_live_model"]})

  # Starts the task that makes the sample and waits for it as long as a
  # making can take. The task, not the caller, owns the model to its end.
  defp make(voice, language, settings, group_id) do
    caller = SystemsRuntime.Proc.self()
    ref = SystemsRuntime.Proc.make_ref()
    timers = timers()

    {:ok, task} =
      SystemsRuntime.TaskSupervisor.start_child(SalixVoice.TaskSupervisor, fn ->
        result =
          with {:ok, wav, seconds} <- run(voice, language, settings) do
            if group_id, do: meter(group_id, settings, seconds)
            {:ok, wav}
          end

        SystemsRuntime.Proc.send(caller, {:preview_made, ref, result})
      end)

    monitor = SystemsRuntime.Proc.monitor(task)

    SystemsRuntime.Proc.receive do
      {:preview_made, ^ref, result} ->
        SystemsRuntime.Proc.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, :unavailable}
    after
      timers[:max_ms] + timers[:close_ms] * 2 ->
        SystemsRuntime.Proc.demonitor(monitor, [:flush])
        {:error, :unavailable}
    end
  end

  defp run(voice, language, settings) do
    mod = Model.impl()
    ref = SystemsRuntime.Proc.make_ref()

    opts = %{
      owner: SystemsRuntime.Proc.self(),
      ref: ref,
      audio_format: :pcm16_24k,
      instructions: @instructions,
      settings: Map.take(settings, @model_setting_fields),
      voice: voice,
      # As a call's greeting (`SalixVoice.CallActor`): given at startup and
      # again as commentary once the session has started.
      input: [%{"role" => "developer", "text" => speak(language)}]
    }

    case safe_start(mod, opts) do
      {:ok, pid} ->
        # The model must not take the caller down with it, nor the other way round.
        SystemsRuntime.Proc.unlink(pid)
        monitor = SystemsRuntime.Proc.monitor(pid)
        timers = timers()

        deadline =
          SystemsClock.send_after(
            SystemsRuntime.Proc.self(),
            {:preview_max, ref},
            timers[:max_ms]
          )

        state = %{
          mod: mod,
          pid: pid,
          ref: ref,
          monitor: monitor,
          language: language,
          quiet_ms: timers[:quiet_ms],
          close_ms: timers[:close_ms],
          quiet: nil,
          quiet_timer: nil,
          input_timer: nil,
          audio: [],
          bytes: 0,
          usage: nil,
          closed: nil
        }

        started = SystemsClock.monotonic_time()
        state = collect(state)
        seconds = model_seconds(state, SystemsClock.monotonic_time() - started)
        SystemsClock.cancel_timer(deadline)
        SystemsClock.cancel_timer(state.quiet_timer)
        SystemsClock.cancel_timer(state.input_timer)
        SystemsRuntime.Proc.demonitor(monitor, [:flush])
        flush(ref)

        if state.bytes > 0,
          do: {:ok, wav(IO.iodata_to_binary(Enum.reverse(state.audio))), seconds},
          else: {:error, :unavailable}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp collect(%{ref: ref, monitor: monitor, quiet: quiet} = state) do
    SystemsRuntime.Proc.receive do
      {:voice_model, ^ref, {:started, _session_id}} ->
        state.mod.append(state.pid, :commentary, nil, speak(state.language))
        state |> input() |> collect()

      {:preview_input, ^ref} ->
        state |> input() |> collect()

      {:voice_model, ^ref, {:audio, audio}} when is_binary(audio) ->
        state |> keep(audio) |> quiet_again() |> next()

      {:voice_model, ^ref, {:closed, reason, usage}} ->
        close(%{state | usage: usage, closed: reason})

      {:voice_model, ^ref, {:error, _error}} ->
        close(state)

      {:voice_model, ^ref, _event} ->
        collect(state)

      {:preview_quiet, ^ref, ^quiet} ->
        close(state)

      {:preview_quiet, ^ref, _stale} ->
        collect(state)

      {:preview_max, ^ref} ->
        close(state)

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        state
    end
  end

  # A sample that reached its size ends there.
  defp next(%{bytes: bytes} = state) when bytes >= @max_audio_bytes, do: close(state)
  defp next(state), do: collect(state)

  defp keep(state, audio) do
    room = @max_audio_bytes - state.bytes
    audio = if byte_size(audio) > room, do: binary_part(audio, 0, room), else: audio
    %{state | audio: [audio | state.audio], bytes: state.bytes + byte_size(audio)}
  end

  # GPT-Live's timeline moves only while input audio comes, so nothing is
  # said to a session that hears nothing: like a call's carrier, a sample
  # sends a frame of silence every #{@input_frame_ms} ms, at real time,
  # from the start until it closes.
  # https://developers.openai.com/api/docs/guides/live-conversations#greet-before-the-caller-speaks
  defp input(state) do
    state.mod.send_audio(state.pid, @silence)

    timer =
      SystemsClock.send_after(
        SystemsRuntime.Proc.self(),
        {:preview_input, state.ref},
        @input_frame_ms
      )

    %{state | input_timer: timer}
  end

  # Each timer carries its own reference, so one that fires after a newer one
  # started is told apart.
  defp quiet_again(state) do
    SystemsClock.cancel_timer(state.quiet_timer)
    tag = SystemsRuntime.Proc.make_ref()

    timer =
      SystemsClock.send_after(
        SystemsRuntime.Proc.self(),
        {:preview_quiet, state.ref, tag},
        state.quiet_ms
      )

    %{state | quiet: tag, quiet_timer: timer}
  end

  # Asks the model to close and waits until its process is gone, taking the
  # usage it reports on the way. One that has not ended `close_ms` later is
  # killed: the sample is billed and its room given back only after this.
  defp close(state) do
    SystemsClock.cancel_timer(state.input_timer)
    state = %{state | input_timer: nil}
    state.mod.close(state.pid)

    timer =
      SystemsClock.send_after(
        SystemsRuntime.Proc.self(),
        {:preview_close, state.ref},
        state.close_ms
      )

    state = await_end(state)
    SystemsClock.cancel_timer(timer)
    state
  end

  defp await_end(%{ref: ref, monitor: monitor} = state) do
    SystemsRuntime.Proc.receive do
      # The first close is the session's; one answering the close asked for
      # after it adds nothing.
      {:voice_model, ^ref, {:closed, reason, usage}} ->
        await_end(if state.closed, do: state, else: %{state | usage: usage, closed: reason})

      {:preview_close, ^ref} ->
        SystemsRuntime.Proc.exit(state.pid, :kill)
        await_end(state)

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        state
    end
  end

  defp flush(ref) do
    SystemsRuntime.Proc.receive do
      {:voice_model, ^ref, _event} -> flush(ref)
      {:preview_quiet, ^ref, _timer} -> flush(ref)
      {:preview_input, ^ref} -> flush(ref)
      {:preview_max, ^ref} -> flush(ref)
      {:preview_close, ^ref} -> flush(ref)
    after
      0 -> :ok
    end
  end

  # The model seconds GPT-Live reports when the session closes, else the time
  # it was open. After a lost connection the report is only its last
  # snapshot, so the time open is the floor, as for a call.
  defp model_seconds(state, elapsed) do
    elapsed_seconds =
      div(System.convert_time_unit(max(elapsed, 0), :native, :millisecond) + 999, 1000)

    case state.usage do
      %{"seconds" => seconds} when is_number(seconds) and seconds >= 0 ->
        if state.closed == "connection_lost",
          do: max(ceil(seconds), elapsed_seconds),
          else: ceil(seconds)

      _ ->
        elapsed_seconds
    end
  end

  defp meter(group_id, settings, seconds) do
    id = SalixVoice.new_call_id()

    SalixVoice.charge(
      group_id,
      %{
        source_key: "voice:preview:" <> id,
        call_id: id,
        group_id: group_id,
        carrier: "preview",
        provider: "openai",
        sku: settings["gpt_live_model"],
        components: [%{component: :model_seconds, meter_unit: :second, quantity: seconds}],
        metered_at: SystemsClock.utc_now()
      },
      "preview=#{id}"
    )
  end

  # The same words for every voice, so samples compare: as written in the
  # languages of Comma's settings, translated from the English in others.
  defp speak(language) do
    case @lines[language] do
      nil ->
        "Say now, in #{Profile.language_name(language)}, only this sentence, translated and " <>
          "nothing else: \"#{@lines["en"]}\" Then stop."

      line ->
        "Say now exactly these words, as written and nothing else: \"#{line}\" Then stop."
    end
  end

  defp wav(pcm) do
    size = byte_size(pcm)

    <<"RIFF", size + 36::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      @sample_rate::little-32, @sample_rate * 2::little-32, 2::little-16, 16::little-16, "data",
      size::little-32, pcm::binary>>
  end

  defp safe_start(mod, opts) do
    mod.start_link(opts)
  catch
    :exit, reason -> {:error, reason}
  end

  defp settings do
    case Settings.get() do
      {:ok, settings} -> {:ok, settings}
      {:error, _reason} -> {:error, :not_configured}
    end
  end

  defp timers,
    do: Keyword.merge(@timers, SystemsRuntime.get_env(:salix_voice, :preview_timers, []))
end
