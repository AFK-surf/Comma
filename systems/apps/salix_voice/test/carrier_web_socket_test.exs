defmodule SalixVoice.Carrier.WebSocketTest do
  use ExUnit.Case, async: true

  alias SalixVoice.Carrier.{Pacing, WebSocket}

  defp started(format) do
    start =
      Jason.encode!(%{
        "type" => "session.start",
        "audio_format" => format,
        "client" => "comma-voice/1"
      })

    {:ok, [{:start, _}], state} = WebSocket.decode({:text, start}, WebSocket.new())
    state
  end

  describe "comma.voice.v1 framing" do
    test "session.start opens the session and fixes the audio format" do
      start =
        Jason.encode!(%{
          "type" => "session.start",
          "audio_format" => "pcm16_24k",
          "client" => "comma-voice/1",
          "display_name" => " Ada ",
          "future_field" => true
        })

      assert {:ok, [{:start, info}], state} = WebSocket.decode({:text, start}, WebSocket.new())
      assert info == %{audio_format: :pcm16_24k, client: "comma-voice/1", display_name: "Ada"}

      assert {:ok, [{:audio, <<1, 2, 3, 4>>}], _} =
               WebSocket.decode({:binary, <<1, 2, 3, 4>>}, state)
    end

    test "wrong order, bad start and oversized or odd audio are bad frames (close 4400)" do
      state = WebSocket.new()
      assert {:error, {:bad_frame, _}} = WebSocket.decode({:binary, <<0>>}, state)

      assert {:error, {:bad_frame, _}} =
               WebSocket.decode({:text, ~s({"type":"session.end"})}, state)

      assert {:error, {:bad_frame, _}} =
               WebSocket.decode(
                 {:text, ~s({"type":"session.start","audio_format":"opus","client":"x"})},
                 state
               )

      assert {:error, {:bad_frame, _}} = WebSocket.decode({:text, "[]"}, state)

      pcmu = started("pcmu_8k")

      assert {:ok, [{:audio, _}], _} =
               WebSocket.decode({:binary, :binary.copy(<<0>>, 16_384)}, pcmu)

      assert {:error, {:bad_frame, _}} =
               WebSocket.decode({:binary, :binary.copy(<<0>>, 16_385)}, pcmu)

      assert {:error, {:bad_frame, _}} =
               WebSocket.decode(
                 {:text, ~s({"type":"session.start","audio_format":"pcmu_8k","client":"x"})},
                 pcmu
               )

      assert {:error, {:bad_frame, _}} =
               WebSocket.decode({:binary, <<1, 2, 3>>}, started("pcm16_24k"))

      assert WebSocket.close_code(:bad_frame) == 4400
    end

    test "client control messages and unknown types" do
      state = started("pcmu_8k")

      assert {:ok, [{:mark_played, "m1"}], _} =
               WebSocket.decode({:text, ~s({"type":"output.played","name":"m1"})}, state)

      assert {:ok, [{:hangup, :caller_hangup}], _} =
               WebSocket.decode({:text, ~s({"type":"session.end"})}, state)

      assert {:ok, [], ^state} = WebSocket.decode({:text, ~s({"type":"later.feature"})}, state)
    end

    test "server messages encode to documented JSON and audio splits at 16 KB" do
      state = started("pcmu_8k")

      assert {[{:text, json}], _} =
               WebSocket.encode(
                 {:started, %{call_id: "vc_1", audio_format: :pcmu_8k, max_duration_s: 1800}},
                 state
               )

      assert Jason.decode!(json) == %{
               "type" => "session.started",
               "call_id" => "vc_1",
               "audio_format" => "pcmu_8k",
               "max_duration_s" => 1800
             }

      {frames, _} = WebSocket.encode({:audio, :binary.copy(<<7>>, 40_000)}, state)
      assert Enum.map(frames, fn {:binary, bin} -> byte_size(bin) end) == [16_384, 16_384, 7_232]

      assert {[{:text, clear}], _} = WebSocket.encode(:clear, state)
      assert Jason.decode!(clear) == %{"type" => "output.clear"}

      assert {[{:text, mark}], _} = WebSocket.encode({:mark, "m9"}, state)
      assert Jason.decode!(mark) == %{"type" => "output.mark", "name" => "m9"}

      assert {[{:text, transcript}], _} =
               WebSocket.encode({:transcript, :agent, "Hello", true}, state)

      assert Jason.decode!(transcript) == %{
               "type" => "transcript",
               "role" => "agent",
               "text" => "Hello",
               "final" => true
             }

      assert {[{:text, ended}], _} = WebSocket.encode({:end, :busy, 0}, state)

      assert Jason.decode!(ended) == %{
               "type" => "session.ended",
               "reason" => "busy",
               "duration_s" => 0
             }

      assert {[{:text, error}], _} = WebSocket.encode({:error, 4409, "busy"}, state)
      assert Jason.decode!(error) == %{"type" => "error", "code" => 4409, "message" => "busy"}

      assert {[{:text, error}], _} = WebSocket.encode({:error, :revoked, "key revoked"}, state)
      assert %{"code" => 4401} = Jason.decode!(error)
    end

    test "close codes follow the documented table" do
      assert WebSocket.close_code(:caller_hangup) == 1000
      assert WebSocket.close_code(:max_duration) == 1000
      assert WebSocket.close_code(:too_fast) == 4400
      assert WebSocket.close_code(:revoked) == 4401
      assert WebSocket.close_code(:start_timeout) == 4408
      assert WebSocket.close_code(:idle_timeout) == 4408
      assert WebSocket.close_code(:busy) == 4409
      assert WebSocket.close_code(:slow_reader) == 4410
      assert WebSocket.close_code(:draining) == 4503
      assert WebSocket.close_code(:model_error) == 4503
    end
  end

  describe "pacing" do
    test "caller audio at real time passes; faster than 1.25x over 5 s is refused" do
      # pcmu_8k: 160 bytes per 20 ms frame.
      steady =
        Enum.reduce(0..499, {:ok, Pacing.inbound(:pcmu_8k)}, fn i, {:ok, pacer} ->
          Pacing.ingest(pacer, 160, i * 20)
        end)

      assert {:ok, _} = steady

      fast =
        Enum.reduce_while(0..499, Pacing.inbound(:pcmu_8k), fn i, pacer ->
          # 1.5x real time: a 20 ms frame every 13 ms.
          case Pacing.ingest(pacer, 160, i * 13) do
            {:ok, pacer} -> {:cont, pacer}
            {:error, :too_fast} -> {:halt, {:too_fast, i * 13}}
          end
        end)

      assert {:too_fast, at_ms} = fast
      assert at_ms >= 4_000 and at_ms <= 6_500
    end

    test "agent audio is written at most the lead ahead and a silent client is a slow reader" do
      frame = :binary.copy(<<0>>, 800)

      out =
        Enum.reduce(1..30, Pacing.outbound(:pcmu_8k), fn _, out -> Pacing.push(out, frame) end)

      # 30 x 100 ms held; only 500 ms may be written at once.
      {chunks, mark, out} = Pacing.take(out, 0)
      assert length(chunks) == 5
      assert mark == "pace:1"
      assert Pacing.held_ms(out) == 2_500
      assert {[], nil, ^out} = Pacing.take(out, 0)
      assert Pacing.next_due_ms(out, 0) == 0

      # The client confirms playback; nothing is overdue.
      out = Pacing.played(out, "pace:1", 500)
      refute Pacing.slow_reader?(out, 2_000)

      {chunks, _mark, out} = Pacing.take(out, 500)
      assert length(chunks) == 5
      # That batch is due at 1 s; without output.played past 3 s it is overdue.
      refute Pacing.slow_reader?(out, 2_900)
      assert Pacing.slow_reader?(out, 3_100)

      cleared = Pacing.clear(out, 3_100)
      assert Pacing.held_ms(cleared) == 0
      refute Pacing.slow_reader?(cleared, 10_000)
      assert Pacing.pacing_mark?("pace:3")
      refute Pacing.pacing_mark?("router-mark")
    end
  end
end
