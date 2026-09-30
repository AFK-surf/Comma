defmodule SalixCalendar.MixProject do
  use Mix.Project

  def project do
    [
      app: :salix_calendar,
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
      extra_applications: [:logger],
      mod: {SalixCalendar.Application, []}
    ]
  end

  defp deps do
    [
      {:salix_store, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:tz, "~> 0.28"}
    ]
  end
end
