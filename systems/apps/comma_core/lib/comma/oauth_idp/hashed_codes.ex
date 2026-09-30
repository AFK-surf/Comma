defmodule Comma.OauthIdp.HashedCodes do
  @moduledoc """
  `Boruta.Oauth.Codes` with hashed-at-rest storage (decision D4) and
  atomic single-use consumption.

  **Hashing**: like `Comma.OauthIdp.HashedAccessTokens`, the digest is
  written by the INSERT itself — the plaintext code never reaches the
  database layer, so it cannot land in the WAL, replication streams, or
  backups, and no failure between statements can strand a plaintext row.

  **Atomic consumption**: Boruta's core validates a code in three
  separate steps (`get_by` → PKCE check → `ensure_valid`) and only
  revokes it after issuing tokens, so concurrent redemptions of one code
  can all pass validation. This adapter moves consumption into `get_by`:
  a single `UPDATE ... SET revoked_at = now() WHERE ... AND revoked_at
  IS NULL` claims the code, and the database guarantees exactly one
  winner. Every other concurrent or later attempt sees `nil` and fails
  with `invalid_grant`. A failed exchange (wrong verifier) also burns
  the code — deliberately: an authorization code is single-presentation,
  and a probe by an attacker must not leave it alive.

  The struct returned by a successful claim carries `revoked_at: nil`
  so the core's own validity check passes for the single winner; the
  core's post-issuance `revoke/1` then finds the row already revoked and
  is a no-op timestamp overwrite.
  """

  @behaviour Boruta.Oauth.Codes

  import Boruta.Config, only: [repo: 0]
  import Ecto.Changeset, only: [get_change: 2, put_change: 3]
  import Ecto.Query, only: [from: 2]

  alias Boruta.Ecto
  alias Boruta.Ecto.OauthMapper
  alias Boruta.Oauth
  alias Comma.OauthIdp

  @impl Boruta.Oauth.Codes
  def get_by(value: value, redirect_uri: redirect_uri) do
    hashed = OauthIdp.hash_token(value)

    claim =
      from(t in Ecto.Token,
        where:
          t.type == "code" and t.value == ^hashed and t.redirect_uri == ^redirect_uri and
            is_nil(t.revoked_at)
      )

    case repo().update_all(claim, set: [revoked_at: DateTime.utc_now()]) do
      {1, _} ->
        row = repo().one!(from(t in Ecto.Token, where: t.type == "code" and t.value == ^hashed))
        %{OauthMapper.to_oauth_schema(row) | revoked_at: nil}

      {0, _} ->
        nil
    end
  end

  @impl Boruta.Oauth.Codes
  def create(
        %{
          client:
            %Oauth.Client{id: client_id, authorization_code_ttl: authorization_code_ttl} = client,
          resource_owner: resource_owner,
          redirect_uri: redirect_uri,
          scope: scope,
          state: state,
          code_challenge: code_challenge,
          code_challenge_method: code_challenge_method
        } = params
      ) do
    changeset =
      apply(Ecto.Token, changeset_method(client), [
        %Ecto.Token{resource_owner: resource_owner},
        %{
          client_id: client_id,
          sub: params[:sub],
          redirect_uri: redirect_uri,
          state: state,
          nonce: params[:nonce],
          scope: scope,
          authorization_code_ttl: authorization_code_ttl,
          code_challenge: code_challenge,
          code_challenge_method: code_challenge_method
        }
      ])

    plaintext = get_change(changeset, :value)

    hashed_changeset =
      put_change(changeset, :value, OauthIdp.hash_token(plaintext))

    case repo().insert(hashed_changeset) do
      {:ok, row} ->
        {:ok, %{OauthMapper.to_oauth_schema(row) | value: plaintext}}

      {:error, changeset} ->
        {:error, "Could not create code : #{Ecto.Errors.message_from_changeset(changeset)}"}
    end
  end

  @impl Boruta.Oauth.Codes
  def revoke(%Oauth.Token{} = code) do
    Ecto.Codes.revoke(code)
  end

  @impl Boruta.Oauth.Codes
  def revoke_previous_token(%Oauth.Token{} = code) do
    Ecto.Codes.revoke_previous_token(code)
  end

  defp changeset_method(%Oauth.Client{pkce: false}), do: :code_changeset
  defp changeset_method(%Oauth.Client{pkce: true}), do: :pkce_code_changeset
end
