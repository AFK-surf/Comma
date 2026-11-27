defmodule SalixStore.Repo.Migrations.AddIFCBotPresence do
  use Ecto.Migration

  def change do
    alter table(:ifc_scope_facts) do
      add(:bot_present, :boolean)
    end
  end
end
