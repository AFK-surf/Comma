defmodule Comma.Repo.Migrations.PreserveLegacyCommaUserIds do
  use Ecto.Migration

  def up do
    drop_if_exists(constraint(:comma_users, :comma_users_public_id_valid))

    create(
      constraint(:comma_users, :comma_users_public_id_valid,
        check:
          "id ~ '^usr_[A-Za-z0-9_-]+$' OR id ~ '^usr-[A-Za-z0-9_-]+$' OR id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'"
      )
    )
  end

  def down do
    raise "grandfathered Comma public IDs are a forward-only compatibility contract"
  end
end
