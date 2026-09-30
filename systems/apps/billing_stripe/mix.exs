defmodule BillingStripe.MixProject do
  use Mix.Project

  def project do
    [
      app: :billing_stripe,
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
    [
      extra_applications: [:logger, :crypto],
      mod: {BillingStripe.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:billing_commerce, in_umbrella: true},
      {:billing_core, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:stripity_stripe, "~> 3.3"}
    ]
  end
end
