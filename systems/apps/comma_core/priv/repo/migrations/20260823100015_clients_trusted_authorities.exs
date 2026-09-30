defmodule Comma.Repo.Migrations.ClientsTrustedAuthorities do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20260531120000_clients_trusted_authorities.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def change do
    alter table(:oauth_clients) do
      add(:trusted_authorities, :text, default: "", null: false)
    end
  end
end
