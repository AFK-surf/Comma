defmodule Comma.Repo.Migrations.FenceTelegramConnectionAttempts do
  use Ecto.Migration

  def change do
    alter table(:comma_telegram_dm_claim_codes) do
      add(:consumed_at, :utc_datetime_usec)
    end

    alter table(:comma_telegram_oidc_attempts) do
      add(:consumed_at, :utc_datetime_usec)
    end
  end
end
