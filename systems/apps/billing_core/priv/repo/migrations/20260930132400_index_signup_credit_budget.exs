defmodule BillingCore.Repo.Migrations.IndexSignupCreditBudget do
  use Ecto.Migration

  def change do
    create(
      index(:credit_grants, [:inserted_at],
        name: :credit_grants_signup_budget_idx,
        where: "source_type = 'comma_signup'"
      )
    )
  end
end
