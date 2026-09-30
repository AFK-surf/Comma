defmodule BridgeForTeamsWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :bridge_for_teams_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BridgeForTeamsWeb.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:systems_observability, in_umbrella: true},
      {:bridge_for_teams_core, in_umbrella: true},
      # Contract E2E: authenticated BFT HTTP consumes the actual Salix
      # meeting-calendar binding without starting the Salix web application.
      {:salix_web, in_umbrella: true, only: :test, runtime: false},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      # Dashboard LiveView stack (port 4101). Reuses phoenix_pubsub already in
      # the umbrella; Bandit is the adapter.
      {:phoenix, "~> 1.7.14"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_template, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.2"},
      {:gettext, "~> 0.26"},
      {:mdex, "~> 0.13"},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
