defmodule SalixWeb.DashboardEndpoint do
  @moduledoc """
  Phoenix endpoint for the Salix admin dashboard (LiveView UI under `/dash`).

  Unlike a normal Phoenix endpoint this one opens NO listener of its own
  (`server: false` in config). It is started purely so its config + socket
  transport process tree exist, and is invoked as a plug by `SalixWeb.Endpoint`
  for any `/dash/*` request — sharing the single Bandit listener on port 4000
  with the JSON API. Static assets and the LiveView socket are therefore mounted
  under the `/dash` prefix so paths match post-delegation (no path rewriting).

  The dashboard talks to Salix public app APIs in-process; it never calls the
  JSON API. Auth is a signed session cookie set after the admin pastes the
  system-wide admin token (`SalixWeb.Dashboard.Auth`).
  """
  use Phoenix.Endpoint, otp_app: :salix_web

  @session_options [
    store: :cookie,
    key: "_salix_dash_key",
    signing_salt: "salix-dash-cookie",
    same_site: "Lax"
  ]

  socket("/dash/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  # Built assets (tailwind/esbuild output) from priv/static, served under /dash.
  plug(Plug.Static,
    at: "/dash",
    from: :salix_web,
    gzip: true,
    only: SalixWeb.Dashboard.static_paths()
  )

  plug(Plug.RequestId)

  plug(SystemsObservability.HTTPPlug,
    endpoint: :salix_api,
    route_resolver: {SalixWeb.Dashboard.Router, :telemetry_route}
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(SalixWeb.Dashboard.Router)

  @doc "Session options shared with the LiveView socket connect_info and test helper."
  def session_options, do: @session_options
end
