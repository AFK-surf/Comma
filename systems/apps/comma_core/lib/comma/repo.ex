defmodule Comma.Repo do
  @moduledoc "Comma-owned PostgreSQL repository. It never owns BFT or Billing facts."

  use Ecto.Repo,
    otp_app: :comma_core,
    adapter: Ecto.Adapters.Postgres
end
