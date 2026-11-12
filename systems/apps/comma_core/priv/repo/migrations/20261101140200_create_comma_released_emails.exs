defmodule Comma.Repo.Migrations.CreateCommaReleasedEmails do
  use Ecto.Migration

  # Keyed hashes of the emails accounts gave up by changing their email
  # (`Comma.EmailChange`). A new account with one gets no registration credits.
  def change do
    create table(:comma_released_emails, primary_key: false) do
      add(:email_hash, :binary, primary_key: true)
      add(:released_at, :utc_datetime_usec, null: false)
    end
  end
end
