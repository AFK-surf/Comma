defmodule Comma.Repo.Migrations.AddSignupCreditGmailClaim do
  use Ecto.Migration

  def change do
    alter table(:comma_users) do
      add(:signup_credit_gmail_claimed, :boolean, null: false, default: false)
    end

    create(
      index(
        :comma_users,
        ["(replace(split_part(split_part(normalized_email, '@', 1), '+', 1), '.', ''))"],
        name: :comma_users_registered_gmail_local_index,
        where: "kind = 'registered' AND split_part(normalized_email, '@', 2) = 'gmail.com'"
      )
    )
  end
end
