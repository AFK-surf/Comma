defmodule Comma.Repo.Migrations.ClientsPublicRevoke do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20211010220831_clients_public_revoke.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def up do
    # 20210926200753_add_public_revoke_to_clients.exs
    alter table(:oauth_clients) do
      add(:public_revoke, :boolean, null: false, default: false)
    end

    # 20210926205845_add_revoke_and_introspect_to_clients_supported_grant_types.exs
    execute("""
    ALTER TABLE oauth_clients
      ALTER COLUMN supported_grant_types TYPE varchar(255)[]
        USING (supported_grant_types || ARRAY['revoke'::varchar(255), 'introspect'::varchar(255)])
    """)

    execute("""
     ALTER TABLE oauth_clients
       ALTER COLUMN supported_grant_types
         SET DEFAULT ARRAY['client_credentials', 'password', 'authorization_code', 'refresh_token', 'implicit', 'revoke', 'introspect']
    """)
  end

  def down do
    # 20210926205845_add_revoke_and_introspect_to_clients_supported_grant_types.exs

    execute("""
    ALTER TABLE oauth_clients
      ALTER COLUMN supported_grant_types TYPE varchar(255)[]
        USING array_remove(supported_grant_types, 'revoke')
    """)

    execute("""
    ALTER TABLE oauth_clients
      ALTER COLUMN supported_grant_types TYPE varchar(255)[]
        USING array_remove(supported_grant_types, 'introspect')
    """)

    execute("""
     ALTER TABLE oauth_clients
       ALTER COLUMN supported_grant_types
         SET DEFAULT ARRAY['client_credentials', 'password', 'authorization_code', 'refresh_token', 'implicit']
    """)

    # 20210926200753_add_public_revoke_to_clients.exs
    alter table(:oauth_clients) do
      remove(:public_revoke)
    end
  end
end
