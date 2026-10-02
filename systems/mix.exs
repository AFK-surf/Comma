defmodule Comma.MixProject do
  use Mix.Project

  # The Comma systems umbrella. One mix project and one `mix release` ship the
  # Salix, Comma product, and Bridge For Teams subsystems. New subsystems add
  # their OTP apps under apps/, register them in Comma's subsystem map, and add
  # them to the release in releases/0 below.
  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Dashboard asset pipeline (bridge_for_teams_web). Standalone tailwind+esbuild
  # Hex installers download their binaries on first `assets.setup` run.
  defp aliases do
    [
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing"
      ],
      "assets.build": [
        "tailwind bridge_for_teams",
        "esbuild bridge_for_teams",
        "tailwind salix",
        "esbuild salix"
      ],
      # Minify, then fingerprint + gzip into priv/static and write
      # cache_manifest.json (consumed by the endpoint's :cache_static_manifest in
      # prod, so ~p"/assets/app.js" resolves to the digested, far-future-cacheable
      # path). Path is explicit since this runs from the umbrella root.
      # phx.digest is a recursive umbrella task, so scope it to each web app
      # (where priv/static is) with `do --app`; a bare `phx.digest` would
      # otherwise run in every child app with a path relative to the wrong dir.
      "assets.deploy": [
        "tailwind bridge_for_teams --minify",
        "esbuild bridge_for_teams --minify",
        "tailwind salix --minify",
        "esbuild salix --minify",
        "do --app bridge_for_teams_web phx.digest priv/static",
        "do --app salix_web phx.digest priv/static"
      ]
    ]
  end

  # One release (`comma`), one Docker image — but a pod runs only the subsystems
  # selected for it (COMMA_SUBSYSTEMS; default all). To make that selection real
  # in the release, every subsystem's apps ship in `:load` mode (loaded, not
  # started); the `:comma` launcher app (:permanent) starts the selected ones at
  # boot. See Comma / Comma.Application and config/runtime.exs.
  #
  # Within a subsystem there are still no build-time roles: every node that
  # runs Salix runs all `salix_*` apps, and cluster singletons are lease-gated
  # at runtime.
  defp releases do
    [
      comma: [
        applications:
          [
            opentelemetry_exporter: :temporary,
            opentelemetry: :temporary,
            systems_observability: :temporary,
            comma: :permanent
          ] ++ subsystem_apps(),
        include_executables_for: [:unix]
      ]
    ]
  end

  # All subsystem applications, in :load mode, grouped by subsystem so adding a
  # subsystem is a localized edit: define its app list and concatenate it (and
  # register it in Comma's @subsystems map).
  defp subsystem_apps do
    alert_router_apps() ++ salix_apps() ++ comma_product_apps() ++ bridge_for_teams_apps()
  end

  # Alert Router is independently selectable and deployable, while reusing the
  # same release image and the repository's established Postgres/Oban stack.
  defp alert_router_apps do
    [
      alert_router: :load
    ]
  end

  # Comma product backend subsystem. The :comma launcher app stays separate from
  # the product domain so release boot selection remains dependency-light.
  defp comma_product_apps do
    [
      billing_core: :load,
      billing_commerce: :load,
      billing_stripe: :load,
      comma_core: :load,
      comma_web: :load,
      comma_tui: :load,
      comma_ssh: :load
    ]
  end

  # BridgeForTeams — the business-logic backend subsystem documented in
  # docs/bridge-for-teams/design.md.
  defp bridge_for_teams_apps do
    [
      bridge_for_teams_core: :load,
      bridge_for_teams_web: :load
    ]
  end

  # Salix — the multi-agent runtime subsystem.
  defp salix_apps do
    [
      salix_store: :load,
      salix_calendar: :load,
      salix_agent: :load,
      salix_cluster: :load,
      salix_llm: :load,
      salix_im: :load,
      salix_mcp: :load,
      salix_web: :load,
      salix_env: :load,
      salix_analytics: :load,
      salix_migrate: :load,
      salix_media: :load,
      salix_meet: :load,
      salix_voice: :load,
      salix_signal_proto: :load,
      salix_signal: :load
    ]
  end

  defp deps do
    []
  end
end
