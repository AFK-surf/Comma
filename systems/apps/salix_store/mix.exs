defmodule SalixStore.MixProject do
  use Mix.Project

  def project do
    [
      app: :salix_store,
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

  defp aliases do
    [
      test: [&prepare_test_database/1, "test"]
    ]
  end

  defp prepare_test_database(_args) do
    Mix.Task.run("ecto.create", ~w(--quiet -r SalixStore.Repo))
    Mix.Task.run("ecto.migrate", ~w(--quiet -r SalixStore.Repo))
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {SalixStore.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:comma_log, in_umbrella: true},
      {:systems_observability, in_umbrella: true},
      {:systems_clock, in_umbrella: true},
      {:systems_runtime, in_umbrella: true},
      {:ecto_sql, "~> 3.12"},
      {:oban, "~> 2.23"},
      {:phoenix_pubsub, "~> 2.1"},
      {:postgrex, "~> 0.19"},
      {:protobuf, "~> 0.17"},
      {:req, "~> 0.5"},
      {:finch, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:redix, "~> 1.5"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:bandit, "~> 1.5", only: :test},
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
