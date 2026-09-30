defmodule Comma.Repo.Migrations.OptionalPublicKeyForOauthClients do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20230524132504_optional_public_key_for_oauth_clients.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def up do
    # 20221108102337_optional_public_key_for_oauth_clients.exs
    alter table(:oauth_clients) do
      modify(:public_key, :text, null: true)
    end
  end

  def down do
    # 20221108102337_optional_public_key_for_oauth_clients.exs
    alter table(:oauth_clients) do
      modify(:public_key, :text, null: false)
    end
  end
end
