defmodule BridgeForTeamsWeb.Application do
  @moduledoc """
  Web-layer supervision for `bridge_for_teams_web` (design §3). Serves the
  BridgeForTeams dashboard endpoint; the old standalone JSON API is no longer
  started.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # PubSub for the dashboard endpoint (design §3). Reused as the
        # endpoint's :pubsub_server (config).
        {Phoenix.PubSub, name: BridgeForTeamsWeb.PubSub},
        # The dashboard Phoenix endpoint (port 4101). It boots in every env so
        # tests can drive it; :server is false in test/dev unless opted in
        # (config), so it only opens a listening socket when configured to.
        BridgeForTeamsWeb.DashboardEndpoint
      ]

    opts = [strategy: :one_for_one, name: BridgeForTeamsWeb.Supervisor]
    SystemsRuntime.Supervisor.start_link(children, opts)
  end
end
