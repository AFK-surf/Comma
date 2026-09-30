defmodule SalixVoice.MixProject do
  use Mix.Project

  def project do
    [
      app: :salix_voice,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {SalixVoice.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # `salix_im` must never depend on this app: the voice provider reaches a
  # call only through `:pg` and messages (docs/messaging-voice.md).
  defp deps do
    [
      {:salix_store, in_umbrella: true},
      {:salix_agent, in_umbrella: true},
      {:salix_im, in_umbrella: true},
      {:salix_cluster, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:websockex, "~> 0.5"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.16"},
      {:telemetry, "~> 1.2"},
      {:bandit, "~> 1.5", only: :test},
      {:websock_adapter, "~> 0.5", only: :test}
    ]
  end
end
