defmodule SalixVoice.Carrier.WebSocketTest do
  use SystemsClock.Case, async: true

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
    test "caller audio at real time passes; sustained 1.5x real time is refused" do
      # pcmu_8k: 160 bytes per 20 ms frame.
      steady =
        Enum.reduce(0..2_999, {:ok, Pacing.inbound(:pcmu_8k)}, fn i, {:ok, pacer} ->
          Pacing.ingest(pacer, 160, i * 20)
        end)

      assert {:ok, _} = steady

      fast =
        Enum.reduce_while(0..2_999, Pacing.inbound(:pcmu_8k), fn i, pacer ->
          # 1.5x real time: a 20 ms frame every 13 ms.
          case Pacing.ingest(pacer, 160, i * 13) do
            {:ok, pacer} -> {:cont, pacer}
            {:error, :too_fast} -> {:halt, {:too_fast, i * 13}}
          end
        end)

      # 5 s of credit spent at 0.25 s per second.
      assert {:too_fast, at_ms} = fast
      assert at_ms >= 15_000 and at_ms <= 20_000
    end

    test "buffered caller audio after a network stall is a catch-up, not too fast" do
      frames = fn pacer, range, at -> Enum.reduce(range, pacer, &ok!(&2, 160, at.(&1))) end

      # 8 s at real time, nothing for 2 s, then the 2 s held in the client's
      # send buffer in one burst, then real time again for 20 s.
      pacer = frames.(Pacing.inbound(:pcmu_8k), 0..399, &(&1 * 20))
      pacer = frames.(pacer, 400..499, fn _ -> 10_000 end)
      pacer = frames.(pacer, 500..1_499, &(&1 * 20))

      # A 4 s stall later in the call, such as a grown Android TCP send
      # buffer, is tolerated the same way.
      pacer = frames.(pacer, 1_500..1_699, fn _ -> 34_000 end)
      _pacer = frames.(pacer, 1_700..2_699, &(&1 * 20))

      # More than 5 s at once is refused.
      assert {:error, :too_fast} = Pacing.ingest(Pacing.inbound(:pcmu_8k), 40_001, 0)
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
      # That batch is due at 1 s; without output.played past 9 s it is overdue.
      refute Pacing.slow_reader?(out, 8_900)
      assert Pacing.slow_reader?(out, 9_100)

      # The threshold is an option.
      strict = Pacing.outbound(:pcmu_8k, slow_reader_ms: 2_000) |> Pacing.push(frame)
      {_chunks, _mark, strict} = Pacing.take(strict, 0)
      refute Pacing.slow_reader?(strict, 2_100)
      assert Pacing.slow_reader?(strict, 2_200)

      cleared = Pacing.clear(out, 9_100)
      assert Pacing.held_ms(cleared) == 0
      refute Pacing.slow_reader?(cleared, 10_000)
      assert Pacing.pacing_mark?("pace:3")
      refute Pacing.pacing_mark?("router-mark")
    end

    test "a 3 s downlink stall followed by on-time confirmations is not a slow reader" do
      frame = :binary.copy(<<0>>, 800)

      out =
        Enum.reduce(1..100, Pacing.outbound(:pcmu_8k), fn _, out -> Pacing.push(out, frame) end)

      # The socket keeps writing on schedule while the client receives nothing.
      out =
        Enum.reduce(0..3_000//100, out, fn now, out ->
          {_chunks, _mark, out} = Pacing.take(out, now)
          refute Pacing.slow_reader?(out, now)
          out
        end)

      assert %{oldest_mark: {1, 500}, pending_marks: pending} = Pacing.diagnostics(out, 3_100)
      assert pending > 1

      # The stalled bytes arrive; the client plays them and confirms each mark.
      out =
        Enum.reduce(1..out.mark_seq, out, &Pacing.played(&2, "pace:#{&1}", 3_100 + &1))

      refute Pacing.slow_reader?(out, 3_200)
      assert Pacing.diagnostics(out, 3_200).pending_marks == 0

      # Confirmations that never arrive are a slow reader after 8 s.
      {_chunks, "pace:" <> _, out} = Pacing.take(out, 3_200)
      deadline = out.deadline_ms
      refute Pacing.slow_reader?(out, deadline + 8_000)
      assert Pacing.slow_reader(out, deadline + 8_001) == :mark_overdue
    end

    test "two 3 s downlink stalls in one agent turn add up but stay under the threshold" do
      frame = :binary.copy(<<0>>, 800)

      out =
        Enum.reduce(1..300, Pacing.outbound(:pcmu_8k), fn _, out -> Pacing.push(out, frame) end)

      # Stalls start at 5 s and 12 s. The client plays at real time, so each
      # stall leaves its playback 3 s further behind the write schedule.
      lag = fn deadline ->
        cond do
          deadline <= 5_000 -> 0
          deadline <= 12_000 -> 3_000
          true -> 6_000
        end
      end

      {out, max_overdue} =
        Enum.reduce(0..20_000//100, {out, 0}, fn now, {out, max_overdue} ->
          {_chunks, _mark, out} = Pacing.take(out, now)

          out =
            out.marks
            |> :queue.to_list()
            |> Enum.filter(fn {_name, deadline} -> deadline + lag.(deadline) <= now end)
            |> Enum.reduce(out, fn {name, _deadline}, out -> Pacing.played(out, name, now) end)

          refute Pacing.slow_reader?(out, now)

          overdue =
            case Pacing.diagnostics(out, now).oldest_mark do
              {_seq, deadline} -> now - deadline
              nil -> 0
            end

          {out, max(max_overdue, overdue)}
        end)

      # Past the old 2 s threshold, within the 8 s one.
      assert max_overdue > 5_000 and max_overdue <= 6_000
      assert Pacing.diagnostics(out, 20_000).pending_marks > 0
    end

    test "a slow reader reports its cause, the oldest mark and a bounded trail" do
      frame = :binary.copy(<<0>>, 800)

      out =
        Enum.reduce(1..10, Pacing.outbound(:pcmu_8k), fn _, out -> Pacing.push(out, frame) end)

      {_chunks, "pace:1", out} = Pacing.take(out, 0)
      out = out |> Pacing.played("pace:1", 480) |> Pacing.played("pace:9", 490)
      {_chunks, "pace:2", out} = Pacing.take(out, 500)

      assert %{
               cause: :mark_overdue,
               held_ms: 0,
               oldest_mark: {2, 1_000},
               pending_marks: 1,
               last_sent_seq: 2,
               last_played: {1, 480},
               trail: [
                 {:mark, 1, 0, 500, 500},
                 {:played, 1, 480, true},
                 {:played, 9, 490, false},
                 {:mark, 2, 500, 1_000, 500}
               ]
             } = Pacing.diagnostics(out, 9_100)

      cleared = Pacing.clear(out, 9_200)

      assert %{cause: nil, last_played: {1, 480}, trail: trail} =
               Pacing.diagnostics(cleared, 9_300)

      assert List.last(trail) == {:clear, 1, 9_200}

      # A model burst beyond the memory bound is the other cause.
      held =
        Pacing.push(Pacing.outbound(:pcmu_8k, max_held_ms: 1_000), :binary.copy(<<0>>, 8_800))

      assert Pacing.slow_reader(held, 0) == :held_limit

      # The trail keeps only the last 80 events.
      chatty = Enum.reduce(1..200, cleared, fn i, out -> Pacing.played(out, "pace:x", i) end)
      assert length(Pacing.diagnostics(chatty, 0).trail) == 80
    end
  end

  defp ok!(pacer, bytes, now_ms) do
    assert {:ok, pacer} = Pacing.ingest(pacer, bytes, now_ms)
    pacer
  end
end
