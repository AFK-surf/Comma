ExUnit.start()

# One `mix test` VM runs several apps' suites in turn. Hand the next suite the
# Sandbox's initial :auto mode instead of this suite's :manual one.
ExUnit.after_suite(fn _ ->
  for repo <- [BillingCore.Repo], SystemsRuntime.Proc.whereis(repo) do
    Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)
  end
end)
