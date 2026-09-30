defmodule BillingCore.Repo.Migrations.AddAdminCommandIdToRedeemCodes do
  use Ecto.Migration

  def change do
    alter table(:billing_redeem_codes) do
      add(:admin_command_id, :text)
    end

    create(
      unique_index(:billing_redeem_codes, [:admin_command_id],
        name: :billing_redeem_codes_admin_command_id_unique,
        where: "admin_command_id IS NOT NULL"
      )
    )
  end
end
