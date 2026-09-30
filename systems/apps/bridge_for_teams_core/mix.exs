defmodule BridgeForTeamsCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :bridge_for_teams_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {BridgeForTeams.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:systems_observability, in_umbrella: true},
      {:billing_core, in_umbrella: true},
      {:billing_commerce, in_umbrella: true},
      # S3 reuse: SalixStore.Blob / SalixStore.S3 / SalixStore.Lease.
      {:salix_store, in_umbrella: true},
      # Shared URI-aware Google Meet classification/redaction contract.
      {:salix_calendar, in_umbrella: true},
      # Test the product-owned knowledge adapter through SalixAgent's exact
      # runtime context seam without making the production core start Agent.
      {:salix_agent, in_umbrella: true, only: :test, runtime: false},
      # Shared JSONL diagnostic logger (CommaLog), unified across subsystems.
      {:comma_log, in_umbrella: true},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.6"},
      {:hammer_backend_redis, "~> 7.1"},
      # JWT/JWK verification for OIDC id_tokens.
      {:jose, "~> 1.11"}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
