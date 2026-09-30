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
    Application.put_env(:salix_agent, :placement, SalixCluster.Placement)
    Application.put_env(:salix_calendar, :placement, SalixCluster.CalendarPlacement)
    Application.put_env(:salix_im, :conversation_placement, SalixCluster.ConversationPlacement)

    Application.put_env(
      :salix_im,
      :private_chat_status_placement,
      SalixCluster.PrivateChatStatusPlacement
    )

    Application.put_env(
      :salix_im,
      :slack_router_status_placement,
      SalixCluster.SlackRouterStatusPlacement
    )

    children =
      [
        SalixCluster.Ring,
        # Owns the non-linked housekeeping tasks (Recovery's async prune).
        # Started unconditionally — Recovery instances launched directly by
        # tests need it even where the production sweeps are disabled.
        {Task.Supervisor, name: SalixCluster.TaskSup}
      ]
      |> maybe_libcluster()
      |> maybe_recovery()

    opts = [strategy: :one_for_one, name: SalixCluster.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_libcluster(children) do
    case Application.get_env(:salix_cluster, :topologies) do
      nil ->
        children

      topologies ->
        children ++ [{Cluster.Supervisor, [topologies, [name: SalixCluster.ClusterSupervisor]]}]
    end
  end

  defp maybe_recovery(children) do
    if Application.get_env(:salix_cluster, :enabled, true) do
      # Lease-gated singletons — safe to start on every node.
      recovery_children =
        [SalixCluster.Recovery] ++
          session_work_notification_children() ++
          [SalixCluster.Timers, SalixCluster.Schedules]

      children ++ recovery_children
    else
      children
    end
  end

  # LISTEN needs the same control Postgres configured for the durable
  # candidate projection. S3-only runtime nodes retain periodic recovery but
  # do not enter a reconnect loop for a database they intentionally lack.
  defp session_work_notification_children do
    if Application.get_env(:salix_store, :start_repo, false) do
      [SalixCluster.SessionWorkNotificationListener]
    else
      []
    end
  end
end
