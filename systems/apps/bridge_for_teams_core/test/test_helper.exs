# Ensure the repo is started and migrated once, then run the suite with the
# Ecto SQL sandbox in manual mode (DataCase checks out per test).
#
# With the Sandbox pool, the migrator needs an owned connection: set :manual,
# check out a shared owner for the migration, then check it back in. Per-test
# checkouts happen in DataCase/ConnCase.
{:ok, _} = Application.ensure_all_started(:salix_web)
{:ok, _} = Application.ensure_all_started(:bridge_for_teams_core)

unless SystemsRuntime.Proc.whereis(Comma.Repo) do
  {:ok, _pid} = Comma.Repo.start_link()
end

# The shared Comma/BFT storage contract now crosses Comma's PostgreSQL account
# boundary. Prepare that repo here so this suite also works when invoked on its
# own instead of relying on comma_core's test helper having run first.
Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, :auto)
Ecto.Migrator.run(Comma.Repo, :up, all: true)
Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, :manual)
:ok = SystemsRuntime.DbClock.install!(Comma.Repo)

Ecto.Adapters.SQL.Sandbox.mode(BridgeForTeams.Repo, :auto)
Ecto.Migrator.run(BridgeForTeams.Repo, :up, all: true)
Ecto.Adapters.SQL.Sandbox.mode(BridgeForTeams.Repo, :manual)

# now() in these databases follows a manual SystemsClock.
:ok = SystemsRuntime.DbClock.install!(BridgeForTeams.Repo)
:ok = SystemsRuntime.DbClock.install!(SalixStore.Repo)

{:ok, _} = Application.ensure_all_started(:billing_core)

unless SystemsRuntime.Proc.whereis(BillingCore.Repo) do
  {:ok, _pid} = BillingCore.Repo.start_link()
end

Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :auto)
Ecto.Migrator.run(BillingCore.Repo, :up, all: true)
Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
:ok = SystemsRuntime.DbClock.install!(BillingCore.Repo)

# The connector e2e (real reference connector + salix HTTP + MinIO) is heavy and
# excluded by default; run it with `mix test --include connector_e2e`.
#
# `:live_llm` opens a socket to a real model provider and spends real quota, so
# it is excluded for the same reason and on the same terms: run it with
# `mix test --include live_llm --only live_llm`. Nothing in a normal suite may
# depend on a model being reachable.
ExUnit.start(exclude: [:connector_e2e, :live_llm])

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
  for repo <- [Comma.Repo, BridgeForTeams.Repo, BillingCore.Repo],
      SystemsRuntime.Proc.whereis(repo) do
    Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)
  end
end)
