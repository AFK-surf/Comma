ExUnit.start()

# Tests check out Comma.Repo connections; do not depend on comma_core's helper
# having run first in this VM.
Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, :manual)
:ok = SystemsRuntime.DbClock.install!(Comma.Repo)

# One `mix test` VM runs several apps' suites in turn. Hand the next suite the
# Sandbox's initial :auto mode instead of this suite's :manual one.
ExUnit.after_suite(fn _ ->
  for repo <- [Comma.Repo], SystemsRuntime.Proc.whereis(repo) do
    Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)
  end
end)
