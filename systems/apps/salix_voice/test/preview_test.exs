defmodule SalixVoice.PreviewTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixVoice"]

  alias SalixStore.{Keys, S3}
  alias SalixVoice.Model.Fake
  alias SalixVoice.{Preview, Settings}
  alias SalixVoice.TestStubs

  defmodule Stubborn do
    @moduledoc false
    # The fake model, except that it ignores being asked to close.
    defdelegate start_link(opts), to: Fake
    defdelegate append(pid, kind, delegation_id, text), to: Fake
    defdelegate send_audio(pid, audio), to: Fake

    def close(pid) do
      observer = SystemsRuntime.get_env(:salix_voice, :fake_model_observer)
      SystemsRuntime.Proc.send(observer, {:fake_model, pid, :close_ignored})
      :ok
    end
  end

  @custom %{"id" => "voice_custom"}

  setup do
    S3.delete(Keys.ctl_system_voice())
    {:ok, _} = Settings.update(%{"enabled" => true, "openai_api_key" => "sk-test"})

    env = [
      model_mod: Fake,
      fake_model_observer: SystemsRuntime.Proc.self(),
      test_pid: SystemsRuntime.Proc.self(),
      test_admission: :ok,
      group_directory_mod: TestStubs.GroupDirectory,
      metering_mod: TestStubs.Metering,
      fake_model_seconds: 3,
      preview_timers: [quiet_ms: 100, max_ms: 1_000, close_ms: 500]
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

      S3.delete(Keys.ctl_system_voice())
    end)

    :ok
  end

  # Asks for a sample from a process of its own, which reports the answer.
  defp ask(voice, language, opts) do
    test = SystemsRuntime.Proc.self()

    SystemsRuntime.Proc.spawn(fn ->
      SystemsRuntime.Proc.send(test, {:sample, Preview.sample(voice, language, opts)})
    end)
  end

  defp sample(voice, language, opts \\ []) do
    ask(voice, language, opts)
    settle_receive({:fake_model, model, {:started, opts}})
    {model, opts}
  end

  # The model starts, is told to speak, says `audio`, and goes quiet.
  defp speak(model, audio) do
    Fake.emit(model, {:started, "sess_preview"})
    settle_receive({:fake_model, ^model, {:append, :commentary, nil, _speak}})
    Fake.emit(model, {:audio, audio})
  end

  test "a sample is the voice saying the fixed words, as WAV, until it has been quiet" do
    {model, opts} = sample("harema", "zh")
    assert opts.voice == "harema"
    assert opts.audio_format == :pcm16_24k

    # The words open the session and are given again once it has started;
    # then it hears 20 ms of silence at a time, as a caller's line would
    # carry, for its timeline to move.
    words = "你好，我是 Comma，这是我在通话里的声音。"
    assert [%{"role" => "developer", "text" => opening}] = opts.input
    assert opening =~ words
    refute_received {:fake_model, ^model, {:audio, _}}
    Fake.emit(model, {:started, "sess_preview"})
    settle_receive({:fake_model, ^model, {:append, :commentary, nil, speak}})
    assert speak =~ words
    silence = :binary.copy(<<0>>, 960)
    settle_receive({:fake_model, ^model, {:audio, ^silence}})
    settle_after(50)
    assert_received {:fake_model, ^model, {:audio, ^silence}}

    Fake.emit(model, {:audio, <<1, 2, 3, 4>>})
    Fake.emit(model, {:output_transcript, "你好", true})
    Fake.emit(model, {:audio, <<5, 6>>})
    settle_receive({:fake_model, ^model, :close})
    settle_receive({:sample, {:ok, wav}})

    assert <<"RIFF", 42::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
             24_000::little-32, 48_000::little-32, 2::little-16, 16::little-16, "data",
             6::little-32, 1, 2, 3, 4, 5, 6>> = wav

    # A preset's sample bills nobody.
    settle_refute_receive({:metered, _}, 20)
  end

  test "a language without its own words says the English ones, translated" do
    {model, opts} = sample("harema", "es")
    assert [%{"text" => opening}] = opts.input
    assert opening =~ "Spanish"
    assert opening =~ "Hello, I'm Comma, and this is how I sound on calls."
    Fake.emit(model, {:error, %{"code" => "server_error"}})
    settle_receive({:sample, {:error, :unavailable}})
  end

  test "a custom voice's sample is admitted and billed to its Group as a call" do
    {model, opts} = sample(@custom, "en", group_id: "grp_1")
    assert opts.voice == @custom
    speak(model, <<1, 2>>)
    settle_receive({:sample, {:ok, _wav}})

    # The seconds the closed model reports.
    settle_receive({:metered, metered})
    assert metered.group_id == "grp_1"
    assert metered.owner_snapshot["billing_account_id"] == "ba_voice"
    assert "voice:preview:vc_" <> _ = metered.source_key
    assert [%{component: :model_seconds, quantity: 3}] = metered.components
  end

  test "a lost connection bills at least the time the model was open" do
    SystemsRuntime.put_env(:salix_voice, :fake_model_seconds, 0)

    SystemsRuntime.put_env(:salix_voice, :preview_timers,
      quiet_ms: 10_000,
      max_ms: 10_000,
      close_ms: 500
    )

    {model, _opts} = sample(@custom, "en", group_id: "grp_1")
    speak(model, <<1, 2>>)
    settle_after(2_500)

    # Lost while open: the report is its last snapshot, 1 s of a session
    # open for longer.
    Fake.emit(model, {:closed, "connection_lost", %{"seconds" => 1}})
    settle_receive({:sample, {:ok, _wav}})
    settle_receive({:metered, %{components: [%{quantity: seconds}]}})
    assert seconds >= 3
  end

  test "a caller that goes away does not leave the model running" do
    test = SystemsRuntime.Proc.self()

    caller =
      SystemsRuntime.Proc.spawn(fn ->
        SystemsRuntime.Proc.send(test, {:sample, Preview.sample("harema", "en")})
      end)

    settle_receive({:fake_model, model, {:started, _opts}})
    monitor = SystemsRuntime.Proc.monitor(model)
    SystemsRuntime.Proc.exit(caller, :kill)

    speak(model, <<1, 2>>)
    settle_receive({:fake_model, ^model, :close})
    settle_receive({:DOWN, ^monitor, :process, ^model, _reason})
    refute_received {:sample, _}
  end

  test "a model that does not close is killed, and only then billed" do
    SystemsRuntime.put_env(:salix_voice, :model_mod, __MODULE__.Stubborn)
    {model, _opts} = sample(@custom, "en", group_id: "grp_1")
    monitor = SystemsRuntime.Proc.monitor(model)
    speak(model, <<1, 2>>)
    settle_receive({:fake_model, ^model, :close_ignored})
    refute_received {:metered, _}

    settle_receive({:DOWN, ^monitor, :process, ^model, :killed})
    settle_receive({:sample, {:ok, _wav}})
    settle_receive({:metered, %{components: [%{quantity: seconds}]}})
    assert seconds > 0
  end

  test "a session that ends or fails without audio gives no sample" do
    {model, _opts} = sample("harema", nil)
    Fake.emit(model, {:started, "sess_preview"})
    Fake.emit(model, {:error, %{"code" => "voice_not_found"}})
    settle_receive({:fake_model, ^model, :close})
    settle_receive({:sample, {:error, :unavailable}})
  end

  test "a session that never speaks ends at the deadline" do
    {model, _opts} = sample(nil, "en")
    settle_receive({:fake_model, ^model, :close})
    settle_receive({:sample, {:error, :unavailable}})
  end

  test "refusals start no session: voice off, the caller's limit, the Group's billing" do
    {:ok, _} = Settings.update(%{"enabled" => false})
    assert {:error, :disabled} = Preview.sample("harema", "en")
    {:ok, _} = Settings.update(%{"enabled" => true})

    assert {:error, :rate_limited} =
             Preview.sample("harema", "en", admit: fn -> {:error, :rate_limited} end)

    SystemsRuntime.put_env(
      :salix_voice,
      :test_admission,
      {:error, {:billing_unavailable, %{reason: "insufficient_credits"}}}
    )

    assert {:error, %{"reason" => "insufficient_credits", "retryable" => false}} =
             Preview.sample(@custom, "en", group_id: "grp_1")

    settle_refute_receive({:fake_model, _, {:started, _}}, 20)
  end
end
