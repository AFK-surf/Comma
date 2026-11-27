defmodule BillingApple.MixProject do
  use Mix.Project

  def project do
    [
      app: :billing_apple,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:systems_clock, in_umbrella: true},
      {:billing_commerce, in_umbrella: true},
      {:billing_core, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:jose, "~> 1.11"},
      {:req, "~> 0.6"}
    ]
  end
end
