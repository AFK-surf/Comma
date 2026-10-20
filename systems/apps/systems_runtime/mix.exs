defmodule SystemsRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :systems_runtime,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [], mod: {SystemsRuntime.Application, []}]

  defp deps, do: [{:ecto_sql, "~> 3.12"}, {:postgrex, "~> 0.19"}, {:telemetry, "~> 1.0"}]
end
