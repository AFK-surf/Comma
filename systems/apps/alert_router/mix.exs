defmodule AlertRouter.MixProject do
  use Mix.Project

  def project do
    [
      app: :alert_router,
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
      mod: {AlertRouter.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:systems_observability, in_umbrella: true},
      # Use the read-only S3 modules without booting Salix's Repo/ID workers.
      {:salix_store, in_umbrella: true, runtime: false},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.20"},
      {:oban, "~> 2.23"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.6"},
      {:oidcc, "~> 3.7"}
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
