defmodule Comma.Repo.Migrations.IndexSignupCreditCandidates do
  use Ecto.Migration

  def change do
    create(
      index(:comma_users, [:inserted_at, :id],
        name: :comma_signup_candidates_idx,
        where: "signup_credit_eligible = true AND status = 'active'"
      )
    )
  end
end
