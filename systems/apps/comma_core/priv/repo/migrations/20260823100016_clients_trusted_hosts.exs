defmodule Comma.Repo.Migrations.ClientsTrustedHosts do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20260728120000_clients_trusted_hosts.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def change do
    alter table(:oauth_clients) do
      add(:trusted_hosts, {:array, :text}, default: [], null: false)
    end
  end
end
