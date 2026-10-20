Code.require_file("support/repo_sandbox.ex", __DIR__)
Code.require_file("support/convergence.ex", __DIR__)
Code.require_file("support/workers.ex", __DIR__)

ExUnit.start(exclude: [:live_llm])

# Seed the migrated Salix baseline (cutover markers) in this VM's partition
# database. CI can run CommaWeb's files in a VM without any Salix or `comma`
# suite, and then nothing else seeds it.
SalixStore.RepoTestSetup.ensure!()

# Match the completed online-release state used by the other product suites,
# including when CommaWeb tests run without loading the BFT test helpers or
# after a suite that left other cutover markers behind.
SalixStore.RepoTestSetup.ensure!()
:ok = SalixStore.AgentConfigurationRollout.open()
:ok = SalixStore.AgentConfigurationRollout.complete()

# Tests check out Comma.Repo connections; do not depend on comma_core's helper
# having run first in this VM.
Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, :manual)
:ok = SystemsRuntime.DbClock.install!(Comma.Repo)

# One `mix test` VM runs several apps' suites in turn. Hand the next suite the
# Sandbox's initial :auto mode instead of this suite's :manual one.
ExUnit.after_suite(fn _ ->
  for repo <- [Comma.Repo, BillingCore.Repo], SystemsRuntime.Proc.whereis(repo) do
    Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)
  end
end)
