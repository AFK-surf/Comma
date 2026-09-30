defmodule Comma.Repo.Migrations.AuthorizationCodeChains do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20221009122204_authorization_code_chains.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def change do
    # 20221009100713_add_previous_code_to_oauth_tokens.exs
    alter table(:oauth_tokens) do
      add(:previous_code, :string)
    end
  end
end
