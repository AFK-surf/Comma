defmodule SalixMeet.MixProject do
  use Mix.Project

  def project do
    [
      app: :salix_meet,
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {SalixMeet.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:systems_observability, in_umbrella: true},
      {:salix_store, in_umbrella: true},
      {:salix_agent, in_umbrella: true},
      {:salix_calendar, in_umbrella: true},
      {:salix_cluster, in_umbrella: true},
      {:salix_im, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:mdex, "~> 0.13"},
      {:bandit, "~> 1.5", only: :test},
      {:plug, "~> 1.16"}
    ]
  end
end
