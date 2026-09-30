defmodule BridgeForTeamsWeb.Application do
  @moduledoc """
  Web-layer supervision for `bridge_for_teams_web` (design §3). Serves the
  BridgeForTeams dashboard LiveView endpoint; the old standalone JSON API is no
  longer started.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # PubSub shared by the dashboard LiveView endpoint (design §3). Reused as
        # the endpoint's :pubsub_server (config).
        {Phoenix.PubSub, name: BridgeForTeamsWeb.PubSub},
        # Bridges live Salix agent runtime events (SalixWeb.PubSub, when
        # co-resident) onto per-org dashboard topics with lazy, interest-scoped
        # subscriptions; LiveViews `watch/1` on mount and keep polling as the
        # fallback when the relay reports unavailable.
        BridgeForTeams.Salix.EventRelay,
        # The dashboard Phoenix endpoint (port 4101). It boots in every env so
        # LiveViewTest can drive it; :server is false in test/dev unless opted in
        # (config), so it only opens a listening socket when configured to.
        BridgeForTeamsWeb.DashboardEndpoint
      ]

    opts = [strategy: :one_for_one, name: BridgeForTeamsWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
