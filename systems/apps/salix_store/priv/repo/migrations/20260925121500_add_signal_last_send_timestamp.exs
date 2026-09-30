defmodule SalixStore.Repo.Migrations.AddSignalLastSendTimestamp do
  use Ecto.Migration

  # The highest message timestamp (ms since the epoch) that the account's
  # owner committed before sending. A new owner starts above it, so the
  # account's send timestamps stay strictly increasing across owner changes
  # and clock differences between nodes (receivers drop a second message
  # with the same author and timestamp). Additive; 0 for existing rows.
  def change do
    alter table(:signal_accounts) do
      add(:last_send_timestamp, :bigint, null: false, default: 0)
    end
  end
end
