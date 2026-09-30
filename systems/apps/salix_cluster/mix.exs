defmodule SalixCluster.MixProject do
  use Mix.Project

  def project do
    [
      app: :salix_cluster,
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
      mod: {SalixCluster.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:salix_store, in_umbrella: true},
      {:salix_agent, in_umbrella: true},
      {:salix_calendar, in_umbrella: true},
      {:salix_env, in_umbrella: true},
      {:salix_im, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.19"},
      {:libring, "~> 1.7"},
      {:libcluster, "~> 3.4"},
      {:crontab, "~> 1.1"},
      {:tz, "~> 0.28"}
    ]
  end
end
