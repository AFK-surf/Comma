defmodule SalixAgent.DeliveredAtStampTest do
  @moduledoc """
  The optional `delivered_at_ms` arrival stamp survives the queue: a
  `queue_append` payload carrying it materializes into a transcript message
  that carries it, and one without it materializes exactly as before.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.InternalSession.State
  alias SalixAgent.InternalSessionStore

  @session "ses1_0000000000000000777"

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_store, :s3_backend, prev),
        else: Application.delete_env(:salix_store, :s3_backend)
    end)

    :ok
  end

  defp queue_append(source_id, payload_extra) do
    %{
      "type" => "queue_append",
      "session_id" => @session,
      "kind" => "user_message",
      "dedupe_key" => source_id,
      "payload" =>
        Map.merge(%{"source_message_id" => source_id, "content" => "hello"}, payload_extra)
    }
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  test "a stamped queue item materializes into a stamped message; an unstamped one stays bare" do
    agent_id = SalixAgent.TestSupport.new_agent_id()

    {:ok, state} =
      InternalSessionStore.prepare_commit(agent_id, @session, [
        %{"type" => "session_created", "session_id" => @session},
        queue_append("stamped", %{"delivered_at_ms" => 1_725_000_000_123}),
        queue_append("bare", %{})
      ])

    {events, _wake?, _hwm} = SalixAgent.InternalSession.materialize_pending_input_events(state)

    deliveries = Enum.filter(events, &(&1["type"] == "delivery"))
    assert length(deliveries) == 2

    stamped = Enum.find(deliveries, &(&1["source_message_id"] == "stamped"))
    bare = Enum.find(deliveries, &(&1["source_message_id"] == "bare"))
    assert stamped["delivered_at_ms"] == 1_725_000_000_123
    refute Map.has_key?(bare, "delivered_at_ms")

    {:ok, _} = InternalSessionStore.prepare_commit(agent_id, @session, events)
    {:ok, session} = InternalSessionStore.read(agent_id, @session)

    by_source =
      Map.new(
        SalixAgent.InternalSession.get(session, :messages),
        &{field(&1, :source_message_id), &1}
      )

    assert field(by_source["stamped"], :delivered_at_ms) == 1_725_000_000_123
    assert field(by_source["bare"], :delivered_at_ms) == nil
  end
end
