defmodule SalixCluster.Application do
  @moduledoc """
  Cluster-layer supervision. Starts the placement
  ring and installs the cluster placement seam so deliveries route to the
  ring-owner node. Optionally starts `libcluster` (when a topology is configured)
  and the lease-gated background sweeps (`Recovery`).

  Recovery is disabled by default in `:test` (driven deterministically by tests).
  libcluster is off unless `config :salix_cluster, :topologies` is set.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Route agent placement through the ring (no-op routing on a single node).
    SystemsRuntime.put_env(:salix_agent, :placement, SalixCluster.Placement)
    # A draining node that places keys elsewhere starts no new agent Server.
    SystemsRuntime.put_env(
      :salix_agent,
      :start_admission,
      &SalixCluster.NodeLifecycle.admit_start/0
    )

    SystemsRuntime.put_env(:salix_calendar, :placement, SalixCluster.CalendarPlacement)
    SystemsRuntime.put_env(:salix_im, :conversation_placement, SalixCluster.ConversationPlacement)

    SystemsRuntime.put_env(
      :salix_im,
      :private_chat_status_placement,
      SalixCluster.PrivateChatStatusPlacement
    )

    SystemsRuntime.put_env(
      :salix_im,
      :slack_router_status_placement,
      SalixCluster.SlackRouterStatusPlacement
    )

    children =
      [
        # Starts before the ring so the ring's first change reaches it.
        {SalixCluster.ConversationOwnerKeeper,
         interval_ms:
           SystemsRuntime.get_env(
             :salix_cluster,
             :conversation_owner_keeper_interval_ms,
             :timer.seconds(60)
           )},
        # Owners the ring places elsewhere are released; the owners of active
        # station Tasks are started again, here or on their owner node, so
        # their watches survive a restart and a placement change. Signal
        # accounts move with the ring too (its app depends on this one, so
        # the call is soft).
        {SalixCluster.Ring,
         on_change: fn ->
           SalixCluster.ConversationOwnerKeeper.ring_changed()
           SalixIM.StationTaskWatchRecovery.ring_changed()
           soft_call(SalixSignal.Account.Keeper, :ring_changed)
         end,
         on_ready: &SalixIM.StationTaskWatchRecovery.node_ready/0},
        # Owns the non-linked housekeeping tasks (Recovery's async prune).
        # Started unconditionally — Recovery instances launched directly by
        # tests need it even where the production sweeps are disabled.
        {SystemsRuntime.TaskSupervisor, name: SalixCluster.TaskSup}
      ]
      |> maybe_libcluster()
      |> maybe_recovery()

    opts = [strategy: :one_for_one, name: SalixCluster.Supervisor]
    SystemsRuntime.Supervisor.start_link(children, opts)
  end

  defp soft_call(module, function) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 0),
      do: apply(module, function, [])

    :ok
  end

  defp maybe_libcluster(children) do
    case SystemsRuntime.get_env(:salix_cluster, :topologies) do
      nil ->
        children

      topologies ->
        children ++ [{Cluster.Supervisor, [topologies, [name: SalixCluster.ClusterSupervisor]]}]
    end
  end

  defp maybe_recovery(children) do
    if SystemsRuntime.get_env(:salix_cluster, :enabled, true) do
      # Lease-gated singletons — safe to start on every node.
      recovery_children =
        [SalixCluster.Recovery] ++
          session_work_notification_children() ++
          [SalixCluster.Schedules]

      children ++ recovery_children
    else
      children
    end
  end

  # LISTEN needs the same control Postgres configured for the durable
  # candidate projection. S3-only runtime nodes retain periodic recovery but
  # do not enter a reconnect loop for a database they intentionally lack.
  defp session_work_notification_children do
    if SystemsRuntime.get_env(:salix_store, :start_repo, false) do
      [SalixCluster.SessionWorkNotificationListener]
    else
      []
    end
  end
end
