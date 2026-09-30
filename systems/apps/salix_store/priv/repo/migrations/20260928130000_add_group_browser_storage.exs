defmodule SalixStore.Repo.Migrations.AddGroupBrowserStorage do
  use Ecto.Migration

  def change do
    create table(:group_browser_storage, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:ciphertext, :text)
      add(:saved_at, :utc_datetime_usec)
      add(:deleted, :boolean, null: false, default: false)
    end

    alter table(:browser_bindings) do
      add(:storage_error, :text)
    end

    create(
      index(:browser_bindings, [:tenant_id, :group_id],
        where: "status <> 'closed'",
        name: :browser_bindings_active_group_index
      )
    )
  end
end
