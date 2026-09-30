defmodule Comma.Repo.Migrations.IdTokenSignatureAlgConfiguration do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20220603191707_id_token_signature_alg_configuration.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def change do
    # 20220603163123_add_id_token_signature_alg_to_clients.exs
    alter table(:oauth_clients) do
      add(:id_token_signature_alg, :string, default: "RS512")
    end
  end
end
