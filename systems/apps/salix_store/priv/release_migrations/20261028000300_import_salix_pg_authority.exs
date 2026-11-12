defmodule SalixStore.Repo.Migrations.ImportSalixPGAuthority do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    apply(Module.concat([Comma, Release]), :migrate_salix_pg_authority, [])
  end

  def down do
    raise "PG authority cutover requires forward repair with old writers stopped"
  end
end
