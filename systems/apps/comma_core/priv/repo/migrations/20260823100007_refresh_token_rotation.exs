defmodule Comma.Repo.Migrations.RefreshTokenRotation do
  use Ecto.Migration

  # Vendored verbatim from boruta 2.3.8
  # (deps/boruta/priv/boruta/migrations/20220822204634_refresh_token_rotation.ex) so the executable
  # migration body is repo-owned and immutable: a future dependency upgrade
  # cannot change the DDL behind this already-applied migration ID, and the
  # release-manifest checksum covers the real operations.

  def change do
    # 20220810192111_add_refresh_token_revoked_at_to_tokens.exs
    alter table(:oauth_tokens) do
      add(:refresh_token_revoked_at, :utc_datetime_usec)
    end
  end
end
