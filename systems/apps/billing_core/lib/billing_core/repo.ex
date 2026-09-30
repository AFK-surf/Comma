defmodule BillingCore.Repo do
  @moduledoc "Neutral billing ledger Repo."

  use Ecto.Repo,
    otp_app: :billing_core,
    adapter: Ecto.Adapters.Postgres
end
