defmodule Comma.Repo.Migrations.ClientsJwksUri do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20230514152712_clients_jwks_uri.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def change do
    # 20230514122748_add_jwks_uri_to_clients.exs
    alter table(:oauth_clients) do
      add(:jwks_uri, :string)
    end
  end
end
