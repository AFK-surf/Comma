defmodule SalixVerifiedKernel.Test.ActivationFixture do
  @moduledoc """
  Synthetic long-history activation input. No staging payloads or identifiers.
  The incident had about 3,900 messages, 16 MB of state and 600 result references.
  References remain protected by JSON transcript content after compaction.
  """
  alias SalixVerifiedKernel.Session

  def build(agent_id, session_id, opts \\ []) do
    count = Keyword.get(opts, :messages, 4_000)
    refs = Keyword.get(opts, :refs, 600)
    padding = String.duplicate("x", Keyword.get(opts, :padding, 4_000))
    compacted = 24_000

    messages =
      for id <- 1..count do
        ref = ref(rem(id - 1, refs) + 1)

        %{
          id: id,
          seq: compacted + id,
          role: "user",
          no_wake: true,
          source_message_id: "synthetic-history-#{id}",
          created_at: 1_700_000_000,
          content: ~s({"result_ref":"#{ref}","padding":"#{padding}"})
        }
      end

    Session.new(agent_id, session_id)
    |> Session.export()
    |> Map.merge(%{
      messages: messages,
      last_ack_message_id: count,
      next_message_id: count + 1,
      last_seq: compacted + count,
      compacted_seq: compacted,
      summary: "Synthetic compacted history. No external data.",
      async_result_refs: Map.new(1..refs, &{ref(&1), &1}),
      status: :idle,
      activity_status: :idle
    })
    |> Session.open()
  end

  def ref(id), do: "trf1_" <> String.pad_leading(Integer.to_string(id), 19, "0")

  def queue_event(session_id) do
    %{
      "type" => "queue_append",
      "session_id" => session_id,
      "kind" => "user_message",
      "wake" => true,
      "payload" => %{
        "source_message_id" => "synthetic-wake",
        "role" => "user",
        "content" => "Answer this new input."
      }
    }
  end

  def apply_events(session, events), do: Enum.reduce(events, session, &step(&2, &1))

  defp step(session, event) do
    finish(Session.step(session, event))
  end

  defp finish({:done, next}), do: next

  defp finish({:observe_time, token}),
    do: finish(Session.step(token, {:observed_time, 1_700_000_001}))

  defp finish({:observe_config, _app, _key, default, token}),
    do: finish(Session.step(token, {:observed_config, default}))
end
