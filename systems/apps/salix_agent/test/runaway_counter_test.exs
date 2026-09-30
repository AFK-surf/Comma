defmodule SalixAgent.RunawayCounterTest do
  use ExUnit.Case, async: true

  alias SalixAgent.InternalSession
  alias SalixAgent.TestSupport.SessionData
  alias SalixStore.Codec

  defp base do
    "agent-counter"
    |> InternalSession.new("ses1_0000000000000000900", %{})
    |> InternalSession.export()
  end

  defp input(id, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "delivery",
        "from_queue" => true,
        "message_id" => id,
        "role" => "user",
        "source_message_id" => "src-#{id}",
        "content" => "input"
      },
      attrs
    )
  end

  defp fact(kind, payload \\ %{}) do
    %{
      "type" => "session_event",
      "event_id" => "guard-#{System.unique_integer([:positive])}",
      "kind" => kind,
      "event" => payload
    }
  end

  defp unsettled, do: fact("runaway_unsettled_round")
  defp reset, do: fact("runaway_guard_reset")

  defp reload(state), do: state |> InternalSession.open() |> InternalSession.persist() |> load()

  defp load(bytes) do
    {:ok, session} = InternalSession.load(bytes)
    InternalSession.export(session)
  end

  test "counter survives reload and hot-window removal without any input identity" do
    state = SessionData.apply_events(base(), [input(1), unsettled(), unsettled()])
    assert state.runaway_unsettled_streak == %{"count" => 2}

    archived =
      reload(%{
        state
        | messages: [],
          events: [],
          compacted_seq: state.last_seq,
          archived_through: state.last_seq,
          active_source_message_ids: []
      })

    assert SessionData.query(archived, :consecutive_unsettled_rounds) == 2

    assert SessionData.apply_event(archived, unsettled()).runaway_unsettled_streak ==
             %{"count" => 3}
  end

  test "fresh user and runtime input reset, but no-wake input and stale ACK do not" do
    state = SessionData.apply_events(base(), [input(1), unsettled(), unsettled()])
    quiet = SessionData.apply_event(state, input(2, %{"no_wake" => true}))
    assert SessionData.query(quiet, :consecutive_unsettled_rounds) == 2

    stale = SessionData.apply_event(quiet, %{"type" => "ack", "last_ack_message_id" => 0})

    assert SessionData.query(stale, :consecutive_unsettled_rounds) == 2

    assert SessionData.query(
             SessionData.apply_event(stale, input(3)),
             :consecutive_unsettled_rounds
           ) == 0

    runtime =
      SessionData.apply_event(stale, %{
        "type" => "runtime_message",
        "from_queue" => true,
        "message_id" => 3,
        "runtime_message_id" => "rt-new",
        "runtime_message_type" => "wait_timeout"
      })

    assert SessionData.query(runtime, :consecutive_unsettled_rounds) == 0

    assert SessionData.query(
             SessionData.apply_event(stale, reset()),
             :consecutive_unsettled_rounds
           ) == 0

    acked = SessionData.apply_event(stale, %{"type" => "ack", "last_ack_message_id" => 2})

    assert SessionData.query(acked, :consecutive_unsettled_rounds) == 0
    assert SessionData.query(acked, :current_activation_key, []) == []
  end

  test "legacy snapshot keeps readable count and archived source routing, not its control key" do
    legacy = %{
      SessionData.apply_event(base(), input(1))
      | messages: [],
        runaway_unsettled_streak: %{"key" => ["src-1"], "count" => 2}
    }

    # An ETF struct written before this release does not have the new status field.
    loaded =
      legacy
      |> Map.delete(:active_source_message_ids)
      |> Codec.encode_snapshot()
      |> Codec.snapshot_etf()
      |> load()

    assert loaded.runaway_unsettled_streak == %{"count" => 2}
    assert SessionData.query(loaded, :current_activation_key, []) == ["src-1"]
    continued = SessionData.apply_event(loaded, unsettled()) |> reload()
    assert SessionData.query(continued, :consecutive_unsettled_rounds) == 3
    assert SessionData.query(continued, :current_activation_key, []) == ["src-1"]

    stale = %{
      SessionData.apply_event(base(), input(1))
      | runaway_unsettled_streak: %{"key" => ["old-source"], "count" => 8}
    }

    assert SessionData.query(reload(stale), :consecutive_unsettled_rounds) == 0
  end

  test "legacy event replay ignores keys without rewriting historical facts" do
    old =
      fact("runaway_unsettled_round", %{
        "activation_key" => ["src-1"],
        "assistant_message_id" => 2
      })

    old_reset =
      fact("runaway_guard_reset", %{"activation_key" => ["src-1"], "tool_call_count" => 1})

    state =
      SessionData.apply_events(base(), [input(1), old, old, old_reset, old])
      |> reload()

    assert state.runaway_unsettled_streak == %{"count" => 1}
    assert Enum.all?(state.events, &(&1["event"]["activation_key"] == ["src-1"]))

    assert SessionData.query(
             SessionData.apply_event(state, unsettled()),
             :consecutive_unsettled_rounds
           ) == 2
  end

  test "guard storage grows with rounds, not rounds times source cardinality" do
    sample = fn rounds, source_count ->
      state = SessionData.apply_event(base(), input(1))
      # One current source scope is allowed for Slack status, never one per round.
      state = %{
        state
        | messages: [],
          active_source_message_ids: Enum.map(1..source_count, &"source-#{&1}")
      }

      state =
        SessionData.apply_events(
          state,
          Enum.map(1..rounds, fn i -> Map.put(reset(), "event_id", "guard-#{i}") end)
        )

      decoded = reload(state)
      assert decoded.runaway_unsettled_streak == %{"count" => 0}
      assert length(decoded.active_source_message_ids) == source_count

      {byte_size(:erlang.term_to_binary(decoded.events)),
       :erts_debug.flat_size(decoded.events) * :erlang.system_info(:wordsize)}
    end

    {small_bytes, small_heap} = sample.(200, 10)
    {wide_bytes, wide_heap} = sample.(200, 1_000)
    {long_bytes, long_heap} = sample.(400, 1_000)
    assert wide_bytes < small_bytes * 1.1
    assert wide_heap == small_heap
    assert long_bytes < wide_bytes * 2.1
    assert long_heap < wide_heap * 2.1
  end
end
