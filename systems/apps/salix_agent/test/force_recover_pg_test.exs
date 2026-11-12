defmodule SalixAgent.ForceRecoverPGTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixAgent.{Control, InternalSession, TestSupport}
  alias SalixAgent.InternalSessionStore.PG
  alias SalixStore.{Agent, Repo, S3}

  @first "ses1_0000000000000000960"
  @second "ses1_0000000000000000961"

  defmodule PlacementBoundary do
    def stop_existing(agent, _opts),
      do: SystemsRuntime.get_env(:salix_agent, :repair_stop).(agent)

    def ensure_started(_, _), do: raise("wake must not occur while recovery owns the Agent")
  end

  setup do
    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)

    previous_placement =
      SystemsRuntime.get_env(:salix_agent, :placement, SalixAgent.Placement.LocalFleet)

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    agent = TestSupport.create_control_agent!(TestSupport.new_agent_id())["agent_id"]
    SystemsRuntime.put_env(:salix_agent, :placement, PlacementBoundary)
    SystemsRuntime.put_env(:salix_agent, :repair_stop, fn _ -> :ok end)

    on_exit(fn ->
      TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_s3)
      SystemsRuntime.put_env(:salix_agent, :placement, previous_placement)
      SystemsRuntime.delete_env(:salix_agent, :repair_stop)
    end)

    %{agent: agent}
  end

  test "a failed runtime stop cannot claim or repair", %{agent: agent} do
    assert {:ok, initial} = PG.create(agent, @first, 1)

    assert {:ok, _} =
             PG.commit_revision(initial, 1, [%{"type" => "status", "status" => "active"}])

    SystemsRuntime.put_env(:salix_agent, :repair_stop, fn _ ->
      {:error, :runtime_still_running}
    end)

    assert {:error, :runtime_still_running} =
             Control.force_recover(agent, session_id: @first, wake: false)

    assert %{rows: [[1]]} =
             Repo.query!("SELECT owner_epoch FROM salix_agents WHERE agent_id=$1", [agent])

    assert {:ok, current} = PG.read(agent, @first)
    assert InternalSession.status(current.state) == :active
  end

  test "repair reads after the stop and releases its direct claim without starting a Server", %{
    agent: agent
  } do
    assert {:ok, initial} = PG.create(agent, @first, 1)

    SystemsRuntime.put_env(:salix_agent, :repair_stop, fn ^agent ->
      {:ok, _} =
        PG.commit_revision(initial, 1, [
          %{"type" => "session_update", "name" => "last owner state"},
          %{"type" => "status", "status" => "active"}
        ])

      :ok
    end)

    assert {:ok, %{"sessions" => [%{"status" => "idle"}], "stopped" => nil}} =
             Control.force_recover(agent, session_id: @first, wake: false)

    assert {:ok, current} = PG.read(agent, @first)
    assert InternalSession.get(current.state, :name) == "last owner state"
    assert InternalSession.status(current.state) == :idle

    assert %{rows: [[2, nil]]} =
             Repo.query!("SELECT owner_epoch,owner_node FROM salix_agents WHERE agent_id=$1", [
               agent
             ])

    assert [] = SystemsRuntime.Registry.lookup(SalixAgent.Registry, agent)
  end

  test "a takeover fences the captured repair and stops later sessions", %{agent: agent} do
    for sid <- [@first, @second] do
      {:ok, initial} = PG.create(agent, sid, 1)
      {:ok, _} = PG.commit_revision(initial, 1, [%{"type" => "status", "status" => "active"}])
    end

    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        fn _, _, metadata, _ ->
          if self() != owner and metadata.params == [agent, @first] and
               String.starts_with?(metadata.query, "SELECT agent_id, session_id") and
               not Process.get(handler, false) do
            Process.put(handler, true)
            send(owner, {:repair_snapshot, self()})

            receive do
              :resume_repair -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    repair = SystemsRuntime.Task.async(fn -> Control.force_recover(agent, wake: false) end)
    settle_receive({:repair_snapshot, reader})
    assert {:ok, takeover} = Agent.claim(agent, "new-owner", SalixAgent.State, steal: true)
    send(reader, :resume_repair)

    assert {:ok,
            %{
              "stopped" => {:fenced, epoch},
              "sessions" => [%{"session_id" => @first, "error" => _}]
            }} =
             settled_await(repair)

    assert epoch == takeover.epoch

    for sid <- [@first, @second] do
      assert {:ok, current} = PG.read(agent, sid)
      assert InternalSession.status(current.state) == :active
    end

    assert %{rows: [["new-owner"]]} =
             Repo.query!("SELECT owner_node FROM salix_agents WHERE agent_id=$1", [agent])

    assert :ok = Agent.release(takeover)
  end
end
