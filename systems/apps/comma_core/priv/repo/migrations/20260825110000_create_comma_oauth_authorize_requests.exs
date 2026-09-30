defmodule Comma.Repo.Migrations.CreateCommaOauthAuthorizeRequests do
  use Ecto.Migration

  # One-time server-side custody for in-flight authorization requests
  # (docs/comma-oauth-idp-rfc.md §5, §6.3): the consent POST trusts only the
  # handle, never resubmitted query parameters. Rows are single-use (CAS on
  # consumed_at), short-lived, and swept opportunistically on insert.
  # user_id is nullable on purpose: the logged-out redirect chain (PR 6)
  # stores the request before any user is known.
  def change do
    create table(:comma_oauth_authorize_requests, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:csrf_token, :text, null: false)
      add(:user_id, :text, null: true)
      add(:client_id, :uuid, null: false)
      add(:redirect_uri, :text, null: false)
      add(:scope, :text, null: false)
      add(:state, :text, null: true)
      add(:nonce, :text, null: true)
      add(:code_challenge, :text, null: false)
      add(:code_challenge_method, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec, null: true)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:comma_oauth_authorize_requests, [:expires_at]))
  end
end
