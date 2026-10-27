defmodule CommaWeb.DictationSocketTest do
  use SystemsClock.Case, async: false

  import Plug.Test

  alias CommaWeb.DictationSocket

  # A provider that guesses the bytes it has heard so far and settles on them.
  defmodule CountingAsr do
    def name, do: "counting"
    def retryable?(_reason), do: false

    def recognize(audio, emit, _config) do
      heard =
        Enum.reduce(audio, 0, fn pcm, heard ->
          heard = heard + byte_size(pcm)
          emit.(%{text: "heard #{heard}", start_ms: 0, end_ms: 0, final: false})
          heard
        end)

      emit.(%{text: "said #{heard}", start_ms: 0, end_ms: 0, final: true})
      :ok
    end
  end

  # A provider that fails for good after its first guess.
  defmodule FailingAsr do
    def name, do: "failing"
    def retryable?(_reason), do: false

    def recognize(audio, emit, _config) do
      Enum.take(audio, 1)
      emit.(%{text: "half a", start_ms: 0, end_ms: 0, final: false})
      {:error, :refused}
    end
  end

  # A provider that says when its connection starts, then guesses as CountingAsr does.
  defmodule ReportingAsr do
    def name, do: "reporting"
    def retryable?(_reason), do: false

    def recognize(audio, emit, config) do
      send(config.test, {:recognizing, self()})
      CountingAsr.recognize(audio, emit, config)
    end
  end

  setup do
    unless SystemsRuntime.Proc.whereis(CommaWeb.DictationRegistry),
      do: start_supervised!(DictationSocket)

    :ok
  end

  # 40 ms frames of 16 kHz s16le: loud enough to be speech, or silent.
  defp speech(frames), do: :binary.copy(<<1_000::signed-little-16>>, 640 * frames)
  defp silence(frames), do: :binary.copy(<<0::signed-little-16>>, 640 * frames)

  defp open(provider, transcribe \\ nil) do
    user = "user-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    config = %{test: self()}

    {:ok, state} =
      DictationSocket.init(%{
        user_id: user,
        provider: {provider, config},
        transcribe: transcribe
      })

    state
  end

  defp send_pcm(state, pcm) do
    pcm
    |> chunks(12_800)
    |> Enum.reduce(state, fn chunk, state ->
      {:ok, state} = DictationSocket.handle_in({chunk, opcode: :binary}, state)
      state
    end)
  end

  defp chunks(<<chunk::binary-size(12_800), rest::binary>>, size),
    do: [chunk | chunks(rest, size)]

  defp chunks(rest, _size), do: [rest]

  # Feeds the socket what its segments sent it until `until` matches a result.
  defp drain(state, frames, until) do
    receive do
      {kind, _segment, _result} = message when kind in [:interim, :final, :transcribed] ->
        step(DictationSocket.handle_info(message, state), frames, until)

      {:DOWN, _ref, :process, _pid, _reason} = message ->
        step(DictationSocket.handle_info(message, state), frames, until)
    end
  end

  defp step(result, frames, until) do
    {pushed, state} =
      case result do
        {:ok, state} ->
          {[], state}

        {:push, {:text, text}, state} ->
          {[text], state}

        {:push, list, state} ->
          {for({:text, text} <- list, do: text), state}

        {:stop, :normal, code, list, state} ->
          {for({:text, text} <- list, do: text) ++ [code], state}
      end

    frames = frames ++ Enum.map(pushed, &decode/1)
    if until.(frames), do: {frames, state}, else: drain(state, frames, until)
  end

  defp decode(code) when is_integer(code), do: {:closed, code}
  defp decode(text), do: Jason.decode!(text)

  test "the words come as the speaker speaks, each segment's settle, and the socket ends after end" do
    state = open(CountingAsr)
    # Speech, then the pause that ends the segment.
    state = send_pcm(state, speech(25) <> silence(25))

    {frames, state} =
      drain(state, [], fn frames -> Enum.any?(frames, &match?(%{"type" => "final"}, &1)) end)

    assert [%{"type" => "partial", "segment" => 0} | _] = frames
    assert %{"type" => "final", "segment" => 0, "text" => "said " <> _} = List.last(frames)

    assert {:stop, :normal, 1000, [{:text, done}], _state} =
             wait_done(DictationSocket.handle_in({~s({"type":"end"}), opcode: :text}, state))

    assert %{"type" => "done"} = Jason.decode!(done)
  end

  test "the words the speaker is still saying at end are settled before the socket closes" do
    state = open(CountingAsr)
    state = send_pcm(state, speech(10))
    {:ok, state} = DictationSocket.handle_in({~s({"type":"end"}), opcode: :text}, state)

    {frames, _state} = drain(state, [], fn frames -> List.last(frames) == {:closed, 1000} end)

    assert %{"type" => "final", "segment" => 0, "text" => "said " <> _} =
             Enum.find(frames, &match?(%{"type" => "final"}, &1))

    assert %{"type" => "done"} = Enum.at(frames, -2)
  end

  test "a sealed segment's transcription gives its words; the provider's stay a partial" do
    test = self()

    transcribe = fn pcm ->
      send(test, {:transcribing, byte_size(pcm)})
      {:ok, " transcribed #{byte_size(pcm)} "}
    end

    state = open(CountingAsr, transcribe)
    state = send_pcm(state, speech(25) <> silence(25))

    {frames, state} =
      drain(state, [], fn frames -> Enum.any?(frames, &match?(%{"type" => "final"}, &1)) end)

    # The segment's audio, its first frames to the pause that sealed it, is what was transcribed.
    assert_received {:transcribing, bytes}
    assert bytes >= byte_size(speech(25))
    expected = "transcribed #{bytes}"

    assert [%{"type" => "final", "segment" => 0, "text" => ^expected}] =
             Enum.filter(frames, &match?(%{"type" => "final"}, &1))

    # The provider's guesses came as partials while the transcription ran.
    assert Enum.all?(Enum.drop(frames, -1), &match?(%{"type" => "partial", "segment" => 0}, &1))

    assert {:stop, :normal, 1000, [{:text, done}], _state} =
             wait_done(DictationSocket.handle_in({~s({"type":"end"}), opcode: :text}, state))

    assert %{"type" => "done"} = Jason.decode!(done)
  end

  test "when the transcription fails, the provider's words are the segment's" do
    state = open(CountingAsr, fn _pcm -> {:error, :asr_not_configured} end)
    state = send_pcm(state, speech(25) <> silence(25))

    {frames, _state} =
      drain(state, [], fn frames -> Enum.any?(frames, &match?(%{"type" => "final"}, &1)) end)

    assert %{"type" => "final", "segment" => 0, "text" => "said " <> _} = List.last(frames)
  end

  test "the socket ends once the last segment's transcription has given its words" do
    test = self()

    transcribe = fn _pcm ->
      send(test, {:transcribing, self()})

      receive do
        :answer -> {:ok, "多言語の言葉"}
      end
    end

    state = open(CountingAsr, transcribe)
    state = send_pcm(state, speech(10))
    {:ok, state} = DictationSocket.handle_in({~s({"type":"end"}), opcode: :text}, state)

    # The provider settled its words, but the transcription has not answered yet.
    {frames, state} =
      drain(state, [], fn frames -> Enum.any?(frames, &match?(%{"text" => "said " <> _}, &1)) end)

    assert %{"type" => "partial", "text" => "said " <> _} = List.last(frames)

    transcription =
      receive do
        {:transcribing, transcription} -> transcription
      end

    send(transcription, :answer)

    {frames, _state} = drain(state, [], fn frames -> List.last(frames) == {:closed, 1000} end)

    assert [
             %{"type" => "final", "segment" => 0, "text" => "多言語の言葉"},
             %{"type" => "done"},
             _closed
           ] =
             frames
  end

  test "two segments are transcribed at once; the next starts when one answers" do
    test = self()

    transcribe = fn pcm ->
      send(test, {:transcribing, self(), byte_size(pcm)})

      receive do
        :answer -> {:ok, "words"}
      end
    end

    state = open(CountingAsr, transcribe)
    # Three segments, each sealed by its pause.
    state = send_pcm(state, String.duplicate(speech(10) <> silence(25), 3))

    first =
      receive do
        {:transcribing, transcription, _bytes} -> transcription
      end

    second =
      receive do
        {:transcribing, transcription, _bytes} -> transcription
      end

    refute_received {:transcribing, _third, _bytes}
    send(first, :answer)

    {_frames, _state} =
      drain(state, [], fn frames ->
        Enum.any?(frames, &match?(%{"type" => "final", "text" => "words"}, &1))
      end)

    third =
      receive do
        {:transcribing, transcription, _bytes} -> transcription
      end

    send(second, :answer)
    send(third, :answer)
  end

  test "a segment the provider gives up on keeps its last guess as its words" do
    state = open(FailingAsr)
    state = send_pcm(state, speech(10) <> silence(25))

    {frames, _state} =
      drain(state, [], fn frames -> Enum.any?(frames, &match?(%{"type" => "final"}, &1)) end)

    assert %{"type" => "final", "segment" => 0, "text" => "half a"} = List.last(frames)
  end

  test "the provider's connection is made before the speaker speaks, and the next one in each pause" do
    state = open(ReportingAsr)
    # Before any audio: the connection the first words will use.
    receive do
      {:recognizing, _connection} -> :ok
    end

    first = state.standby

    state = send_pcm(state, silence(10) <> speech(25) <> silence(25))
    # The words came through the connection made first, and a new one waits for the next words.
    {_frames, state} =
      drain(state, [], fn frames -> Enum.any?(frames, &match?(%{"type" => "final"}, &1)) end)

    assert is_pid(state.standby) and state.standby != first

    receive do
      {:recognizing, _next} -> :ok
    end
  end

  test "a connection that heard no speech is dropped, and one waiting too long is made again" do
    state = open(ReportingAsr)
    waiting = state.standby
    gone = Process.monitor(waiting)
    state = %{state | standby_at: state.standby_at - 16_000}
    {:ok, state} = DictationSocket.handle_info(:check, state)

    receive do
      {:DOWN, ^gone, :process, _, _} -> :ok
    end

    assert is_pid(state.standby) and state.standby != waiting

    # Silence only, then the end: nothing to settle, and no connection left.
    state = send_pcm(state, silence(10))
    dropped = Process.monitor(state.standby)

    assert {:stop, :normal, 1000, [{:text, done}], _state} =
             DictationSocket.handle_in({~s({"type":"end"}), opcode: :text}, state)

    assert %{"type" => "done"} = Jason.decode!(done)

    receive do
      {:DOWN, ^dropped, :process, _, _} -> :ok
    end
  end

  test "a frame that is not PCM, or audio past three minutes, closes the socket" do
    state = open(CountingAsr)

    assert {:stop, :normal, {1003, _}, _} =
             DictationSocket.handle_in({<<1, 2, 3>>, opcode: :binary}, state)

    long = %{open(CountingAsr) | samples: 3 * 60 * 16_000}

    assert {:stop, :normal, {4009, _}, _} =
             DictationSocket.handle_in({silence(1), opcode: :binary}, long)
  end

  test "words a provider has not settled when end runs out keep their last guess" do
    state = %{
      open(CountingAsr)
      | segments: %{self() => %{index: 0, text: "half a", final?: false}}
    }

    assert {:stop, :normal, 1000, [{:text, final}, {:text, done}], _state} =
             DictationSocket.handle_info(:end_timeout, state)

    assert %{"type" => "final", "segment" => 0, "text" => "half a"} = Jason.decode!(final)
    assert %{"type" => "done"} = Jason.decode!(done)
  end

  test "the socket takes its ticket alone, and the ticket takes a session" do
    opts = CommaWeb.Router.init([])

    # No session: the request reaches the socket, which wants an upgrade.
    socket = conn(:get, "/v1/comma/dictation?ticket=none") |> CommaWeb.Router.call(opts)
    assert socket.status == 426
    assert %{"error" => "websocket_required"} = Jason.decode!(socket.resp_body)

    ticket = conn(:post, "/v1/comma/me/dictation/tickets") |> CommaWeb.Router.call(opts)
    assert ticket.status == 401
  end

  test "a member has two dictation sockets at most" do
    user = "user-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    parent = self()

    for _ <- 1..2 do
      spawn_link(fn ->
        {:ok, _} = DictationSocket.init(%{user_id: user, provider: {CountingAsr, %{}}})
        send(parent, :open)

        receive do
          :never -> :ok
        end
      end)

      receive do
        :open -> :ok
      end
    end

    assert {:stop, :normal, {4029, _}, _} =
             DictationSocket.init(%{user_id: user, provider: {CountingAsr, %{}}})
  end

  defp wait_done({:stop, _, _, _, _} = stop), do: stop
  defp wait_done({:ok, state}), do: wait_done_drain(state)
  defp wait_done({:push, _frames, state}), do: wait_done_drain(state)

  defp wait_done_drain(state) do
    receive do
      {kind, _segment, _result} = message when kind in [:interim, :final, :transcribed] ->
        wait_done(DictationSocket.handle_info(message, state))

      {:DOWN, _ref, :process, _pid, _reason} = message ->
        wait_done(DictationSocket.handle_info(message, state))
    end
  end
end
