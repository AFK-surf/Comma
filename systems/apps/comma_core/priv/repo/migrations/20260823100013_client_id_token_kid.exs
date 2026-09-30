defmodule Comma.Repo.Migrations.ClientIdTokenKid do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20230525170834_client_id_token_kid.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def change do
    # 20230515150324_add_id_token_kid_to_clients.exs
    alter table(:oauth_clients) do
      add(:id_token_kid, :string)
    end
  end
end
