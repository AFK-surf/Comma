defmodule CommaTUI.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :comma_tui,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      deps: [{:ucwidth, "~> 0.2.0"}]
    ]

  def application, do: [extra_applications: [:logger]]
end
