defmodule SalixVoice.CallActorTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixVoice"]

  alias SalixStore.{Keys, S3}
  alias SalixVoice.Model.Fake
  alias SalixVoice.{Settings, TestStubs}

  @pg SalixVoice.PG

  setup do
    S3.delete(Keys.ctl_system_voice())

    {:ok, _} =
      Settings.update(%{
        "enabled" => true,
        "openai_api_key" => "sk-test",
        "max_calls_per_node" => 50
      })

    env = [
      model_mod: Fake,
      fake_model_observer: SystemsRuntime.Proc.self(),
      test_pid: SystemsRuntime.Proc.self(),
      test_admission: :ok,
      ingress_mod: TestStubs.Ingress,
      group_directory_mod: TestStubs.GroupDirectory,
      metering_mod: TestStubs.Metering,
      profile_decider_mod: TestStubs.ProfileDecider,
      test_profile_decision: {:error, "not_configured"},
      preferences_mod: TestStubs.Preferences,
      persona_mod: TestStubs.Persona,
      fake_model_seconds: 42,
      timers: [
        delegation_settle_ms: 20,
        progress_thinking_ms: 5_000,
        progress_apology_ms: 10_000,
        model_close_wait_ms: 300,
        notice_max_ms: 300,
        hangup_max_ms: 400,
        quiet_ms: 100
      ]
    ]

    previous =
      Enum.map(env, fn {key, _} -> {key, SystemsRuntime.fetch_env(:salix_voice, key)} end)

    Enum.each(env, fn {key, value} -> SystemsRuntime.put_env(:salix_voice, key, value) end)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> SystemsRuntime.put_env(:salix_voice, key, value)
          :error -> SystemsRuntime.delete_env(:salix_voice, key)
        end
      end

      for pid <- :pg.get_members(@pg, :calls), do: SystemsRuntime.Proc.exit(pid, :kill)
      # A killed call's ingress task would otherwise report to the next test's
      # :test_pid.
      for pid <- SystemsRuntime.TaskSupervisor.children(SalixVoice.TaskSupervisor),
          do: SystemsRuntime.Proc.exit(pid, :kill)

      S3.delete(Keys.ctl_system_voice())
      SalixCluster.NodeLifecycle.clear_draining()
    end)

    :ok
  end

  defp admit(overrides \\ %{}) do
    Map.merge(
      %{
        carrier: :websocket,
        tenant_id: "ten_1",
        group_id: "grp_" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive])),
        connect_id: "conn_voice",
        caller: %{"kind" => "api_key", "value" => "key_1"},
        carrier_call_id: nil,
        audio_format: :pcmu_8k,
        key_id: "key_1",
        key_name: "Desk phone",
        principal: "api_key:key_1:usr_creator",
        display_name: "Ada"
      },
      overrides
    )
    |> SalixVoice.admit()
  end

  test "insufficient credits refuses admission before a call or model is started" do
    SystemsRuntime.put_env(
      :salix_voice,
      :test_admission,
      {:error,
       {:billing_unavailable,
        struct!(BillingCore.FeeControl.Decision, allowed?: false, reason: "insufficient_credits")}}
    )

    group = "grp_credit_denied"

    assert {:error,
            %{
              "error_class" => "billing_unavailable",
              "reason" => "insufficient_credits",
              "retryable" => false
            }} = admit(%{group_id: group})

    refute SalixVoice.group_busy?(group)
    settle_refute_receive({:fake_model, _, {:started, _}}, 20)
    SystemsRuntime.put_env(:salix_voice, :test_admission, :ok)
    assert {:ok, %{call_id: call}} = admit(%{group_id: group})
    assert SystemsRuntime.Proc.is_process(SalixVoice.whereis(call))
  end

  test "logs the model session id once per call" do
    {:ok, %{call_id: call_id}} = admit(%{})
    {:ok, call, _info} = SalixVoice.attach(call_id, SystemsRuntime.Proc.self())
    settle_receive({:fake_model, model, {:started, _}})

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        emit(model, call, {:started, "sess_log"})
        emit(model, call, {:started, "sess_log"})
      end)

    assert [_] = Regex.scan(~r/voice model started call=#{call_id} session="sess_log"/, log)
  end

  # Admit and attach the test process as the carrier socket; returns the call
  # pid, its info and the fake model pid.
  defp live_call(overrides \\ %{}, opts \\ []) do
    {:ok, %{call_id: call_id, token: token}} = admit(overrides)

    {:ok, call, info} =
      if token,
        do:
          SalixVoice.attach(token, SystemsRuntime.Proc.self(),
            carrier_call_id: overrides[:carrier_call_id]
          ),
        else: SalixVoice.attach(call_id, SystemsRuntime.Proc.self())

    watch(call)
    settle_receive({:fake_model, model, {:started, model_opts}})
    assert model_opts.audio_format == info.audio_format

    if Keyword.get(opts, :start_model, true) do
      emit(model, call, {:started, "sess_1"})
      settle_receive({:fake_model, ^model, {:append, :instructions, nil, _greeting}})
      settle_receive({:ingress, _, _, %{"event_type" => "voice.call_started"}, _, _})
    end

    {call, info, model}
  end

  # Deliver a model event and wait until the call has handled it.
  defp emit(model, call, event) do
    Fake.emit(model, event)
    _ = :sys.get_state(model, :infinity)
    _ = :sys.get_state(call, :infinity)
    :ok
  end

  defp request(info, extra) do
    Map.merge(
      %{
        "group_id" => info.group_id,
        "connect_id" => info.connect_id,
        "agent_id" => "agt_router",
        "delegation_id" => nil,
        "text" => nil
      },
      extra
    )
  end

  defp provider(call, op, info, extra),
    do: GenServer.call(call, {:voice_provider, op, request(info, extra)}, :infinity)

  # Monitor a call before anything can end it: a monitor taken once the end is
  # under way finds a call that already stopped and reports `:noproc`, never
  # the `:normal` exit `await_end/2` waits for. A monitor is a signal, and a
  # message another process sends the call later may reach it first; the call
  # answers the test only once it holds the test's earlier monitor.
  defp watch(call) do
    Process.put({:watch, call}, SystemsRuntime.Proc.monitor(call))
    _ = :sys.get_state(call, :infinity)
    call
  end

  defp await_end(call, reason) do
    settle_receive({:voice_call, :end, ^reason})
    await_down(call)
  end

  defp await_down(call) do
    ref = Process.get({:watch, call}) || flunk("watch/1 the call before it can end")
    settle_receive({:DOWN, ^ref, :process, ^call, :normal})
  end

  for first <- [:model, :carrier] do
    @tag :voice_greeting
    test "greets a silent caller once when #{first} is ready first" do
      {:ok, %{call_id: id}} = admit(%{carrier: :signal, key_id: nil})
      [call] = :pg.get_members(@pg, {:call, id})
      settle_receive({:fake_model, model, {:started, _}})

      case unquote(first) do
        :model ->
          emit(model, call, {:started, "greeting-session"})
          settle_refute_receive({:fake_model, ^model, {:append, _, _, _}}, 50)
          assert {:ok, ^call, _} = SalixVoice.attach(id, SystemsRuntime.Proc.self())

        :carrier ->
          assert {:ok, ^call, _} = SalixVoice.attach(id, SystemsRuntime.Proc.self())
          settle_refute_receive({:fake_model, ^model, {:append, _, _, _}}, 50)
          emit(model, call, {:started, "greeting-session"})
      end

      settle_receive({:fake_model, ^model, {:append, :instructions, nil, greeting}})
      assert is_binary(greeting) and byte_size(greeting) > 0
      refute_received {:fake_model, ^model, {:audio, _}}
      emit(model, call, {:audio, <<1, 2, 3>>})
      settle_receive({:voice_call, :audio, <<1, 2, 3>>})

      emit(model, call, {:started, "greeting-session"})
      assert {:error, :already_attached} = SalixVoice.attach(id, SystemsRuntime.Proc.self())
      settle_refute_receive({:fake_model, ^model, {:append, _, _, _}}, 50)
    end
  end

  defp answer(choice, probability_bp),
    do: %{"choice" => choice, "probabilities_bp" => %{choice => probability_bp}}

  defp put_timer(name, ms) do
    timers = SystemsRuntime.fetch_env!(:salix_voice, :timers)
    SystemsRuntime.put_env(:salix_voice, :timers, Keyword.put(timers, name, ms))
  end

  test "confident profile fields reach the model instructions and the greeting" do
    SystemsRuntime.put_env(
      :salix_voice,
      :test_profile_decision,
      {:ok,
       %{
         "answers" => %{
           "language" => answer("es", 9_000),
           "small_talk" => answer("skip", 9_000),
           "units" => answer("metric", 6_000),
           "formality" => answer("unknown", 9_500),
           "reply_length" => answer("short", 9_000)
         }
       }}
    )

    {:ok, %{call_id: id}} = admit(%{carrier: :signal, key_id: nil})
    [call] = :pg.get_members(@pg, {:call, id})

    settle_receive({:profile_decide, _group_id, questions, opts})
    assert opts[:entrypoint] == "voice_profile"
    assert is_integer(opts[:admission_deadline])
    assert Map.has_key?(questions, "language")

    settle_receive({:fake_model, model, {:started, model_opts}})
    base = SalixVoice.CallActor.instructions()
    assert String.starts_with?(model_opts.instructions, base <> "\n\n")
    profile = String.replace_prefix(model_opts.instructions, base, "")

    # Above-threshold choices render; a low probability, unknown, or an
    # option that matches the base instructions adds nothing.
    assert profile =~ "Spanish"
    assert profile =~ "small talk"
    refute profile =~ "metric"
    refute profile =~ "tone"
    assert length(String.split(String.trim(profile), "\n- ")) == 3

    assert {:ok, ^call, _} = SalixVoice.attach(id, SystemsRuntime.Proc.self())
    emit(model, call, {:started, "profile-session"})
    settle_receive({:fake_model, ^model, {:append, :instructions, nil, greeting}})
    assert greeting =~ "Spanish"
  end

  test "a slow profile gives way to the base instructions at its deadline" do
    put_timer(:profile_ms, 100)

    SystemsRuntime.put_env(
      :salix_voice,
      :test_profile_decision,
      {:sleep, 2_000, {:ok, %{"answers" => %{}}}}
    )

    {:ok, %{call_id: id}} = admit(%{carrier: :signal, key_id: nil})
    [call] = :pg.get_members(@pg, {:call, id})
    settle_refute_receive({:fake_model, _, {:started, _}}, 50)

    settle_receive({:fake_model, model, {:started, model_opts}})
    assert model_opts.instructions == SalixVoice.CallActor.instructions()

    assert {:ok, ^call, _} = SalixVoice.attach(id, SystemsRuntime.Proc.self())
    emit(model, call, {:started, "late-profile-session"})
    settle_receive({:fake_model, ^model, {:append, :instructions, nil, greeting}})
    assert greeting =~ "English"
  end

  test "credits exhausted after admission stop the call before model startup" do
    put_timer(:profile_ms, 1_000)

    SystemsRuntime.put_env(
      :salix_voice,
      :test_profile_decision,
      {:sleep, 200, {:ok, %{"answers" => %{}}}}
    )

    {:ok, %{call_id: id}} = admit(%{carrier: :signal, key_id: nil})
    call = id |> SalixVoice.whereis() |> watch()
    assert {:ok, ^call, _} = SalixVoice.attach(id, SystemsRuntime.Proc.self())
    settle_receive({:profile_decide, _, _, _})

    SystemsRuntime.put_env(
      :salix_voice,
      :test_admission,
      {:error,
       {:billing_unavailable,
        struct!(BillingCore.FeeControl.Decision, allowed?: false, reason: "insufficient_credits")}}
    )

    await_end(call, :billing_unavailable)
    settle_refute_receive({:fake_model, _, {:started, _}}, 20)
  end

  test "a call that ends while its profile is pending never starts the model" do
    put_timer(:profile_ms, 5_000)

    SystemsRuntime.put_env(
      :salix_voice,
      :test_profile_decision,
      {:sleep, 2_000, {:ok, %{"answers" => %{}}}}
    )

    {:ok, %{call_id: id}} = admit(%{carrier: :signal, key_id: nil})
    [call] = :pg.get_members(@pg, {:call, id})
    watch(call)
    assert {:ok, ^call, _} = SalixVoice.attach(id, SystemsRuntime.Proc.self())
    settle_receive({:profile_decide, _, _, _})

    SystemsRuntime.Proc.send(call, {:voice_carrier, :hangup, :normal})
    await_end(call, :caller_hangup)
    settle_refute_receive({:fake_model, _, {:started, _}}, 100)
  end

  test "the Router gets one call-start input when the call is ready, and can speak first" do
    {:ok, %{call_id: id}} = admit(%{carrier: :signal, key_id: nil})
    [call] = :pg.get_members(@pg, {:call, id})
    settle_receive({:fake_model, model, {:started, _}})
    assert {:ok, ^call, info} = SalixVoice.attach(id, SystemsRuntime.Proc.self())
    settle_refute_receive({:ingress, _, _, _, _, _}, 50)

    emit(model, call, {:started, "sess_start"})

    settle_receive({:ingress, group_id, content, metadata, source_id, opts})
    assert group_id == info.group_id
    assert source_id == "im_provider:voice:conn_voice:#{id}:start"
    assert opts[:session_name] == "Voice call"
    refute Keyword.has_key?(opts, :trusted_source_text)
    assert content =~ "The caller just connected"
    assert content =~ "im_api.voice.say (call_id #{id})"

    assert %{
             "provider" => "voice",
             "connect_id" => "conn_voice",
             "chat_id" => ^id,
             "chat_type" => "private",
             "from_user_id" => "key_1",
             "event_type" => "voice.call_started",
             "event_id" => ^id,
             "source_actor_type" => "provider_user"
           } = metadata

    # No message_id: a reply to this input names no delegation.
    refute Map.has_key?(metadata, "message_id")

    # A repeated model start neither greets nor announces the call again.
    emit(model, call, {:started, "sess_start"})
    settle_refute_receive({:ingress, _, _, _, _, _}, 50)

    assert {:ok, %{"delivered" => true, "delegation_id" => nil}} =
             provider(call, :say, info, %{"text" => "Your build finished."})

    settle_receive({:fake_model, ^model, {:append, :commentary, nil, "Your build finished."}})
  end

  test "the Router gets one call-end input with the reason and unanswered requests" do
    {call, info, model} = live_call()
    emit(model, call, {:delegation, "dlg_open", 500})
    settle_receive({:ingress, _, _, %{"event_type" => "voice.delegation"}, _, _})

    SystemsRuntime.Proc.send(call, {:voice_carrier, :hangup, :normal})
    await_end(call, :caller_hangup)

    settle_receive({:ingress, group_id, content, metadata, source_id, opts})
    assert group_id == info.group_id
    assert source_id == "im_provider:voice:conn_voice:#{info.call_id}:end"
    assert opts[:session_name] == "Voice call"
    assert content =~ "the caller hung up (reason caller_hangup)"
    assert content =~ "One caller request was still unanswered."
    # Only a call that speaks as the Router hands over what was said.
    refute content =~ "What was said"

    assert %{"event_type" => "voice.call_ended", "chat_id" => chat_id} = metadata
    assert chat_id == info.call_id
    refute Map.has_key?(metadata, "message_id")
    settle_refute_receive({:ingress, _, _, _, _, _}, 50)
  end

  describe "a Group with Router calls" do
    setup do
      SystemsRuntime.put_env(:salix_voice, :test_preferences, %{
        "voice" => %{"kind" => "custom"},
        "custom_voice" => %{"id" => "voice_dot", "name" => "Dot", "description" => "Warm"},
        "router_calls" => true
      })

      on_exit(fn ->
        SystemsRuntime.delete_env(:salix_voice, :test_preferences)
        SystemsRuntime.delete_env(:salix_voice, :test_persona)
      end)
    end

    test "the call speaks as the Router with its voice, persona, notes and history" do
      SystemsRuntime.put_env(
        :salix_voice,
        :test_persona,
        {:ok,
         %{
           name: "Dot",
           persona: "You are cheerful and call the user boss.",
           notes: "The user lives in Beijing.",
           input: [
             %{"role" => "user", "text" => "Book the dentist for Friday."},
             %{"role" => "assistant", "text" => "Booked for 3 pm."}
           ]
         }}
      )

      {:ok, %{call_id: id}} = admit(%{carrier: :signal, key_id: nil})
      [call] = :pg.get_members(@pg, {:call, id})
      watch(call)

      settle_receive({:persona_resolve, _group_id, audience})
      settle_receive({:fake_model, model, {:started, model_opts}})

      # The persona is read for the caller's own one-to-one, as voice ingress
      # records it.
      assert audience == %{
               tenant_id: "ten_1",
               connect_id: "conn_voice",
               user_id: "key_1",
               requester: "api_key:key_1:usr_creator"
             }

      # The Router's identity replaces the caller profile.
      settle_refute_receive({:profile_decide, _, _, _}, 20)

      assert model_opts.voice == %{"id" => "voice_dot"}

      assert [%{"role" => "user"}, %{"role" => "assistant", "text" => "Booked for 3 pm."}] =
               model_opts.input

      assert model_opts.instructions =~ "You are Dot"
      assert model_opts.instructions =~ "call the user boss"
      assert model_opts.instructions =~ "lives in Beijing"
      assert model_opts.instructions =~ "delegate it"
      refute model_opts.instructions =~ "voice of the Comma assistant"

      assert {:ok, ^call, _info} = SalixVoice.attach(id, SystemsRuntime.Proc.self())
      emit(model, call, {:started, "router-session"})
      settle_receive({:fake_model, ^model, {:append, :instructions, nil, greeting}})
      assert greeting =~ "as Dot"
      settle_receive({:ingress, _, _, %{"event_type" => "voice.call_started"}, _, _})

      emit(model, call, {:input_transcript, "How was", true, 100})
      emit(model, call, {:input_transcript, "my week?", true, 400})
      emit(model, call, {:output_transcript, "Busy, boss!", true})
      SystemsRuntime.Proc.send(call, {:voice_carrier, :hangup, :normal})
      await_end(call, :caller_hangup)

      # The Router remembers the call like a chat.
      settle_receive({:ingress, _, content, %{"event_type" => "voice.call_ended"}, _, _})
      assert content =~ "Caller: How was my week?\nYou: Busy, boss!"
    end

    test "without the Router's identity the call starts with the base instructions" do
      {:ok, %{call_id: _id}} = admit(%{carrier: :signal, key_id: nil})
      settle_receive({:persona_resolve, _group_id, _audience})
      settle_receive({:fake_model, _model, {:started, model_opts}})
      assert model_opts.instructions == SalixVoice.CallActor.instructions()
      assert model_opts.input == []
      assert model_opts.voice == %{"id" => "voice_dot"}
    end

    test "a Signal group call keeps its voice but never speaks as the Router" do
      {:ok, %{call_id: id}} =
        admit(%{
          carrier: :signal,
          key_id: nil,
          key_name: nil,
          principal: nil,
          caller: %{"kind" => "signal_group", "value" => "grp-signal-1"}
        })

      [call] = :pg.get_members(@pg, {:call, id})
      watch(call)

      settle_receive({:fake_model, model, {:started, model_opts}})
      settle_refute_receive({:persona_resolve, _, _}, 20)
      assert model_opts.voice == %{"id" => "voice_dot"}
      assert model_opts.instructions == SalixVoice.CallActor.instructions()
      assert model_opts.input == []

      assert {:ok, ^call, _info} = SalixVoice.attach(id, SystemsRuntime.Proc.self())
      emit(model, call, {:started, "group-session"})
      settle_receive({:ingress, _, _, %{"event_type" => "voice.call_started"}, _, _})
      emit(model, call, {:input_transcript, "Read me the notes.", true, 100})
      SystemsRuntime.Proc.send(call, {:voice_carrier, :hangup, :normal})
      await_end(call, :caller_hangup)

      # The group's words are not handed to the Router as its own conversation.
      settle_receive({:ingress, _, content, %{"event_type" => "voice.call_ended"}, _, _})
      refute content =~ "What was said"
    end
  end

  test "the call-end input follows a slow call-start input" do
    SystemsRuntime.put_env(:salix_voice, :test_ingress_delays, %{"voice.call_started" => 200})
    on_exit(fn -> SystemsRuntime.delete_env(:salix_voice, :test_ingress_delays) end)

    {:ok, %{call_id: id}} = admit()
    [call] = :pg.get_members(@pg, {:call, id})
    watch(call)
    settle_receive({:fake_model, model, {:started, _}})
    assert {:ok, ^call, _} = SalixVoice.attach(id, SystemsRuntime.Proc.self())
    emit(model, call, {:started, "sess_order"})
    SystemsRuntime.Proc.send(call, {:voice_carrier, :hangup, :normal})
    await_end(call, :caller_hangup)

    settle_receive({:ingress, _, _, %{"event_type" => first}, _, _})
    settle_receive({:ingress, _, _, %{"event_type" => second}, _, _})
    assert [first, second] == ["voice.call_started", "voice.call_ended"]
  end

  test "a call that never became ready sends the Router nothing" do
    {:ok, %{call_id: id}} = admit()
    [call] = :pg.get_members(@pg, {:call, id})
    watch(call)
    assert {:ok, ^call, _} = SalixVoice.attach(id, SystemsRuntime.Proc.self())
    SystemsRuntime.Proc.send(call, {:voice_carrier, :hangup, :normal})
    await_end(call, :caller_hangup)
    settle_refute_receive({:ingress, _, _, _, _, _}, 100)
  end

  test "a failed call-start input leaves the call live" do
    SystemsRuntime.put_env(:salix_voice, :test_ingress_result, {:error, :router_unavailable})
    on_exit(fn -> SystemsRuntime.delete_env(:salix_voice, :test_ingress_result) end)

    {call, info, model} = live_call()
    _ = :sys.get_state(call, :infinity)

    assert {:ok, %{"delivered" => true}} = provider(call, :say, info, %{"text" => "Hello."})
    settle_receive({:fake_model, ^model, {:append, :commentary, nil, "Hello."}})
  end

  test "caller audio before the model starts keeps the newest 2 s, then flows both ways" do
    {call, _info, model} = live_call(%{}, start_model: false)

    # 30 frames of 100 ms (800 bytes of mu-law) before the model is ready.
    for i <- 1..30,
        do: SystemsRuntime.Proc.send(call, {:voice_carrier, :audio, :binary.copy(<<i>>, 800)})

    _ = :sys.get_state(call, :infinity)
    refute_received {:fake_model, ^model, {:audio, _}}

    Fake.emit(model, {:started, "sess_1"})

    for i <- 11..30 do
      frame = :binary.copy(<<i>>, 800)
      settle_receive({:fake_model, ^model, {:audio, ^frame}})
    end

    refute_received {:fake_model, ^model, {:audio, _}}

    SystemsRuntime.Proc.send(call, {:voice_carrier, :audio, <<99>>})
    settle_receive({:fake_model, ^model, {:audio, <<99>>}})

    Fake.emit(model, {:audio, <<1, 2, 3>>})
    settle_receive({:voice_call, :audio, <<1, 2, 3>>})

    Fake.emit(model, :speech_started)
    settle_receive({:voice_call, :clear})

    Fake.emit(model, {:input_transcript, "Hello", true, 100})
    settle_receive({:voice_call, :transcript, :caller, "Hello", true})
    Fake.emit(model, {:output_transcript, "Hi there.", true})
    settle_receive({:voice_call, :transcript, :agent, "Hi there.", true})
  end

  test "a delegation becomes Router provider input with the caller's words up to its offset" do
    {_call, info, model} = live_call()

    Fake.emit(model, {:output_transcript, "Hello, how can I help? ", true})
    Fake.emit(model, {:output_transcript, "Tell me more.", true})
    Fake.emit(model, {:input_transcript, "What's the weather", true, 1_000})
    Fake.emit(model, {:input_transcript, "in Paris?", true, 1_400})
    Fake.emit(model, {:input_transcript, "Also book", true, 3_000})
    Fake.emit(model, {:delegation, "dlg_1", 2_000})

    settle_receive({:ingress, group_id, content, metadata, source_id, opts})
    assert group_id == info.group_id
    assert source_id == "im_provider:voice:conn_voice:#{info.call_id}:dlg_1"
    assert opts[:trusted_source_text] == "What's the weather in Paris?"
    assert opts[:session_name] == "Voice call"
    assert content =~ "What's the weather in Paris?"
    assert content =~ "Tell me more."
    refute content =~ "Also book"

    assert %{
             "provider" => "voice",
             "connect_id" => "conn_voice",
             "chat_id" => chat_id,
             "chat_type" => "private",
             "message_id" => "dlg_1",
             "from_user_id" => "api_key:key_1",
             "from_username" => "Ada",
             "event_type" => "voice.delegation",
             "event_id" => "dlg_1",
             "source_actor_type" => "provider_system",
             "api_key_id" => "key_1",
             "api_key_name" => "Desk phone",
             "api_key_principal" => "api_key:key_1:usr_creator",
             "source_sent_at_ms" => sent_at
           } = metadata

    assert chat_id == info.call_id
    assert is_integer(sent_at)

    # The next delegation carries only the words after the previous one.
    Fake.emit(model, {:delegation, "dlg_2", 4_000})
    settle_receive({:ingress, _, _content, _, _, opts})
    assert opts[:trusted_source_text] == "Also book"
  end

  test "voice.say speaks through commentary in chunks and answers the oldest delegation" do
    {call, info, model} = live_call()
    emit(model, call, {:delegation, "dlg_1", 500})
    emit(model, call, {:delegation, "dlg_2", 900})
    settle_receive({:ingress, _, _, _, _, _})
    settle_receive({:ingress, _, _, _, _, _})

    sentence = String.duplicate("word ", 60) |> String.trim() |> Kernel.<>(".")
    long = Enum.map_join(1..8, " ", fn _ -> sentence end)

    assert {:ok, %{"delivered" => true, "chunks" => chunks, "delegation_id" => "dlg_1"}} =
             provider(call, :say, info, %{"text" => long})

    assert chunks > 1

    appended =
      for _ <- 1..chunks do
        settle_receive({:fake_model, ^model, {:append, :commentary, "dlg_1", text}})
        assert String.length(text) <= 1_800
        text
      end

    assert Enum.join(appended, " ") == long

    assert {:ok, %{"delegation_id" => "dlg_2", "chunks" => 1}} =
             provider(call, :say, info, %{"text" => "Paris is sunny."})

    settle_receive({:fake_model, ^model, {:append, :commentary, "dlg_2", "Paris is sunny."}})

    assert {:ok, %{"delegation_id" => "dlg_2"}} =
             provider(call, :say, info, %{"text" => "Anything else?", "delegation_id" => "dlg_2"})

    assert {:ok, %{"chunks" => 1}} =
             provider(call, :note, info, %{"text" => "Checking the calendar."})

    settle_receive({:fake_model, ^model, {:append, :thinking, nil, "Checking the calendar."}})
  end

  test "provider calls for another Group or connect are forbidden; bad input is rejected" do
    {call, info, model} = live_call()
    emit(model, call, {:delegation, "dlg_1", 500})
    settle_receive({:ingress, _, _, _, _, _})

    assert {:error, :forbidden} =
             GenServer.call(
               call,
               {:voice_provider, :say,
                request(info, %{"group_id" => "grp_other", "text" => "hi"})},
               :infinity
             )

    assert {:error, :forbidden} =
             GenServer.call(
               call,
               {:voice_provider, :say,
                request(info, %{"connect_id" => "conn_other", "text" => "hi"})},
               :infinity
             )

    assert {:error, {:bad_request, _}} = provider(call, :say, info, %{"text" => "  "})

    assert {:error, {:bad_request, _}} =
             provider(call, :say, info, %{"text" => "hi", "delegation_id" => "dlg_x"})

    assert {:error, {:bad_request, _}} = provider(call, :transfer, info, %{"text" => "hi"})
    refute_received {:fake_model, ^model, {:append, _, _, _}}
  end

  test "an unanswered delegation gets one thinking update and one spoken apology" do
    SystemsRuntime.put_env(:salix_voice, :timers,
      delegation_settle_ms: 10,
      progress_thinking_ms: 60,
      progress_apology_ms: 150,
      model_close_wait_ms: 300
    )

    {call, info, model} = live_call()
    emit(model, call, {:delegation, "dlg_slow", 500})
    emit(model, call, {:delegation, "dlg_fast", 700})

    assert {:ok, %{"delegation_id" => "dlg_slow"}} =
             provider(call, :say, info, %{"text" => "Done.", "delegation_id" => "dlg_slow"})

    settle_receive({:fake_model, ^model, {:append, :commentary, "dlg_slow", "Done."}})

    settle_receive(
      {:fake_model, ^model,
       {:append, :thinking, "dlg_fast", "The assistant is still working on it."}}
    )

    settle_receive({:fake_model, ^model, {:append, :commentary, "dlg_fast", "Sorry" <> _}})
    SystemsClock.sleep(200)
    refute_received {:fake_model, ^model, {:append, _, "dlg_slow", "The assistant" <> _}}
    refute_received {:fake_model, ^model, {:append, _, _, _}}
  end

  test "voice.hang_up speaks the farewell, ends the call and bills it" do
    handler = attach_telemetry()

    {call, info, model} =
      live_call(%{
        carrier: :twilio,
        carrier_call_id: "CA_hangup",
        caller: %{"kind" => "e164", "value" => "+15551234567"},
        key_id: nil
      })

    # A phone caller is a provider user identified by the E.164 number.
    emit(model, call, {:delegation, "dlg_phone", 100})
    settle_receive({:ingress, _, _, metadata, _, _})
    assert metadata["source_actor_type"] == "provider_user"
    assert metadata["from_user_id"] == "+15551234567"
    refute Map.has_key?(metadata, "api_key_principal")

    assert {:ok, %{"ending" => true}} =
             provider(call, :hang_up, info, %{
               "text" => "Goodbye!",
               "delegation_id" => "dlg_phone"
             })

    settle_receive({:fake_model, ^model, {:append, :commentary, "dlg_phone", "Goodbye!"}})
    Fake.emit(model, {:audio, <<1>>})
    settle_receive({:voice_call, :audio, <<1>>})

    await_end(call, :agent_hangup)
    settle_receive({:fake_model, ^model, :close})

    # A call another test ended may bill after this test starts; match this one.
    settle_receive({:metered, %{source_key: "voice:twilio:CA_hangup"} = attrs})
    assert attrs.group_id == info.group_id
    assert attrs.tenant_id == "ten_1"
    assert attrs.owner_snapshot["billing_account_id"] == "ba_voice"
    assert attrs.provider == "openai"
    assert attrs.sku == "gpt-live-1"

    assert [
             %{component: :model_seconds, meter_unit: :second, quantity: 42},
             %{component: :carrier_seconds, meter_unit: :second, quantity: carrier_seconds}
           ] = attrs.components

    assert carrier_seconds >= 1
    # Other tests' calls may end while this handler is attached; this is the
    # only Twilio call.
    settle_receive(
      {:telemetry, [:salix, :voice, :call, :stop], %{duration: _}, %{transport: "twilio"} = meta}
    )

    assert meta == %{transport: "twilio", reason: "agent_hangup"}
    SystemsRuntime.Telemetry.detach(handler)
  end

  test "voice.hang_up without text ends at once; a late provider call finds no call" do
    {call, info, _model} = live_call()
    assert {:ok, %{"ending" => true}} = provider(call, :hang_up, info, %{})
    await_end(call, :agent_hangup)
    assert SalixVoice.whereis(info.call_id) == nil
  end

  test "one active call per Group: admission refuses a second call and a race ends the later one" do
    group_id = "grp_busy"
    {:ok, _} = admit(%{group_id: group_id})
    assert {:error, :busy} = admit(%{group_id: group_id})

    # Two calls that both passed admission: the later {started_at_ms, call_id} ends.
    settings = elem(Settings.get(), 1)

    args = fn call_id, started ->
      %{
        call_id: call_id,
        carrier: :websocket,
        tenant_id: "ten_1",
        group_id: "grp_race",
        connect_id: "conn_voice",
        caller: %{"kind" => "api_key", "value" => "key_1"},
        carrier_call_id: nil,
        audio_format: :pcmu_8k,
        settings: settings,
        started_at_ms: started
      }
    end

    {:ok, early} =
      DynamicSupervisor.start_child(
        SalixVoice.CallSupervisor,
        {SalixVoice.CallActor, args.("vc_EARLY", 1_000)}
      )

    # The later call ends once the earlier one answers its busy probe. Hold
    # the earlier call until the test monitors the later one, so the later
    # call cannot stop before the monitor is in place.
    :ok = :sys.suspend(early, :infinity)

    {:ok, late} =
      DynamicSupervisor.start_child(
        SalixVoice.CallSupervisor,
        {SalixVoice.CallActor, args.("vc_LATE", 2_000)}
      )

    watch(late)
    :ok = :sys.resume(early, :infinity)
    await_down(late)
    assert SystemsRuntime.Proc.alive?(early)
    assert :pg.get_members(@pg, {:group_call, "grp_race"}) == [early]
  end

  test "a Group call that becomes visible only after this call started still ends the later one" do
    # `:pg` propagates a remote join asynchronously. Two nodes can admit calls
    # for one Group within that window (or across a healed partition), and then
    # neither call saw the other in `get_members` at its start. `remote` stands
    # in for such a remote CallActor: it joins after this call started and
    # answers a busy probe with an earlier `{started_at_ms, call_id}`.
    {call, info, _model} = live_call()
    test = SystemsRuntime.Proc.self()
    # The monitor `live_call/0` set (see `watch/1`): the call may end and stop
    # before the test sees the probe.
    ref = Process.get({:watch, call})

    remote =
      SystemsRuntime.Proc.spawn(fn ->
        :ok = :pg.join(@pg, {:group_call, info.group_id}, SystemsRuntime.Proc.self())
        SystemsRuntime.Proc.send(test, :remote_joined)

        SystemsRuntime.Proc.receive do
          {:voice_busy_probe, pid, key} ->
            SystemsRuntime.Proc.send(test, {:remote_probed, pid, key})

            SystemsRuntime.Proc.send(
              pid,
              {:voice_busy_probe_reply, SystemsRuntime.Proc.self(), {0, "vc_REMOTE_EARLIER"}}
            )
        end

        SystemsRuntime.Proc.sleep(:infinity)
      end)

    settle_receive(:remote_joined)
    settle_receive({:remote_probed, ^call, {_started_at_ms, call_id}})
    assert call_id == info.call_id
    settle_receive({:voice_call, :end, :busy})
    settle_receive({:DOWN, ^ref, :process, ^call, reason})
    assert reason == :normal
    assert :pg.get_members(@pg, {:group_call, info.group_id}) == [remote]
    SystemsRuntime.Proc.exit(remote, :kill)
  end

  test "node cap, disabled voice and a missing model key refuse admission" do
    {:ok, _} = Settings.update(%{"max_calls_per_node" => 1})
    {:ok, _} = admit()
    assert {:error, :node_full} = admit()

    {:ok, _} = Settings.update(%{"enabled" => false})
    assert {:error, :disabled} = admit()

    {:ok, _} = Settings.update(%{"enabled" => true, "clear_secrets" => ["openai_api_key"]})
    assert {:error, :not_configured} = admit()
  end

  test "a revoked voice key plays a notice and ends the call as revoked" do
    {call, _info, model} = live_call(%{key_id: "key_revoked"})

    for pid <- :pg.get_members(@pg, {:voice_key, "key_revoked"}),
        do: SystemsRuntime.Proc.send(pid, {:voice_key_revoked, "key_revoked"})

    settle_receive({:fake_model, ^model, {:append, :instructions, nil, _notice}})
    await_end(call, :revoked)
  end

  test "an expiring voice key ends the call at its expiry" do
    expires = SystemsClock.system_time(:millisecond) + 150
    {call, _info, _model} = live_call(%{key_id: "key_expiring", key_expires_at: expires})
    await_end(call, :revoked)
  end

  test "drain tells callers the call must end, ends every local call and refuses new ones" do
    {call, _info, model} = live_call()
    {:ok, %{call_id: waiting}} = admit()

    SalixCluster.NodeLifecycle.mark_draining()
    assert {:error, :draining} = admit()

    assert :ok = SalixVoice.Drain.drain()
    settle_receive({:fake_model, ^model, {:append, :instructions, nil, _notice}})
    settle_receive({:voice_call, :end, :draining})
    refute SystemsRuntime.Proc.alive?(call)
    assert SalixVoice.whereis(waiting) == nil
  end

  test "the call deadline ends the call" do
    SystemsRuntime.put_env(:salix_voice, :timers,
      max_call_ms: 100,
      notice_max_ms: 100,
      quiet_ms: 50
    )

    handler = attach_telemetry()
    {call, _info, model} = live_call()
    settle_receive({:fake_model, ^model, {:append, :instructions, nil, _notice}})
    await_end(call, :max_duration)
    settle_receive({:telemetry, [:salix, :voice, :call, :stop], _, %{reason: "timeout"}})
    SystemsRuntime.Telemetry.detach(handler)
  end

  test "Twilio attach needs the stream token, the admitted CallSid and a single socket" do
    {:ok, %{call_id: call_id, token: token}} =
      admit(%{
        carrier: :twilio,
        carrier_call_id: "CA_attach",
        caller: %{"kind" => "e164", "value" => "+15551234567"}
      })

    assert is_binary(token)
    assert {:error, :token_required} = SalixVoice.attach(call_id, SystemsRuntime.Proc.self())

    assert {:error, :carrier_call_mismatch} =
             SalixVoice.attach(token, SystemsRuntime.Proc.self(), carrier_call_id: "CA_other")

    # A `start` frame without a callSid does not skip the binding check.
    assert {:error, :carrier_call_mismatch} = SalixVoice.attach(token, SystemsRuntime.Proc.self())

    assert {:ok, _call, info} =
             SalixVoice.attach(token, SystemsRuntime.Proc.self(), carrier_call_id: "CA_attach")

    assert info.carrier_call_id == "CA_attach"

    other = SystemsRuntime.Proc.spawn(fn -> SystemsRuntime.Proc.sleep(:infinity) end)

    assert {:error, :already_attached} =
             SalixVoice.attach(token, other, carrier_call_id: "CA_attach")

    assert {:error, :invalid_token} = SalixVoice.attach("forged.token", other)
  end

  test "a call whose carrier never attaches ends; a lost socket ends the call" do
    SystemsRuntime.put_env(:salix_voice, :timers,
      attach_websocket_ms: 100,
      model_close_wait_ms: 100
    )

    {:ok, %{call_id: call_id}} = admit()
    call = watch(SalixVoice.whereis(call_id))
    await_down(call)

    {:ok, %{call_id: call_id}} = admit()

    socket =
      SystemsRuntime.Proc.spawn(fn ->
        SystemsRuntime.Proc.receive(do: (:stop -> exit(:crash)))
      end)

    {:ok, call, _info} = SalixVoice.attach(call_id, socket)
    watch(call)
    handler = attach_telemetry()
    SystemsRuntime.Proc.send(socket, :stop)
    await_down(call)
    settle_receive({:telemetry, [:salix, :voice, :call, :stop], _, %{reason: "carrier_error"}})
    SystemsRuntime.Telemetry.detach(handler)
  end

  test "a stale attach timeout does not end an attached call" do
    {call, _info, _model} = live_call()

    # The timer fired just before the attach cancelled it.
    SystemsRuntime.Proc.send(call, {:timer, :attach, :attach_timeout})
    _ = :sys.get_state(call, :infinity)
    assert SystemsRuntime.Proc.alive?(call)
    refute_received {:voice_call, :end, _}
  end

  test "the call keeps no platform secrets in its state or status" do
    {call, _info, _model} = live_call()

    refute inspect(:sys.get_state(call, :infinity)) =~ "sk-test"
    refute inspect(:sys.get_status(call, :infinity)) =~ "sk-test"

    # Before the model starts, a crash report redacts the key.
    status = %{state: %{model_settings: %{"openai_api_key" => "sk-test"}}}
    refute inspect(SalixVoice.CallActor.format_status(status)) =~ "sk-test"
  end

  test "after a model transport loss the elapsed session time is the billing floor" do
    {call, info, model} = live_call()
    SystemsClock.sleep(20)

    # The last usage snapshot is older than the session.
    Fake.emit(model, {:closed, "connection_lost", %{"seconds" => 0}})
    await_end(call, :model_error)

    source_key = "voice:websocket:#{info.call_id}"
    settle_receive({:metered, %{source_key: ^source_key} = attrs})

    assert [%{component: :model_seconds, quantity: model_seconds}, _carrier] = attrs.components
    assert model_seconds >= 1
  end

  test "removing a caller number ends that number's phone call as revoked" do
    {call, info, model} =
      live_call(%{
        carrier: :twilio,
        carrier_call_id: "CA_removed",
        caller: %{"kind" => "e164", "value" => "+15557654321"},
        key_id: nil
      })

    assert :ok = SalixVoice.revoke_caller(info.group_id, "+15550000000")
    _ = :sys.get_state(call, :infinity)
    refute_received {:voice_call, :end, _}

    assert :ok = SalixVoice.revoke_caller(info.group_id, "+15557654321")
    settle_receive({:fake_model, ^model, {:append, :instructions, nil, _notice}})
    await_end(call, :revoked)
  end

  test "a model that fails before starting ends the call as a model error" do
    {:ok, %{call_id: call_id}} = admit()
    {:ok, call, _info} = SalixVoice.attach(call_id, SystemsRuntime.Proc.self())
    watch(call)
    settle_receive({:fake_model, model, {:started, _}})
    Fake.emit(model, {:error, %{"code" => "invalid_api_key"}})
    await_end(call, :model_error)
  end

  defp attach_telemetry do
    handler = "voice-test-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.Telemetry.attach_many(
      handler,
      [[:salix, :voice, :call, :stop], [:salix, :voice, :delegation, :stop]],
      fn event, measurements, meta, _ ->
        SystemsRuntime.Proc.send(parent, {:telemetry, event, measurements, meta})
      end,
      nil
    )

    handler
  end
end
