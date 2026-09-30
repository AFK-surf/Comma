defmodule BillingCommerce.MixProject do
  use Mix.Project

  def project do
    [
      app: :billing_commerce,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {BillingCommerce.Application, []}
    ]
  end

  defp deps do
    [
      {:billing_core, in_umbrella: true},
      {:salix_analytics, in_umbrella: true},
      {:ecto_sql, "~> 3.12"},
      {:jason, "~> 1.4"}
    ]
  end
end
