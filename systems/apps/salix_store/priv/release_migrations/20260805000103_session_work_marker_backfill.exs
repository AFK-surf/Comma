defmodule SalixStore.Repo.Migrations.SessionWorkMarkerBackfill do
  @moduledoc """
  Exclusive projection of pre-head agent-local Session-work markers.

  The release controller runs this idempotent, cursor-persisted step at zero
  writers after the old-binary drain and rollback floor. The serving runtime
  never scans the legacy corpus.
  """

  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    SalixAgent.Release.backfill_session_work(confirm_no_writers: true)
    :ok
  end
end
