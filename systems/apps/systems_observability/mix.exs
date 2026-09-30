defmodule SystemsObservability.MixProject do
  use Mix.Project

  def project do
    [
      app: :systems_observability,
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
    [extra_applications: [:logger], mod: {SystemsObservability.Application, []}]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry_bandit, "~> 0.3.0"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_exporter, "~> 1.10"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:plug, "~> 1.16"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:telemetry_poller, "~> 1.0"}
    ]
  end
end
