defmodule Comma.Repo.Migrations.CreateCommaAppAttestKeys do
  use Ecto.Migration

  def change do
    create table(:comma_app_attest_keys, primary_key: false) do
      add(:key_id, :text, primary_key: true)
      add(:email_fingerprint, :text, null: false)
      add(:app_id, :text, null: false)
      add(:environment, :text, null: false)
      add(:public_key, :binary, null: false)
      add(:counter, :bigint, null: false, default: 0)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:comma_app_attest_keys, [:email_fingerprint]))
  end
end
