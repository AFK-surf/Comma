defmodule SalixIM.MixProject do
  use Mix.Project

  def project do
    [
      app: :salix_im,
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
      mod: {SalixIM.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:salix_ifc, in_umbrella: true},
      {:salix_store, in_umbrella: true},
      {:salix_agent, in_umbrella: true, only: :test},
      {:telemetry_metrics, "~> 1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:mdex, "~> 0.13"},
      # 0.2.3 makes native AST conversion stack-safe for nested message markup.
      # Keep MDEx 0.13's node schema; later native releases add required fields.
      {:mdex_native, "0.2.3"},
      {:bandit, "~> 1.5", only: :test},
      {:plug, "~> 1.16"}
    ]
  end
end
