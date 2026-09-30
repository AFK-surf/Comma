defmodule BridgeForTeams.ReleaseMigrationE2ETest do
  @moduledoc """
  Release migration coverage for the repo lifecycle used by `bin/comma eval`.

  The Comma deployment job starts repos temporarily with `Ecto.Migrator.with_repo/2`.
  Progressive organization reconciliation is deliberately absent from this
  release entrypoint and is covered by canonical organization-write tests.
  """

  use ExUnit.Case, async: false

  alias BridgeForTeams.Repo

  setup do
    {:ok, _started} = Application.ensure_all_started(:bridge_for_teams_core)
    :ok
  end

  test "a real Bridge Repo query reaches the Prometheus scrape" do
    checkout_repos(fn ->
      Ecto.Adapters.SQL.query!(Repo, "SELECT 1", [])

      assert SystemsObservability.scrape() =~
               ~s(comma_system_db_queries_total{component="bridge_for_teams",operation="query",outcome="ok",repo="bft"})
    end)
  end

  defp checkout_repos(fun) do
    Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo, sandbox: false)
    Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
      Ecto.Adapters.SQL.Sandbox.checkin(BillingCore.Repo)
    end
  end
end
