defmodule BridgeForTeams.Release do
  @moduledoc """
  Release-time DB tasks (design §8): `bin/comma eval "BridgeForTeams.Release.migrate()"`.
  No Mix at runtime — loads the app and runs migrations directly.
  """
  @app :bridge_for_teams_core

  @doc "Run all pending migrations for the BridgeForTeams repo."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Run one Bridge storage metering pass."
  @spec run_storage_metering_once(keyword()) :: {:ok, [map()]}
  def run_storage_metering_once(opts \\ []) do
    load_app()

    summaries =
      for repo <- repos() do
        {:ok, summary, _started} =
          Ecto.Migrator.with_repo(repo, fn started_repo ->
            opts
            |> Keyword.put(:repo, started_repo)
            |> BridgeForTeams.StorageMetering.Reconciler.run_once()
          end)

        summary
      end

    {:ok, summaries}
  end

  @doc "Roll back the BridgeForTeams repo to `version`."
  @spec rollback(module(), non_neg_integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
