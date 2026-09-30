defmodule SalixAnalytics.MixProject do
  use Mix.Project

  def project do
    [
      app: :salix_analytics,
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
      mod: {SalixAnalytics.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:salix_store, in_umbrella: true},
      {:salix_cluster, in_umbrella: true},
      {:oban, "~> 2.23"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5", only: :test},
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
