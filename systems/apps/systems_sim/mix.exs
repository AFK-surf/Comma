defmodule SystemsSim.MixProject do
  use Mix.Project

  def project do
    [
      app: :systems_sim,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: [{:systems_clock, in_umbrella: true}]
    ]
  end

  def application, do: [extra_applications: []]
end
