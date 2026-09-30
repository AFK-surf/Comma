defmodule Comma.Repo.Migrations.SignedUserinfoResponse do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20221129125812_signed_userinfo_response.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def change do
    # 20221129094553_add_userinfo_signed_response_alg_to_oauth_clients.exs
    alter table(:oauth_clients) do
      add(:userinfo_signed_response_alg, :string)
    end
  end
end
