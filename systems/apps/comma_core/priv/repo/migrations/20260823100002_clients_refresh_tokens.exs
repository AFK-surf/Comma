defmodule Comma.Repo.Migrations.ClientsRefreshTokens do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20210916124216_clients_refresh_tokens.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def change do
    # 20210904185118_add_public_refresh_token_to_clients.exs
    alter table(:oauth_clients) do
      add(:public_refresh_token, :boolean, null: false, default: false)
    end

    # 20210914115259_add_refresh_token_ttl_to_clients.exs
    alter table(:oauth_clients) do
      add(:refresh_token_ttl, :integer, null: false, default: "2592000")
    end
  end
end
