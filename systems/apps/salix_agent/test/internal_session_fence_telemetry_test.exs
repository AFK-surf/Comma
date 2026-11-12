defmodule SalixAgent.InternalSessionFenceTelemetryTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{InternalSessionActor, InternalSessionStore, OwnershipCell}
  alias SalixAgent.InternalSessionStore.PGCodec
  alias SalixStore.Repo

  @session "ses1_0000000000000000002"

  defmodule FenceLog do
    @moduledoc false
    def log(%{meta: %{session_fence: fields}}, %{config: %{owner: owner}}),
      do: SystemsRuntime.Proc.send(owner, {:session_fence, fields})

    def log(_event, _config), do: :ok
  end

  @doc false
  def operation(_event, _measurements, metadata, owner) do
    if metadata[:operation] == "session_fence",
      do: SystemsRuntime.Proc.send(owner, {:fence_operation, metadata})
  end

  setup do
    SystemsClock.manual()
    on_exit(&SystemsClock.reset/0)
    owner = SystemsRuntime.Proc.self()
    handler = {__MODULE__, :session_fence}

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:salix, :operation, :stop],
        &__MODULE__.operation/4,
        owner
      )

    :ok = :logger.add_handler(:session_fence_test, FenceLog, %{config: %{owner: owner}})

    on_exit(fn ->
      SystemsRuntime.Telemetry.detach(handler)
      :logger.remove_handler(:session_fence_test)
    end)
  end

  defp owned_session do
    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.SessionFixture.cleanup_on_exit(agent)

    Repo.query!(
      """
      INSERT INTO salix_agents
        (agent_id,tenant_id,group_id,role,config_revision,config_payload,owner_node,owner_epoch,root_revision)
        VALUES ($1,'tenant','group','worker',1,$2,'owner',1,1)
      """,
      [agent, PGCodec.encode(%{})]
    )

    :ok = OwnershipCell.install(agent, 1)
    on_exit(fn -> OwnershipCell.clear(agent) end)

    {:ok, _} =
      Registry.register(SalixAgent.Registry, InternalSessionActor.key(agent, @session), nil)

    assert {:ok, _state} = InternalSessionStore.create(agent, @session)
    assert {:ok, version} = InternalSessionStore.read_revision(agent, @session)

    assert {:ok, staged} =
             InternalSessionStore.write_revision(version, [
               %{"type" => "status", "session_id" => @session, "status" => "active"}
             ])

    {agent, staged}
  end

  defp slow_prerequisite(result) do
    fn ->
      SystemsClock.advance(1_200)
      result
    end
  end

  defp observe(result, owner_ms, freeze_ms, write_ms) do
    started = SystemsClock.monotonic_time()
    SystemsClock.advance(owner_ms + freeze_ms)
    lap = SystemsClock.monotonic_time()
    SystemsClock.advance(write_ms)

    laps = %{
      owner_ms: System.convert_time_unit(owner_ms, :millisecond, :native),
      freeze_ms: System.convert_time_unit(freeze_ms, :millisecond, :native)
    }

    clock = %{kind: "direct", started: started, lap: lap, laps: laps}
    InternalSessionStore.observe_fence("agent", "session", result, clock)
  end

  test "a slow fence is measured and logged by phase" do
    observe({:ok, :revision}, 100, 200, 900)

    assert_received {:fence_operation, %{operation: "session_fence", outcome: "ok"}}

    assert_received {:session_fence,
                     %{
                       agent_id: "agent",
                       session_id: "session",
                       kind: "direct",
                       outcome: "ok",
                       owner_ms: 100,
                       freeze_ms: 200,
                       prerequisite_ms: 0,
                       schedule_ms: 0,
                       write_ms: 900
                     }}
  end

  test "a slow fence names the kernel calls inside its freeze" do
    {agent, staged} = owned_session()

    assert {:ok, _committed} =
             InternalSessionStore.durable_fence(agent, @session, staged, slow_prerequisite(:ok))

    assert_received {:session_fence, %{freeze_steps: steps}}
    assert Map.keys(steps) |> Enum.sort() == ~w(activity baseline delta reads view write)a
  end

  test "a fast fence is measured and not logged, and a failure counts as one" do
    observe({:error, :stale}, 0, 0, 999)

    assert_received {:fence_operation, %{operation: "session_fence", outcome: "error"}}
    refute_received {:session_fence, _fields}
  end

  test "a caller that does not own the Session is measured as a failed fence" do
    assert {:error, :not_session_owner} =
             InternalSessionStore.durable_fence("agent", @session, nil)

    assert_received {:fence_operation, %{operation: "session_fence", outcome: "error"}}
  end

  test "a fence times its prerequisite apart from its write" do
    {agent, staged} = owned_session()

    assert {:ok, _committed} =
             InternalSessionStore.durable_fence(agent, @session, staged, slow_prerequisite(:ok))

    assert_received {:session_fence,
                     %{kind: "direct", outcome: "ok", prerequisite_ms: 1_200, owner_ms: 0}}
  end

  test "a failed prerequisite is measured" do
    {agent, staged} = owned_session()
    prerequisite = slow_prerequisite({:error, :workspace})

    assert {:error, :workspace} =
             InternalSessionStore.durable_fence(agent, @session, staged, prerequisite)

    assert_received {:session_fence, %{outcome: "error", prerequisite_ms: 1_200, write_ms: 0}}
  end

  test "a started fence times its prerequisite apart from its freeze" do
    {agent, staged} = owned_session()

    assert {:ok, task} =
             InternalSessionStore.start_durable_fence(
               agent,
               @session,
               staged,
               slow_prerequisite(:ok)
             )

    assert {:ok, _committed} = InternalSessionStore.await_durable_fence(task)
    assert_received {:session_fence, %{kind: "started", outcome: "ok", prerequisite_ms: 1_200}}
  end
end
