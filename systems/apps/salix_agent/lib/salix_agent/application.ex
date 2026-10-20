defmodule SalixAgent.Application do
  @moduledoc """
  Agent-runtime supervision. Starts the
  partitioned process Registry for agent Servers and a DynamicSupervisor that
  spawns one `SalixAgent.Server` per claimed agent on demand.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Streamed-delta capture table. Owned by the application master so an
    # in-flight capture survives any worker's crash loop, and created here
    # rather than lazily so the first streaming round does not race on it.
    _ = SalixAgent.EventArchive.Accumulator.create_table()
    # Ownership-cell table, same pattern: owned by the application master so
    # a crash of the cell GenServer never forgets a recorded fence.
    _ = SalixAgent.OwnershipCell.create_table()
    _ = SalixAgent.SessionResidency.create_table()
    # Skill projections must outlive the tasks that build round configurations.
    _ = SalixAgent.SkillProjection.create_table()
    # miIO and other LAN codec sessions outlive the tool calls that open them.
    _ = SalixAgent.LanCodec.create_table()

    fleet_max_restarts =
      SystemsRuntime.get_env(:salix_agent, :fleet_supervisor_max_restarts, 3)

    fleet_max_seconds =
      SystemsRuntime.get_env(:salix_agent, :fleet_supervisor_max_seconds, 5)

    children = [
      {SystemsRuntime.Registry,
       keys: :unique, name: SalixAgent.Registry, partitions: System.schedulers_online()},
      # Node-local mirror of the fenced root-head ownership; must exist before
      # any Server claims or session actor commits.
      SalixAgent.OwnershipCell,
      SalixAgent.SessionResidency,
      # Owns the table of round configurations built ahead of session actors.
      SalixAgent.RoundConfigPrewarm,
      # Core ownership/recovery work never shares admission with user-selected
      # providers, runtimes, or tools.
      {SystemsRuntime.TaskSupervisor, name: SalixAgent.TaskSup},
      {SystemsRuntime.TaskSupervisor, name: SalixAgent.WaitTimerTasks, max_children: 256},
      {SystemsRuntime.TaskSupervisor,
       name: SalixAgent.AgentReplyTaskSup,
       max_children: SystemsRuntime.get_env(:salix_agent, :agent_reply_task_limit, 64)},
      {SystemsRuntime.TaskSupervisor,
       name: SalixAgent.AgentStageTaskSup,
       max_children: SystemsRuntime.get_env(:salix_agent, :agent_stage_task_limit, 64)},
      SalixAgent.DependencySupervisor,
      SalixAgent.Decide.Limits,
      SalixAgent.DependencyRunner,
      # Reactive domain recovery requested by the cluster lease holder. It has
      # no ticker or lease of its own and keeps slow SessionActor wakes off the
      # shared Recovery cadence.
      SalixAgent.SessionWorkRecovery,
      # In-memory last-activity cache; must exist before any agent runs.
      SalixAgent.ActivitySurface,
      SalixAgent.RouterRequestMonitor,
      SalixAgent.DraftSurface,
      SalixAgent.ExecutionSurface,
      {SystemsRuntime.DynamicSupervisor,
       name: SalixAgent.Browser.Supervisor, strategy: :one_for_one},
      SalixAgent.SubscriptionWorker,
      background(SalixAgent.SubscriptionQuotaWorker, :subscription_quota_worker),
      background(SalixAgent.PreparedBlobCleanup, :prepared_blob_cleanup),
      # Background Loops: the node's spinfoam child, the build artifact
      # handoff, and the reconciler that follows Agent placement.
      SalixAgent.Loops.Host,
      SalixAgent.Loops.Reconciler,
      # Outbound SSH sessions (ssh.* tools) are supervised by their session
      # actors; this registry only names them. SSH over Tailcat goes through
      # one gateway process per node, started on first use.
      {SystemsRuntime.Registry, keys: :unique, name: SalixAgent.SSH.Registry},
      SalixAgent.SSH.TailcatGateway,
      # A Group's tailnet node runs in this node's gateway while this node
      # holds the Group's tailnet lease; its owner process holds the lease.
      {SystemsRuntime.Registry, keys: :unique, name: SalixAgent.Tailnet.Registry},
      SalixAgent.Tailnet.Gateway,
      {SystemsRuntime.DynamicSupervisor, name: SalixAgent.Tailnet.Owners, strategy: :one_for_one},
      {SystemsRuntime.DynamicSupervisor,
       name: SalixAgent.FleetSup,
       strategy: :one_for_one,
       max_restarts: fleet_max_restarts,
       max_seconds: fleet_max_seconds}
    ]

    opts = [strategy: :one_for_one, name: SalixAgent.Supervisor]

    SystemsRuntime.Supervisor.start_link(
      List.flatten(children) ++ SalixAgent.SessionHistory.Supervisor.children(),
      opts
    )
  end

  # A worker that does its work on a timer starts unless its switch is off.
  # The test configuration turns each one off: a test calls the worker's work
  # itself, or starts the worker under its own supervisor.
  defp background(child, switch),
    do: if(SystemsRuntime.get_env(:salix_agent, switch, true), do: [child], else: [])
end
