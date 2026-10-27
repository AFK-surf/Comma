# Multi-node tests start BEAM distribution for the whole umbrella VM. Running
# them in the default suite changes Node.self/0 after earlier applications have
# created owner records as :nonode@nohost, so keep them in the dedicated CI
# integration stage.
ExUnit.start(exclude: [:multinode, :live_llm])

# Match the completed online-release state the CommaWeb and BFT helpers set:
# whether it holds must not depend on which app's tests the shard ran first.
:ok = SalixStore.AgentConfigurationRollout.open()
:ok = SalixStore.AgentConfigurationRollout.complete()

Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, :manual)
:ok = SystemsRuntime.DbClock.install!(Comma.Repo)

# BillingCore.Repo is started and migrated once, here, and left in :manual: each test that writes to it checks a
# connection out (`Ecto.Adapters.SQL.Sandbox.start_owner!/2` or `checkout/1`). A module that started, migrated or
# switched it itself made the next module's result depend on which ran first.
unless SystemsRuntime.Proc.whereis(BillingCore.Repo) do
  {:ok, _pid} = BillingCore.Repo.start_link()
end

Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :auto)
Ecto.Migrator.run(BillingCore.Repo, :up, all: true)
Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)

# One `mix test` VM runs several apps' suites in turn. Hand the next suite the
# Sandbox's initial :auto mode instead of this suite's :manual one.
ExUnit.after_suite(fn _ ->
  for repo <- [Comma.Repo, BillingCore.Repo], SystemsRuntime.Proc.whereis(repo) do
    Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)
  end
end)
