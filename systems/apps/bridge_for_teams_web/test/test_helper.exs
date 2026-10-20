# See apps/bridge_for_teams_core/test/test_helper.exs — same pattern. The web suite
# drives bridge_for_teams_core's repo, so migrate it once under a non-sandbox
# checkout, then run with the SQL sandbox in manual mode.
{:ok, _} = Application.ensure_all_started(:salix_web)
{:ok, _} = Application.ensure_all_started(:bridge_for_teams_core)
{:ok, _} = Application.ensure_all_started(:bridge_for_teams_web)

Ecto.Adapters.SQL.Sandbox.mode(BridgeForTeams.Repo, :manual)
:ok = SystemsRuntime.DbClock.install!(BridgeForTeams.Repo)

Ecto.Adapters.SQL.Sandbox.checkout(BridgeForTeams.Repo, sandbox: false)
Ecto.Migrator.run(BridgeForTeams.Repo, :up, all: true)
Ecto.Adapters.SQL.Sandbox.checkin(BridgeForTeams.Repo)

{:ok, _} = Application.ensure_all_started(:billing_core)

unless SystemsRuntime.Proc.whereis(BillingCore.Repo) do
  {:ok, _pid} = BillingCore.Repo.start_link()
end

Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
:ok = SystemsRuntime.DbClock.install!(BillingCore.Repo)

Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo, sandbox: false)
Ecto.Migrator.run(BillingCore.Repo, :up, all: true)
Ecto.Adapters.SQL.Sandbox.checkin(BillingCore.Repo)

ExUnit.start()

# Product tests start in the completed online-release state. Handoff regressions
# explicitly remove this marker to exercise mixed-version admission.
:ok = SalixStore.AgentConfigurationRollout.open()
:ok = SalixStore.AgentConfigurationRollout.complete()

# Group Compute reads (the Project's Cloud VM) need the completed Compute
# authority handoff too; a fresh partition database has no marker yet.
SalixStore.Repo.query!("""
INSERT INTO salix_cutover_markers (name, completed_at, evidence)
VALUES ('group_compute_authority_v1', now(), '{"phase":"complete"}'::jsonb)
ON CONFLICT (name) DO UPDATE SET evidence = EXCLUDED.evidence
""")

# One `mix test` VM runs several apps' suites in turn. Hand the next suite the
# Sandbox's initial :auto mode instead of this suite's :manual one.
ExUnit.after_suite(fn _ ->
  for repo <- [BridgeForTeams.Repo, BillingCore.Repo], SystemsRuntime.Proc.whereis(repo) do
    Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)
  end
end)
