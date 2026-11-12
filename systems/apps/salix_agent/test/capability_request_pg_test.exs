defmodule SalixAgent.CapabilityRequestPGTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixAgent.{CapabilityRequests, TestSupport}
  alias SalixAgent.CapabilityRequestStore.PG
  alias SalixStore.{Ids, Repo, S3}

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    Repo.query!("TRUNCATE salix_capability_requests")
    source = TestSupport.create_control_agent!(TestSupport.new_agent_id())

    on_exit(fn ->
      TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
    end)

    {:ok, source: source}
  end

  test "SQL lists preserve ordering, all pending pages, and the expired-pending complement",
       ctx do
    pending =
      for i <- 1..101 do
        record = record(ctx, "pending-#{String.pad_leading(to_string(i), 3, "0")}")
        record = Map.merge(record, %{"updated_at" => rem(i, 3) - 1, "created_at" => nil})
        assert {:ok, _} = PG.execute(PG.prepare_insert(record))
        record
      end

    expired = Map.merge(record(ctx, "expired"), %{"expires_at" => 1, "updated_at" => 999})

    completed =
      Map.merge(record(ctx, "finished"), %{"status" => "completed", "updated_at" => 1_000})

    elsewhere =
      Map.merge(record(ctx, "elsewhere"), %{
        "surface_ref" => %{"conversation_id" => "other"},
        "updated_at" => -1_000
      })

    for rec <- [expired, completed, elsewhere],
        do: assert({:ok, _} = PG.execute(PG.prepare_insert(rec)))

    expected =
      Enum.sort_by(
        pending,
        &{&1["updated_at"] || 0, &1["created_at"] || 0, &1["request_id"]},
        :desc
      )

    assert {:ok, ^expected} =
             CapabilityRequests.list_conversation(group(ctx), tenant(ctx), "conversation",
               limit: 1
             )

    assert {:ok, all} =
             CapabilityRequests.list_conversation(group(ctx), tenant(ctx), "conversation",
               limit: 103
             )

    assert all == expected ++ [completed, expired]

    assert {:ok, [^completed, ^expired]} =
             CapabilityRequests.list_group(group(ctx), tenant(ctx), status: "", limit: 2)

    assert {:ok, active} =
             CapabilityRequests.list_group(group(ctx), tenant(ctx), status: "pending", limit: 500)

    refute Enum.any?(active, &(&1["request_id"] == "expired"))

    missing = record(ctx, "missing-time") |> Map.delete("created_at") |> Map.delete("updated_at")
    assert {:ok, _} = PG.execute(PG.prepare_insert(missing))

    assert %{rows: [[nil, nil]]} =
             Repo.query!(
               "SELECT created_at,updated_at FROM salix_capability_requests WHERE group_id=$1 AND request_id=$2",
               [group(ctx), "missing-time"]
             )
  end

  test "one Conversation list classifies a request once across a concurrent completion", ctx do
    initial = record(ctx, "moving")
    assert {:ok, row} = PG.execute(PG.prepare_insert(initial))
    owner = self()
    handler = {__MODULE__, make_ref()}
    group_id = group(ctx)

    :telemetry.attach(
      handler,
      [:salix_store, :repo, :query],
      fn _, _, metadata, _ ->
        if List.first(metadata.params || []) == group_id and
             String.contains?(metadata.query, "surface_kind='conversation'") and
             Process.get(handler) != true do
          Process.put(handler, true)
          send(owner, {:pending_page_read, self()})
          receive do: (:continue_list -> :ok)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    reading =
      SystemsRuntime.Task.async(fn ->
        CapabilityRequests.list_conversation(group(ctx), tenant(ctx), "conversation", limit: 2)
      end)

    settle_receive({:pending_page_read, reader})
    completed = Map.merge(initial, %{"status" => "completed", "result" => %{"content" => "done"}})
    assert {:ok, _} = PG.execute(PG.prepare_update(row, completed))
    send(reader, :continue_list)
    :telemetry.detach(handler)
    assert {:ok, [^initial]} = settled_await(reading)

    assert {:ok, [^completed]} =
             CapabilityRequests.list_conversation(group(ctx), tenant(ctx), "conversation",
               limit: 2
             )
  end

  test "one revision wins completion versus expiry and its exact result remains due", ctx do
    initial = record(ctx, "race")
    assert {:ok, row} = PG.execute(PG.prepare_insert(initial))

    candidates =
      for status <- ["completed", "expired"] do
        result = %{"status" => status, "content" => "frozen-" <> status}
        PG.prepare_update(row, Map.merge(initial, %{"status" => status, "result" => result}))
      end

    tasks =
      Enum.map(candidates, fn pending ->
        SystemsRuntime.Task.async(fn -> PG.execute(pending) end)
      end)

    results = Enum.map(tasks, &settled_await/1)
    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, :precondition_failed}] = Enum.filter(results, &match?({:error, _}, &1))
    assert winner.record["result"]["content"] == "frozen-" <> winner.record["status"]
    refute is_nil(winner.due_at)
    assert is_nil(winner.delivered_at)
    assert {:ok, due} = PG.page_result_delivery(limit: 1)
    assert Enum.any?(due.items, &(&1.record["request_id"] == "race"))
  end

  test "lost mutation and delivery ACK replies settle without replacing the stored result", ctx do
    initial = record(ctx, "lost-reply")
    assert {:ok, row} = PG.execute(PG.prepare_insert(initial))
    result = %{"status" => "completed", "content" => "same result"}

    pending =
      PG.prepare_update(row, Map.merge(initial, %{"status" => "completed", "result" => result}))

    Repo.query!(pending.sql, pending.params)
    assert {:ok, settled} = PG.settle(pending)
    assert settled.record["result"] == result
    ack = PG.prepare_delivery_ack(settled)
    Repo.query!(ack.sql, ack.params)
    assert {:ok, delivered} = PG.settle(ack)
    assert delivered.record == settled.record
    assert is_nil(delivered.due_at)
    refute is_nil(delivered.delivered_at)
    assert :ok = PG.acknowledge_delivery(settled.record)
  end

  test "tool identity finds explicit ids, cancellation has no due delivery, and expiry pages are bounded",
       ctx do
    attrs = %{
      "request_id" => "explicit-request",
      "source_agent_id" => ctx.source["agent_id"],
      "source_session_id" => Ids.new_session_id(),
      "tool_call_id" => "same-tool",
      "request_type" => "location",
      "request_payload" => %{},
      "expires_at" => now() + 120
    }

    assert {:ok, request} = CapabilityRequests.create_capability_request(attrs)

    assert CapabilityRequests.pending_capability_request?(
             request["source_agent_id"],
             request["source_session_id"],
             request["tool_call_id"]
           )

    assert {:ok, cancelled} =
             CapabilityRequests.cancel_capability_request(
               request["source_agent_id"],
               request["source_session_id"],
               request["tool_call_id"],
               "stopped"
             )

    assert cancelled["status"] == "cancelled"

    assert :ok =
             CapabilityRequests.retry_result_delivery(
               group(ctx),
               request["request_id"],
               tenant(ctx)
             )

    assert {:ok, row} = PG.read(group(ctx), request["request_id"])
    assert is_nil(row.due_at)
    assert is_nil(row.delivered_at)

    for id <- ["expired-a", "expired-b"] do
      assert {:ok, _} = PG.execute(PG.prepare_insert(Map.put(record(ctx, id), "expires_at", 1)))
    end

    assert {:ok, %{items: [first], next: cursor}} =
             CapabilityRequests.due_location_requests(limit: 1)

    assert {:ok, %{items: [second]}} =
             CapabilityRequests.due_location_requests(limit: 1, cursor: cursor)

    refute first.record["request_id"] == second.record["request_id"]
  end

  test "IFC decision with lost acknowledgement never grants a recovery receipt", ctx do
    initial =
      record(ctx, "ifc-unknown")
      |> Map.merge(%{
        "request_type" => "ifc_declassify",
        "request_payload" => %{
          "ifc_declassify" => %{
            "requester" => "provider_user|cnx1|U_A",
            "source_atoms" => ["scope|cnx1|@U_A"],
            "destination_atoms" => ["space|cnx1"],
            "summary" => "share a fact"
          }
        }
      })

    assert {:ok, row} = PG.execute(PG.prepare_insert(initial))

    decided =
      Map.merge(initial, %{
        "status" => "completed",
        "response_payload" => %{"approved" => true},
        "settlement_deadline_ms" => SystemsClock.system_time(:millisecond) + 30_000
      })

    pending = PG.prepare_update(row, decided)
    Repo.query!(pending.sql, pending.params)

    assert {:error, {:conflict, :already_settled}} =
             CapabilityRequests.decide_declassification(
               group(ctx),
               initial["request_id"],
               %{"approved" => true},
               tenant(ctx)
             )

    assert {:ok, before_deadline} = reconcile(decided)
    refute is_map(before_deadline["result"])
    SystemsClock.advance(30_000)
    assert {:ok, after_deadline} = reconcile(decided)
    assert after_deadline["result"]["error_class"] == "capability_receipt_result_unknown"

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM ifc_receipts WHERE group_id=$1", [group(ctx)])
  end

  defp reconcile(request) do
    CapabilityRequests.reconcile_capability_request(
      request["source_agent_id"],
      request["source_session_id"],
      request["tool_call_id"]
    )
  end

  defp record(ctx, id) do
    %{
      "group_id" => group(ctx),
      "tenant_id" => tenant(ctx),
      "request_id" => id,
      "source_agent_id" => ctx.source["agent_id"],
      "source_session_id" => Ids.new_session_id(),
      "tool_call_id" => "tool-" <> id,
      "request_type" => "location",
      "status" => "pending",
      "expires_at" => now() + 120,
      "created_at" => now(),
      "updated_at" => now(),
      "request_payload" => %{},
      "response_payload" => %{},
      "surface_kind" => "conversation",
      "surface_ref" => %{"conversation_id" => "conversation"}
    }
  end

  defp group(ctx), do: ctx.source["group_id"]
  defp tenant(ctx), do: ctx.source["tenant_id"]
  defp now, do: SystemsClock.system_time(:second)
end
