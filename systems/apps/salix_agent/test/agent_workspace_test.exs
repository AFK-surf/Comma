defmodule SalixAgent.AgentWorkspaceTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.AgentWorkspace
  alias SalixStore.S3

  @hour 60 * 60
  @now 1_800_000_000

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    case SystemsRuntime.Proc.whereis(S3.Fake) do
      nil -> start_supervised!(S3.Fake)
      _pid -> S3.Fake.reset()
    end

    on_exit(fn ->
      if is_nil(previous_backend),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
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

    test "a first commit shrinks an oversized legacy ledger in place" do
      agent_id = valid_agent_id()
      stale = SystemsClock.system_time(:second) - 30 * 24 * @hour

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
