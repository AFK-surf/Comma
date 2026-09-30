defmodule CommaSSH.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :comma_ssh,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: [{:comma_core, in_umbrella: true}, {:comma_tui, in_umbrella: true}]
    ]

  def application, do: [extra_applications: [:logger, :ssh], mod: {CommaSSH.Application, []}]
end
