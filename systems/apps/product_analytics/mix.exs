defmodule ProductAnalytics.MixProject do
  use Mix.Project

  # Shared, subsystem-neutral library: the bounded PostHog export queue used by
  # Comma (comma_core) and Comma for Teams (bridge_for_teams_core). Each product
  # keeps its own event allowlist, identity and exporter; this app only queues
  # and sends. A plain library, pulled in as a dependency; it starts nothing.
  def project do
    [
      app: :product_analytics,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:systems_clock, in_umbrella: true},
      {:systems_runtime, in_umbrella: true},
      {:ecto, "~> 3.12"},
      {:posthog, "~> 2.16"},
      {:jason, "~> 1.4"}
    ]
  end
end
