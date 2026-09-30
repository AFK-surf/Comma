# Module name is intentionally NOT `Comma.MixProject` — that belongs to the
# umbrella root (../../mix.exs). This is the `:comma` launcher app's project.
defmodule Comma.Launcher.MixProject do
  use Mix.Project

  def project do
    [
      app: :comma,
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

  # The launcher deliberately has NO umbrella dependency on the subsystem apps:
  # it starts them by name at runtime (see Comma.Application), and in the release
  # they ship in `:load` mode. Depending on them here would force them to start
  # at boot, defeating per-pod selection.
  def application do
    [
      extra_applications: [:logger],
      mod: {Comma.Application, []}
    ]
  end

  defp deps do
    [{:systems_observability, in_umbrella: true}]
  end
end
