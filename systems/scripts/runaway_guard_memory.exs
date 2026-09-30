# Synthetic reducer/codec comparison; no network, actors, or online data.
# Run from systems: MIX_ENV=test mix run --no-start scripts/runaway_guard_memory.exs
# Legacy refers to the former event payload shape, not an old runtime binary.
alias SalixAgent.InternalSession
alias SalixStore.Codec

for rounds <- [200, 400, 800] do
  for shape <- [:legacy, :counter] do
    session = InternalSession.new("memory-test", "ses1_0000000000000000900", %{})

    session =
      Enum.reduce(1..rounds, session, fn i, session ->
        session =
          InternalSession.apply_event(session, %{
            "type" => "delivery",
            "from_queue" => true,
            "message_id" => i,
            "role" => "user",
            "content" => "input",
            "source_message_id" => "source-" <> String.pad_leading(Integer.to_string(i), 40, "0")
          })

        payload = %{"assistant_message_id" => i + 1, "tool_call_count" => 1}

        payload =
          if shape == :legacy,
            do:
              Map.put(payload, "activation_key", InternalSession.current_activation_key(session)),
            else: payload

        InternalSession.apply_event(session, %{
          "type" => "session_event",
          "kind" => "runaway_guard_reset",
          "event_id" => "reset-#{i}",
          "event" => payload
        })
      end)

    snapshot = session |> InternalSession.persist() |> Codec.compress_snapshot_etf()

    {decode_us, {:ok, restored}} =
      :timer.tc(fn -> snapshot |> Codec.snapshot_etf() |> InternalSession.load() end)

    events = InternalSession.get(restored, :events)

    IO.inspect(%{
      shape: shape,
      rounds: rounds,
      guard_etf_bytes: byte_size(:erlang.term_to_binary(events)),
      guard_flat_bytes: :erts_debug.flat_size(events) * :erlang.system_info(:wordsize),
      current_sources: length(InternalSession.get(restored, :active_source_message_ids)),
      snapshot_bytes: byte_size(snapshot),
      decode_us: decode_us,
      count: InternalSession.consecutive_unsettled_rounds(restored)
    })
  end
end
