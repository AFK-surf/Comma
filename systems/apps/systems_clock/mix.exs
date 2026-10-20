defmodule SystemsClock.MixProject do
  use Mix.Project

  def project do
    [
      app: :systems_clock,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: [{:systems_runtime, in_umbrella: true}]
    ]
  end

  def application, do: [extra_applications: [], mod: {SystemsClock.Application, []}]
end
