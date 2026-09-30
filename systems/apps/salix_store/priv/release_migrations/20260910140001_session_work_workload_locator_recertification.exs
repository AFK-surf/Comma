defmodule SalixStore.Repo.Migrations.SessionWorkWorkloadLocatorRecertification do
  @moduledoc """
  Exclusive strategy-v4 recertification of Session-work workload locators.

  The release step scans bounded Postgres candidate addresses and Session
  authority again after the workload locator column exists. It rebuilds the
  disposable projection and resumes forward from its durable cursor.
  """

  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    SalixAgent.Release.backfill_session_work(confirm_no_writers: true)
    :ok
  end
end
