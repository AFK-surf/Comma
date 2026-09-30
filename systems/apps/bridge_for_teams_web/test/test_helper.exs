# See apps/bridge_for_teams_core/test/test_helper.exs — same pattern. The web suite
# drives bridge_for_teams_core's repo, so migrate it once under a non-sandbox
# checkout, then run with the SQL sandbox in manual mode.
{:ok, _} = Application.ensure_all_started(:salix_web)
{:ok, _} = Application.ensure_all_started(:bridge_for_teams_core)
{:ok, _} = Application.ensure_all_started(:bridge_for_teams_web)

Ecto.Adapters.SQL.Sandbox.mode(BridgeForTeams.Repo, :manual)

Ecto.Adapters.SQL.Sandbox.checkout(BridgeForTeams.Repo, sandbox: false)
Ecto.Migrator.run(BridgeForTeams.Repo, :up, all: true)
Ecto.Adapters.SQL.Sandbox.checkin(BridgeForTeams.Repo)

{:ok, _} = Application.ensure_all_started(:billing_core)

unless Process.whereis(BillingCore.Repo) do
  {:ok, _pid} = BillingCore.Repo.start_link()
end

Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)

Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo, sandbox: false)
Ecto.Migrator.run(BillingCore.Repo, :up, all: true)
Ecto.Adapters.SQL.Sandbox.checkin(BillingCore.Repo)

ExUnit.start()

# Product tests start in the completed online-release state. Handoff regressions
# explicitly remove this marker to exercise mixed-version admission.
:ok = SalixStore.AgentConfigurationRollout.open()
:ok = SalixStore.AgentConfigurationRollout.complete()
