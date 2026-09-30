ExUnit.start()

Application.ensure_all_started(:billing_core)
Application.ensure_all_started(:billing_commerce)

unless Process.whereis(BillingCore.Repo) do
  {:ok, _pid} = BillingCore.Repo.start_link()
end

Ecto.Migrator.run(BillingCore.Repo, :up, all: true)
Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)

ExUnit.after_suite(fn _ ->
  Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :auto)
end)
