Application.ensure_all_started(:billing_core)
Application.ensure_all_started(:billing_commerce)
Application.ensure_all_started(:billing_stripe)

unless Process.whereis(BillingCore.Repo) do
  {:ok, _pid} = BillingCore.Repo.start_link()
end

Ecto.Migrator.with_repo(BillingCore.Repo, &Ecto.Migrator.run(&1, :up, all: true))
Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)

ExUnit.after_suite(fn _ ->
  Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :auto)
end)

ExUnit.start()
