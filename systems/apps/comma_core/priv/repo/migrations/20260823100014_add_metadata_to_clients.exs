defmodule Comma.Repo.Migrations.AddMetadataToClients do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20230727181622_add_metadata_to_clients.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def change do
    # 20230727160245_add_metadata_to_clients.exs
    alter table(:oauth_clients) do
      add(:metadata, :jsonb, default: "{}", null: false)
      add(:logo_uri, :string)
    end
  end
end
