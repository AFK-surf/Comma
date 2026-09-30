defmodule SalixStore.Repo.Migrations.SessionWorkProjectionRecertification do
  @moduledoc """
  Exclusive strategy-v3 recertification of Session-work projection coverage.

  This has a new release-ledger version so deployments that already recorded
  the original cutover still run the PG-address reconciliation and write
  current versioned terminal evidence. It resumes forward-only at zero writers.
  """

  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    SalixAgent.Release.backfill_session_work(confirm_no_writers: true)
    :ok
  end
end
