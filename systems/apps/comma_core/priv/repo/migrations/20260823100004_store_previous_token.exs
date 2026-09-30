defmodule Comma.Repo.Migrations.StorePreviousToken do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20220109171634_store_previous_token.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def change do
    # 20220109161041_add_previous_token_to_oauth_tokens.exs
    alter table(:oauth_tokens) do
      add(:previous_token, :string)
    end
  end
end
