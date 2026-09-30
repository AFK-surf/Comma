defmodule SalixStore.GuardETFTest do
  use ExUnit.Case, async: true
  alias SalixStore.{GuardETF, Codec, BoundedSnapshot}

  test "preserves all values except the two targeted event payload fields across ETF wrappers" do
    payload = %{
      "activation_key" => List.duplicate("legacy", 1000),
      "nested" => %{"activation_key" => "keep"},
      "other" => {1, 2.5, 123_456_789_012_345_678_901_234_567_890}
    }

    events =
      for kind <- ["runaway_guard_reset", "other", "runaway_unsettled_round"],
          do: %{"kind" => kind, "event" => payload, "seq" => 1}

    state = %{
      SalixAgent.InternalSession.export(SalixAgent.InternalSession.new("agent", "session"))
      | events: events,
        input_queue: [%{"activation_key" => "keep"}],
        messages: [%{content: "activation_key", raw: <<1::size(3)>>}]
    }

    expected = %{
      state
      | events:
          Enum.map(events, fn e ->
            if e["kind"] == "other",
              do: e,
              else: put_in(e["event"], Map.delete(payload, "activation_key"))
          end)
    }

    for term <- [state, {:comma_internal_session, 3, state}],
        wrapper <- [:raw, :compressed, :zstd, :gzip] do
      raw = :erlang.term_to_binary(term, minor_version: 1)

      bytes =
        case wrapper do
          :raw -> raw
          :compressed -> :erlang.term_to_binary(term, compressed: 1)
          :zstd -> Codec.encode_zstd_etf(term)
          :gzip -> :zlib.gzip(raw)
        end

      assert {:ok, inflated} = BoundedSnapshot.inflate(bytes, 1_000_000)
      assert {:ok, cleaned} = GuardETF.clean(inflated, 1_000_000)
      assert {:ok, ^expected} = Codec.decode_snapshot_bounded(cleaned, 1_000_000)
    end
  end

  test "truncated, unsupported, or oversized remaining terms fail closed" do
    raw =
      "agent"
      |> SalixAgent.InternalSession.new("session")
      |> SalixAgent.InternalSession.export()
      |> :erlang.term_to_binary()

    for n <- [0, 1, div(byte_size(raw), 2), byte_size(raw) - 1] do
      assert {:error, :invalid_snapshot} = GuardETF.clean(binary_part(raw, 0, n), 1_000_000)
    end

    assert {:error, :invalid_snapshot} = GuardETF.clean(<<131, 255>>, 1_000_000)
    assert {:error, :non_guard_oversized_snapshot} = GuardETF.clean(raw, 1)
  end
end
