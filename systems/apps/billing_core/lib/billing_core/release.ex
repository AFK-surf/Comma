defmodule BillingCore.Release do
  @moduledoc """
  Release-time DB tasks for the BillingCore repo.

  Runs without Mix in the release container, matching the Bridge release entrypoint.
  """

  @app :billing_core

  @doc "Run all pending migrations for configured BillingCore repos."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Replay pending charges after pricing catalog or metering normalization changes."
  @spec replay_pending_charges(keyword()) :: [map()]
  def replay_pending_charges(opts \\ []) do
    load_app()

    for repo <- repos() do
      {:ok, summary, _started} =
        Ecto.Migrator.with_repo(repo, fn started_repo ->
          # PricingBackfill.run/1 only accepts a map; a keyword list would
          # fall through to the {:error, :missing_state} clause.
          opts
          |> Map.new()
          |> Map.put(:repo, started_repo)
          |> BillingCore.Metering.PricingBackfill.run()
        end)

      summary
    end
  end

  @doc "Backfill historical LLM provider/sku data for at most the last seven days."
  @spec backfill_historical_llm(keyword()) :: [map()]
  def backfill_historical_llm(opts \\ []) do
    load_app()

    for repo <- repos() do
      {:ok, summary, _started} =
        Ecto.Migrator.with_repo(repo, fn started_repo ->
          opts
          |> Keyword.put(:repo, started_repo)
          |> BillingCore.Metering.HistoricalLLMBackfill.run()
        end)

      summary
    end
  end

  defp repos do
    Application.get_env(@app, :ecto_repos, [])
  end

  defp load_app do
    Application.load(@app)
  end
end
