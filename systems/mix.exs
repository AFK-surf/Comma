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
      consolidation_path: consolidation_path(),
      releases: releases(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Each Mix run in this umbrella consolidates protocols again, even after a
  # clean compile. Concurrent test processes (MIX_TEST_PARTITION, see
  # .github/CI.md) each get their own directory instead of rewriting one.
  defp consolidation_path do
    if partition = System.get_env("MIX_TEST_PARTITION") do
      Path.expand("_build/#{Mix.env()}/consolidated-#{partition}", __DIR__)
    end
  end

  # Points git at the repository's hooks in scripts/git-hooks. Image builds
  # copy systems/ alone and have no script.
  defp install_git_hooks(_args) do
    script = Path.expand("../scripts/git-hooks/install.sh", __DIR__)
    if File.exists?(script), do: System.cmd("sh", [script])
  end

  # Dashboard asset pipeline (bridge_for_teams_web). Standalone tailwind+esbuild
  # Hex installers download their binaries on first `assets.setup` run.
  defp aliases do
    [
      # A module loads on its first call; mid-test that is work the test clock
      # cannot see. Every module loads before the suite starts, before the
      # applications' processes compete with the code server for the load,
      # with its atoms made in one order on every run (`SystemsSim.Preload`).
      # Only the first app.config of a run counts. The test aliases of
      # salix_store, comma_core, alert_router and bridge_for_teams_core run
      # ecto.create, whose app.config would otherwise come first.
      test: &run_tests/1,
      "deps.get": ["deps.get", &install_git_hooks/1],
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

  # CI compiles once before its test processes start. Pass their --no-compile
  # flag through this alias so preloading does not start another compilation.
  defp run_tests(args) do
    Mix.Task.run("app.config", args)
    preload_modules()
    Mix.Task.run("test", args)
  end

  # What `app.config --preload-modules` does, with the code path cached first
  # and the modules' atoms made in one order (`SystemsSim.Preload`). The code
  # server finds a module by asking the file system in each directory of the
  # path that it has not listed: for the umbrella's 6,900 modules that was
  # 20 s of system calls in every test process. Cached, it lists each
  # directory once. Compilation is over by now, so the directories keep their
  # contents.
  defp preload_modules do
    true = :code.set_path(:code.get_path(), :cache)
    SystemsSim.Preload.modules()
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
      salix_meet_native: :load,
      salix_meet: :load,
      salix_voice: :load,
      salix_signal_proto: :load,
      salix_signal: :load
    ]
  end

  # Membrane's ratio (salix_meet_native) caps decimal at 2.x while ecto_sql
  # needs 3.x; ratio uses decimal only optionally. A child's override does not
  # reach the umbrella's own dependency check.
  defp deps do
    [{:decimal, "~> 3.1", override: true}]
  end
end
