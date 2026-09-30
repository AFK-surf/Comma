defmodule AlertRouter.Repo do
  @moduledoc """
  Alert Router's PostgreSQL system of record.

  Deployments use a dedicated logical database and credentials on the existing
  environment Cloud SQL instance. That preserves a separate failure and
  migration boundary without introducing a new storage product.
  """

  use Ecto.Repo,
    otp_app: :alert_router,
    adapter: Ecto.Adapters.Postgres
end
