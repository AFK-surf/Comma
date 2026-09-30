defmodule CommaWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :comma_web,
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
      mod: {CommaWeb.Application, []}
    ]
  end

  defp deps do
    [
      {:systems_observability, in_umbrella: true},
      {:billing_core, in_umbrella: true},
      {:billing_commerce, in_umbrella: true},
      {:billing_stripe, in_umbrella: true},
      {:comma_core, in_umbrella: true},
      {:salix_agent, in_umbrella: true},
      {:salix_cluster, in_umbrella: true},
      {:salix_im, in_umbrella: true},
      {:salix_mcp, in_umbrella: true},
      {:salix_web, in_umbrella: true},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.6"},
      {:floki, "~> 0.38"},
      {:oidcc, "~> 3.9"}
    ]
  end
end
