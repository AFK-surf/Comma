defmodule SalixAgent.SessionHistorySchedulerTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixAgent.SessionHistory.{Scheduler, Worker}
  alias SalixStore.{Ids, Repo}

  # Use the production dispatch callback without the independent periodic
  # discovery input, so only this test's queued addresses start work.
  defmodule Dispatch do
    use SystemsRuntime.Server
    def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: Worker)
    def init(_), do: {:ok, %{}}
    def handle_cast(message, state), do: Worker.handle_cast(message, state)
  end

  defmodule Cold do
    def transfer(agent, session, _docs) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:started, self(), agent, session})

      receive do
        :release -> :ok
      end
    end
  end

  setup do
    opts = Repo.config() |> Keyword.drop([:name, :pool, :pool_size]) |> Keyword.put(:pool_size, 4)
    start_supervised!({SalixStore.SessionHistoryRepo, opts})
    scheduler = start_supervised!(Scheduler)
    dispatch = start_supervised!(Dispatch)
    old = SystemsRuntime.get_env(:salix_agent, :session_history_cold)
    SystemsRuntime.put_env(:salix_agent, :session_history_cold, Cold)
    :persistent_term.put({Cold, :owner}, self())

    on_exit(fn ->
      if old,
        do: SystemsRuntime.put_env(:salix_agent, :session_history_cold, old),
        else: SystemsRuntime.delete_env(:salix_agent, :session_history_cold)

      :persistent_term.erase({Cold, :owner})
    end)

    %{scheduler: scheduler, dispatch: dispatch}
  end

  defp source(agent, session) do
    Repo.query!(
      "INSERT INTO agent_session_history_states(agent_id,session_id,indexed_through,cold_through,target_seq) VALUES($1,$2,300,0,300)",
      [agent, session]
    )

    Repo.query!(
      "INSERT INTO agent_session_history_documents(agent_id,session_id,seq,part,text,kind,tool_name,label) VALUES($1,$2,1,0,'history','message','', '[\"agent_private\"]')",
      [agent, session]
    )
  end

  test "dispatch bounds task starts, shares tenant capacity, and serializes an address", %{
    scheduler: scheduler,
    dispatch: dispatch
  } do
    a = Ids.new_agent_id(Ids.new_group_id(Ids.new_tenant_id()))
    b = Ids.new_agent_id(Ids.new_group_id(Ids.new_tenant_id()))
    c = Ids.new_agent_id(Ids.new_group_id(Ids.new_tenant_id()))
    for agent <- [a, b], n <- 1..64, do: source(agent, "s#{n}")
    source(c, "quiet")
    :erlang.trace(scheduler, true, [:procs, {:tracer, self()}])
    :erlang.trace(dispatch, true, [:procs, {:tracer, self()}])
    for agent <- [a, b], n <- 1..64, do: Worker.hint(agent, "s#{n}")

    running =
      for _ <- 1..4 do
        settle_receive({:started, pid, agent, session})
        {pid, agent, session}
      end

    assert Enum.frequencies_by(running, &elem(&1, 1)) == %{a => 2, b => 2}
    assert length(Enum.uniq_by(running, &Tuple.delete_at(&1, 0))) == 4
    [{_, ^a, active} | _] = Enum.filter(running, &(elem(&1, 1) == a))
    Worker.hint(a, active)
    Worker.hint(c, "quiet")
    settle_refute_receive({:started, _, _, _}, 100)
    spawned = drain_spawns([])
    assert length(spawned) == 4
    assert MapSet.new(spawned) == MapSet.new(Enum.map(running, &elem(&1, 0)))
    {released, ^a, _} = Enum.find(running, &(elem(&1, 1) == a))
    send(released, :release)
    settle_receive({:started, quiet, ^c, "quiet"})
    settle_refute_receive({:started, _, _, _}, 100)
    stop_supervised!(Dispatch)
    stop_supervised!(Scheduler)
    for {pid, _, _} <- running, do: Process.exit(pid, :kill)
    Process.exit(quiet, :kill)
  end

  defp drain_spawns(acc) do
    receive do
      {:trace, _, :spawn, pid, _} -> drain_spawns([pid | acc])
    after
      0 -> acc
    end
  end
end
