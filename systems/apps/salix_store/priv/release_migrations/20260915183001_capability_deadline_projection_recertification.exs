defmodule SalixStore.Repo.Migrations.CapabilityDeadlineProjectionRecertification do
  @moduledoc """
  Recertify indexed Session work with capability deadlines using strategy v5.

  The existing exclusive backfill pages candidate addresses and local work
  markers. It preserves Session and capability-request facts and rebuilds only
  their recovery projection. A stored cursor resumes an interrupted pass.
  This migration does not write to providers.
  """

  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    SalixAgent.Release.backfill_session_work(confirm_no_writers: true)
    :ok
  end
end
