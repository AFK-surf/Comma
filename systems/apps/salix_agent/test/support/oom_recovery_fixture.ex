defmodule SalixAgent.OOMRecoveryFixture do
  @moduledoc false

  # Synthetic, content-free approximation of the incident's repeated identities.
  # 3,639 resets hold 3,312,400 identity entries; identifiers are 52 bytes each.
  def build(count, compact? \\ true, message_bytes \\ 0) do
    sources = Enum.map(1..div(count + 1, 2), &String.pad_leading("source-#{&1}", 52, "0"))

    state =
      %{
        (SalixAgent.InternalSession.new("oom-rehearsal", "ses1_0000000000000000001")
         |> SalixAgent.InternalSession.export())
        | storage_format: 3
      }
      |> SalixAgent.TestSupport.SessionData.apply_event(
        delivery(1, String.duplicate("x", message_bytes))
      )

    state =
      Enum.reduce(1..count, state, fn n, acc ->
        SalixAgent.TestSupport.SessionData.apply_event(acc, %{
          "type" => "session_event",
          "event_id" => "legacy-reset-#{n}",
          "kind" => "runaway_guard_reset",
          "event" => %{"activation_key" => Enum.take(sources, div(n + 1, 2))},
          "created_at" => n
        })
      end)

    state =
      if compact? do
        SalixAgent.TestSupport.SessionData.apply_event(state, %{
          "type" => "compaction",
          "compacted_through" => 1,
          "compacted_seq" => state.last_seq,
          "summary_sequence" => 1,
          "summary" => "Synthetic history summarized; retain all original archive facts."
        })
      else
        state
      end

    state =
      SalixAgent.TestSupport.SessionData.apply_event(state, %{
        "type" => "ack",
        "last_ack_message_id" => 1
      })

    # This accepted, uncompacted input must survive repair and remain wakeable.
    state =
      SalixAgent.TestSupport.SessionData.apply_event(state, delivery(2, "Unprocessed live input"))

    state =
      SalixAgent.TestSupport.SessionData.apply_event(state, %{
        "type" => "session_event",
        "event_id" => "live-unsettled",
        "kind" => "runaway_unsettled_round",
        "event" => %{},
        "created_at" => count + 1
      })

    state =
      SalixAgent.TestSupport.SessionData.apply_event(state, %{
        "type" => "queue_append",
        "kind" => "user_message",
        "queue_id" => 1,
        "wake" => true,
        "payload" => %{"source_message_id" => "queued-source", "content" => "Pending queue input"}
      })

    SalixAgent.TestSupport.SessionData.normalize(%{
      state
      | runtime_epoch: 7,
        work_index_token: "preserved-work"
    })
  end

  defp delivery(id, content) do
    %{
      "type" => "delivery",
      "from_queue" => true,
      "message_id" => id,
      "role" => "user",
      "content" => content,
      "source_message_id" => "source-#{id}",
      "created_at" => id
    }
  end
end
