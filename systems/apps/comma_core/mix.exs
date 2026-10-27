defmodule CommaCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :comma_core,
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
      mod: {CommaCore.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:systems_clock, in_umbrella: true},
      {:systems_runtime, in_umbrella: true},
      {:systems_observability, in_umbrella: true},
      {:billing_core, in_umbrella: true},
      {:salix_store, in_umbrella: true},
      {:salix_agent, in_umbrella: true},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:oban, "~> 2.23"},
      {:phoenix_pubsub, "~> 2.1"},
      {:redix, "~> 1.5"},
      {:hammer_backend_redis, "~> 7.1"},
      {:oidcc, "~> 3.7"},
      {:jose, "~> 1.11"},
      {:boruta, "~> 2.3.8"},
      {:goth, "~> 1.4"},
      {:ex_aws, "~> 2.7"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},
      {:plug_crypto, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:ex_json_schema, "~> 0.11"},
      {:req, "~> 0.6"},
      {:posthog, "~> 2.16"},
      {:gen_smtp, "~> 1.3"}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: [&prepare_test_database/1, "test"]
    ]
  end

  defp prepare_test_database(_args) do
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
  end
end
