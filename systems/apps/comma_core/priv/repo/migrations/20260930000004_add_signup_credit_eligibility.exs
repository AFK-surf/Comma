defmodule Comma.Repo.Migrations.AddSignupCreditEligibility do
  use Ecto.Migration

  def change do
    alter table(:comma_users) do
      add(:signup_credit_eligible, :boolean, null: false, default: false)
    end
  end
end
