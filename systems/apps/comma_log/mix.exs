defmodule CommaLog.MixProject do
  use Mix.Project

  # Shared, subsystem-neutral library: the opt-in JSONL diagnostic logger used by
  # both Salix (salix_*) and BridgeForTeams (bridge_for_teams_*). A plain library
  # app — not a subsystem — pulled in transitively as a dependency, so its single
  # logger GenServer is always available.
  def project do
    [
      app: :comma_log,
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

  def application do
    [
      extra_applications: [:logger],
      mod: {CommaLog.Application, []}
    ]
  end

  defp deps do
    [
      {:systems_observability, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:opentelemetry_api, "~> 1.5"}
    ]
  end
end
