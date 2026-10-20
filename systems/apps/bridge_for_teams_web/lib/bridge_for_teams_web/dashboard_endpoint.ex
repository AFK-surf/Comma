defmodule BridgeForTeamsWeb.DashboardEndpoint do
  @moduledoc """
  Phoenix endpoint for the BridgeForTeams dashboard (design §3, port 4101),
  served by Bandit via `Bandit.PhoenixAdapter`: the React app's pages and
  JSON API, and the server-rendered login pages.

  The dashboard talks to the `BridgeForTeams.*` contexts in-process. Session
  cookies are signed with `secret_key_base` (config).
  """
  use Phoenix.Endpoint, otp_app: :bridge_for_teams_web

  # Session cookie for the signed dashboard session (stores the opaque
  # BridgeForTeams.Auth session token under :comma_session, plus CSRF).
  @session_options [
    store: :cookie,
    key: "_comma_dashboard_key",
    signing_salt: "comma4t-dash-cookie",
    same_site: "Lax"
  ]

  # Serve the built assets (tailwind/esbuild output) from priv/static. In prod
  # these are fingerprinted by `mix phx.digest` (assets.deploy) and served with
  # far-future cache headers; gzip serves the pre-compressed .gz variants digest
  # produces (harmless in dev, where no digest/.gz exists).
  plug Plug.Static,
    at: "/",
    from: :bridge_for_teams_web,
    gzip: true,
    only: BridgeForTeamsWeb.Dashboard.static_paths()

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug SystemsObservability.PodDrainGate

  plug SystemsObservability.HTTPPlug,
    endpoint: :bft_dashboard,
    route_resolver: {BridgeForTeamsWeb.DashboardRouter, :telemetry_route}

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug BridgeForTeamsWeb.DashboardRouter
end
