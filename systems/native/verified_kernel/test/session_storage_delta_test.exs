defmodule SalixVerifiedKernel.SessionStorageDeltaTest do
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.Session

  defp session(patch \\ %{}) do
    Session.new("agent", "ses1_0000000000000000001", %{created_at: 1})
    |> Session.export()
    |> Map.merge(patch)
    |> Session.open()
  end

  defp write(cursor, events, hwm \\ nil),
    do: Session.write_revision(cursor, events, hwm, fn _, _ -> :ok end)

  defp delta(cursor) do
    assert {:ok, delta} = Session.revision_delta(cursor)
    delta
  end

  test "a live commit and PG restore adopt the same assistant provider state" do
    providers = %{"condensed_workspace" => %{"revision" => "rev1"}}

    committed =
      session()
      |> Session.start_revision(1)
      |> write([
        %{
          "type" => "assistant",
          "message_id" => 1,
          "content" => "accepted",
          "do_not_send_to_llm" => %{"context_provider_states" => providers}
        }
      ])
      |> Session.commit_revision_delta({2, %{}})

    {live, 2, false} = Session.revision_view(committed)
    {:ok, stored} = live |> Session.persist() |> Session.admit()
    {:ok, restored} = Session.lifecycle(stored, :restore_pg)

    assert Session.query(restored, :provider_states) == providers
    assert Session.query(live, :provider_states) == providers
  end

  test "a control change has the same payload with ten times the history and prompt" do
    deltas =
      for count <- [10, 100] do
        messages = Enum.map(1..count, &%{id: &1, seq: &1, role: "assistant", content: "old"})

        session(%{
          messages: messages,
          last_seq: count,
          next_message_id: count + 1,
          system_prompt: String.duplicate("context", count)
        })
        |> Session.start_revision(1)
        |> write([%{"type" => "session_update", "name" => "renamed"}])
        |> delta()
      end

    assert [same, same] = deltas
    assert same["columns"] == %{"name" => "renamed"}
    assert same["records"] == []
    assert same["context"] == nil
    assert byte_size(:erlang.term_to_binary(same)) < 1_024
  end

  test "queue consume removes one materialized input without crossing an unconsumed input" do
    item = fn id ->
      %{
        "queue_id" => id,
        "kind" => "user_message",
        "dedupe_key" => "input-#{id}",
        "wake" => true,
        "payload" => %{"source_message_id" => "input-#{id}", "content" => "body"}
      }
    end

    cursor =
      session(%{input_queue: Enum.map(1..3, item), next_queue_id: 4})
      |> Session.start_revision(7)
      |> write([
        %{
          "type" => "delivery",
          "from_queue" => true,
          "message_id" => 1,
          "source_message_id" => "input-2",
          "content" => "body",
          "role" => "user",
          "accepted_input" => {2, "user_message", "input-2", item.(2)["payload"]}
        },
        %{"type" => "queue_consume", "queue_id" => 2}
      ])

    delta = delta(cursor)
    assert delta["inputs_remove"] == [2]
    refute Map.has_key?(delta["columns"], "queue_ack_id")
    assert [%{"seq" => 1, "kind" => "message", "payload" => payload}] = delta["records"]
    assert payload.accepted_input == {2, "user_message", "input-2", item.(2)["payload"]}
    {working, 7, true} = Session.revision_view(cursor)
    assert Enum.map(Session.get(working, :input_queue), & &1["queue_id"]) == [1, 3]
    assert Session.get(working, :queue_ack_id) == 0
  end

  test "a pending input keeps every alias and queue id after immediate materialization" do
    appended =
      session()
      |> Session.start_revision(3)
      |> write([
        %{
          "type" => "queue_append",
          "kind" => "user_message",
          "dedupe_key" => "primary",
          "source_message_id" => "event-alias",
          "created_at" => 1,
          "payload" => %{"source_message_id" => "payload-alias", "content" => "body"}
        }
      ])

    {working, 3, true} = Session.revision_view(appended)
    {events, true, hwm} = Session.query(working, :materialize_pending_input_events)
    cursor = write(appended, events, hwm)
    delta = delta(cursor)

    assert delta["inputs_put"] == []
    assert delta["inputs_remove"] == []

    assert Enum.sort(delta["dedupe_add"]) ==
             Enum.sort([{"primary", 1}, {"event-alias", 1}, {"payload-alias", 1}])

    assert [%{"seq" => 1, "payload" => %{accepted_input: {1, "user_message", "primary", _}}}] =
             delta["records"]

    assert delta["columns"]["queue_ack_id"] == 1
  end

  test "callback control keeps its record reference without duplicating the result body" do
    started =
      session()
      |> Session.apply_batch([
        %{
          "type" => "async_tool_call_started",
          "tool_call_id" => "call",
          "tool_name" => "lookup",
          "completion_mode" => "external_callback",
          "capability_request_id" => "request"
        }
      ])

    delta =
      started
      |> Session.start_revision(2)
      |> write([
        %{
          "type" => "async_tool_call_completed",
          "tool_call_id" => "call",
          "completed_at" => 100,
          "result" => %{"content" => "unique result body"}
        }
      ])
      |> delta()

    assert [%{"kind" => "async_result", "record_id" => "call", "payload" => record}] =
             delta["records"]

    assert record["result"] == %{"content" => "unique result body"}

    assert %{"record_seq" => 1, "pending" => pending} =
             delta["control_put"]["async_tool_calls"]["call"]

    assert pending["capability_request_id"] == "request"
    assert pending["capability_retry_at_ms"] == 100
  end
end
