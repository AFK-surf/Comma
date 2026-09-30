defmodule Comma.Repo.Migrations.ConfidentialClients do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20220625210731_confidential_clients.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def change do
    # 20220625090332_add_confidential_to_oauth_clients.exs
    alter table(:oauth_clients) do
      add(:confidential, :boolean, default: false, null: false)
    end
  end
end
