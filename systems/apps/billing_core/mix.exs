defmodule BillingCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :billing_core,
      version: "0.1.0",
      build_path: "../../_build",
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
      mod: {BillingCore.Application, []}
    ]
  end

  defp deps do
    [
      {:systems_observability, in_umbrella: true},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:salix_analytics, in_umbrella: true}
    ]
  end
end
