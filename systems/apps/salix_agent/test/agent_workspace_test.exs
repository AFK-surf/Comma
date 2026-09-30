defmodule SalixAgent.AgentWorkspaceTest do
  use ExUnit.Case, async: false

  alias SalixAgent.AgentWorkspace
  alias SalixStore.S3

  @hour 60 * 60
  @now 1_800_000_000

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    case Process.whereis(S3.Fake) do
      nil -> start_supervised!(S3.Fake)
      _pid -> S3.Fake.reset()
    end

    on_exit(fn ->
      if is_nil(previous_backend),
        do: Application.delete_env(:salix_store, :s3_backend),
        else: Application.put_env(:salix_store, :s3_backend, previous_backend)
    end)

    :ok
  end

  describe "prune_operations/2" do
    test "keeps only the newest 256 records outside the floor" do
      operations = Map.new(for i <- 1..300, do: record("op-#{i}", @now - 2 * @hour - i))

      kept = AgentWorkspace.prune_operations(operations, @now)

      assert map_size(kept) == 256
      assert Map.has_key?(kept, "op-1")
      assert Map.has_key?(kept, "op-256")
      refute Map.has_key?(kept, "op-257")
      refute Map.has_key?(kept, "op-300")
    end

    test "drops records older than 24 hours and records without a timestamp" do
      operations =
        Map.new([
          record("fresh", @now - 2 * @hour),
          record("stale", @now - 25 * @hour),
          {"legacy", %{"result" => :legacy}}
        ])

      assert Map.keys(AgentWorkspace.prune_operations(operations, @now)) == ["fresh"]
    end

    test "never evicts a record younger than one hour, even past the count limit" do
      operations = Map.new(for i <- 1..300, do: record("op-#{i}", @now - i))

      assert map_size(AgentWorkspace.prune_operations(operations, @now)) == 300
    end

    test "floor records use up the budget before older ones" do
      young = for i <- 1..250, do: record("young-#{i}", @now - i)
      old = for i <- 1..20, do: record("old-#{i}", @now - 2 * @hour - i)

      kept = AgentWorkspace.prune_operations(Map.new(young ++ old), @now)

      assert map_size(kept) == 256
      assert Enum.count(kept, fn {id, _} -> String.starts_with?(id, "old-") end) == 6
      assert Map.has_key?(kept, "old-1")
      assert Map.has_key?(kept, "old-6")
      refute Map.has_key?(kept, "old-7")
    end

    test "keeps the newest records within 4 MB" do
      big = :binary.copy("x", 900 * 1024)
      operations = Map.new(for i <- 1..6, do: record("big-#{i}", @now - 2 * @hour - i, big))

      kept = AgentWorkspace.prune_operations(operations, @now)

      assert Enum.sort(Map.keys(kept)) == ["big-1", "big-2", "big-3", "big-4"]
    end

    test "breaks timestamp ties by operation id so pruning is deterministic" do
      young = for i <- 1..255, do: record("young-#{i}", @now - i)
      ties = [record("tie-b", @now - 2 * @hour), record("tie-a", @now - 2 * @hour)]

      kept = AgentWorkspace.prune_operations(Map.new(young ++ ties), @now)

      assert map_size(kept) == 256
      assert Map.has_key?(kept, "tie-a")
      refute Map.has_key?(kept, "tie-b")
    end
  end

  describe "committed operations" do
    test "a retry inside the window returns the first result without re-applying events" do
      agent_id = valid_agent_id()
      {:ok, first_write} = AgentWorkspace.prepare_write(agent_id, "/a.txt", "first")

      assert {:ok, :first} =
               AgentWorkspace.seed_operation(agent_id, "op-a", :first, [first_write])

      {:ok, second_write} = AgentWorkspace.prepare_write(agent_id, "/a.txt", "second")

      assert {:ok, :first} =
               AgentWorkspace.seed_operation(agent_id, "op-a", :second, [second_write])

      assert {:ok, "first"} = AgentWorkspace.read(agent_id, "/a.txt")
      assert {:ok, :first} = AgentWorkspace.operation_result(agent_id, "op-a")
    end

    test "an operation pushed out of the window replays as a new operation" do
      agent_id = valid_agent_id()
      earlier = System.os_time(:second) - 2 * @hour
      {:ok, write} = AgentWorkspace.prepare_write(agent_id, "/b.txt", "old")

      assert {:ok, :old} =
               AgentWorkspace.seed_operation(agent_id, "op-b", :old, [write],
                 committed_at: earlier
               )

      assert {:ok, :old} = AgentWorkspace.operation_result(agent_id, "op-b")

      for i <- 1..256 do
        assert {:ok, ^i} = AgentWorkspace.seed_operation(agent_id, "filler-#{i}", i, [])
      end

      assert {:error, :not_found} = AgentWorkspace.operation_result(agent_id, "op-b")
      assert {:ok, "old"} = AgentWorkspace.read(agent_id, "/b.txt")

      {:ok, rewrite} = AgentWorkspace.prepare_write(agent_id, "/b.txt", "new")
      assert {:ok, :new} = AgentWorkspace.seed_operation(agent_id, "op-b", :new, [rewrite])
      assert {:ok, "new"} = AgentWorkspace.read(agent_id, "/b.txt")
    end

    test "latest_operation_result_by_prefix only sees the retained window" do
      agent_id = valid_agent_id()
      earlier = System.os_time(:second) - 2 * @hour
      prefix = "vfs:delete:key:abc"

      assert {:ok, %{"deleted" => 1}} =
               AgentWorkspace.seed_operation(agent_id, prefix <> ":1", %{"deleted" => 1}, [],
                 committed_at: earlier
               )

      assert {:ok, %{"deleted" => 1}} =
               AgentWorkspace.latest_operation_result_by_prefix(agent_id, prefix)

      for i <- 1..256 do
        assert {:ok, ^i} = AgentWorkspace.seed_operation(agent_id, "filler-#{i}", i, [])
      end

      assert {:error, :not_found} =
               AgentWorkspace.latest_operation_result_by_prefix(agent_id, prefix)
    end

    test "a first commit shrinks an oversized legacy ledger in place" do
      agent_id = valid_agent_id()
      stale = System.os_time(:second) - 30 * 24 * @hour

      # Write the pre-change layout directly: an unbounded map of old records,
      # as a workspace state object left behind by the previous binary.
      legacy_operations =
        Map.new(for i <- 1..400, do: record("legacy-#{i}", stale - i, "result-#{i}"))

      legacy_state = %AgentWorkspace.State{
        agent_id: agent_id,
        vfs: %{},
        operations: legacy_operations
      }

      assert {:ok, _} =
               S3.put(
                 SalixStore.Keys.agent_workspace_state(agent_id),
                 SalixStore.Codec.encode_snapshot(legacy_state)
               )

      assert {:ok, %AgentWorkspace.State{operations: before}} =
               AgentWorkspace.read_state(agent_id)

      assert map_size(before) == 400
      assert {:ok, "result-7"} = AgentWorkspace.operation_result(agent_id, "legacy-7")

      assert {:ok, :now} = AgentWorkspace.seed_operation(agent_id, "op-now", :now, [])

      assert {:ok, %AgentWorkspace.State{operations: remaining}} =
               AgentWorkspace.read_state(agent_id)

      assert Map.keys(remaining) == ["op-now"]
    end
  end

  defp record(id, committed_at, result \\ nil) do
    {id,
     %{
       "operation_id" => id,
       "result" => result || "result-" <> id,
       "event_count" => 0,
       "managed_blob_uuids" => [],
       "committed_at" => committed_at
     }}
  end

  defp valid_agent_id do
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    SalixStore.Ids.new_agent_id(group_id)
  end
end
