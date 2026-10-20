defmodule SalixStore.LoopsStoreTest do
  # Shares the node-global control tables; keep serial.
  use SystemsClock.Case, async: false

  alias SalixStore.{Loops, Repo}

  setup do
    Repo.query!("TRUNCATE agent_loops, agent_loop_acks")
    :ok
  end

  defp rec(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "tenant_id" => "ten_a",
        "group_id" => "grp_a",
        "agent_id" => "agent_a",
        "session_id" => "ses_a",
        "elf_sha256" => "deadbeef",
        "elf_path" => "/loops/main.elf",
        "config" => %{"interval_ms" => 1000},
        "ifc" => %{"creator" => "comma_user|u1"},
        "created_at" => 1_000
      },
      overrides
    )
  end

  test "create is insert-once and reads back the record" do
    assert {:ok, created} = Loops.create(rec("l1"))
    assert created["status"] == "active"
    assert created["incarnation"] == 0
    assert created["elf_path"] == "/loops/main.elf"
    assert {:error, :already_exists} = Loops.create(rec("l1"))
  end

  test "owner predicates hide other owners' rows" do
    assert {:ok, _} = Loops.create(rec("l1"))
    assert {:ok, _} = Loops.get_agent_owned("l1", "agent_a")
    assert {:error, :not_found} = Loops.get_agent_owned("l1", "agent_b")
    assert {:ok, _} = Loops.get_group_owned("l1", "grp_a")
    assert {:error, :not_found} = Loops.get_group_owned("l1", "grp_b")
    assert {:error, :not_found} = Loops.delete_agent_owned("l1", "agent_b")
    assert :ok = Loops.delete_agent_owned("l1", "agent_a")
    assert {:error, :not_found} = Loops.get("l1")
  end

  test "archive transitions only touch the matching rows" do
    assert {:ok, _} = Loops.create(rec("l1"))
    assert {:ok, _} = Loops.create(rec("l2", %{"status" => "paused", "paused_by" => "user"}))
    assert {:ok, 1} = Loops.transition_by_agent("agent_a", "active", nil, "paused", "archive", 5)
    assert {:ok, l1} = Loops.get("l1")
    assert l1["status"] == "paused" and l1["paused_by"] == "archive"
    assert {:ok, 1} = Loops.transition_by_agent("agent_a", "paused", "archive", "active", nil, 6)
    assert {:ok, l2} = Loops.get("l2")
    assert l2["paused_by"] == "user"
  end

  test "acks are idempotent and pruned by age" do
    assert {:ok, _} = Loops.create(rec("l1"))
    assert :ok = Loops.settle_event("l1", 0, "e1", 100)
    assert :ok = Loops.settle_event("l1", 0, "e1", 200)
    assert Loops.acked?("l1", "e1")
    refute Loops.acked?("l1", "e2")
    assert {:ok, 1} = Loops.prune_acks(150)
    refute Loops.acked?("l1", "e1")
  end

  test "concurrent event admission enforces capacity and retries preserve the first receipt" do
    {:ok, row} = Loops.create(rec("l1"))
    event = %{"event_id" => "e1", "topic" => "mail", "payload" => %{"value" => "first"}}
    assert {:ok, %{"duplicate" => false}} = Loops.admit_event(row, event, 100, 2, 1000)

    assert {:ok, %{"duplicate" => true}} =
             Loops.admit_event(row, %{event | "payload" => %{"value" => "changed"}}, 900, 2, 1000)

    {:ok, current} = Loops.get("l1")
    assert current["pending_events"]["e1"]["payload"] == %{"value" => "first"}
    assert current["pending_events"]["e1"]["deadline_ms"] == 1100

    results =
      2..8
      |> SystemsClock.async_stream(fn n ->
        Loops.admit_event(row, %{event | "event_id" => "e#{n}"}, 100, 2, 1000)
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :mailbox_full})) == 6
    assert {:ok, [summary]} = Loops.list_by_agent("agent_a")
    assert summary["pending_events"] == nil
  end

  test "admission rechecks revoked binding and inactive state inside the transaction" do
    {:ok, row} = Loops.create(rec("l1", %{"webhook_secret" => "old"}))
    event = %{"event_id" => "e1", "topic" => "mail", "payload" => %{}}
    {:ok, _} = Loops.update("l1", &{:ok, Map.put(&1, "webhook_secret", "new")})
    assert {:error, :binding_changed} = Loops.admit_event(row, event, 1, 32, 1000)
    {:ok, _} = Loops.update("l1", &{:ok, Map.put(&1, "status", "paused")})
    assert {:error, {:not_active, "paused"}} = Loops.admit_event(row, event, 1, 32, 1000)
    assert {:ok, current} = Loops.get("l1")
    assert current["pending_events"] == %{}
  end
end
