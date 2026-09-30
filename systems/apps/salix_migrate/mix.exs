defmodule SalixMigrate.MixProject do
  use Mix.Project

  def project do
    [
      app: :salix_migrate,
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
      mod: {SalixMigrate.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:salix_store, in_umbrella: true},
      {:salix_agent, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
