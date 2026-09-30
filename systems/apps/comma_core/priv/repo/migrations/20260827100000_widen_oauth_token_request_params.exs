defmodule Comma.Repo.Migrations.WidenOauthTokenRequestParams do
  use Ecto.Migration

  # RP-controlled authorization-request parameters have no length bound in
  # their specs: RFC 6749 §4.1.1 requires the AS to accept and echo `state`
  # opaquely (Auth.js sends an ~800-byte JWE), OIDC Core sets no bound on
  # `nonce`, and registered redirect URIs may be up to the admin command's
  # 512-byte cap while this column held 255. Boruta's stock schema sized all
  # three as varchar(255), so a standard NextAuth login crashed the consent
  # approve with a database error. varchar -> text is binary-compatible in
  # PostgreSQL: no table rewrite, no value changes, instant catalog update.
  def change do
    alter table(:oauth_tokens) do
      modify(:state, :text, from: :string)
      modify(:nonce, :text, from: :string)
      modify(:redirect_uri, :text, from: :string)
    end
  end
end
