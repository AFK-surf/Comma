ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(AlertRouter.Repo, :manual)
:ok = SystemsRuntime.DbClock.install!(AlertRouter.Repo)

# One `mix test` VM runs several apps' suites in turn. Hand the next suite the
# Sandbox's initial :auto mode instead of this suite's :manual one.
ExUnit.after_suite(fn _ ->
  for repo <- [AlertRouter.Repo], SystemsRuntime.Proc.whereis(repo) do
    Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)
  end
end)
