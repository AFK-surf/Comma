defmodule Comma.OauthIdp.HashedAccessTokens do
  @moduledoc """
  `Boruta.Oauth.AccessTokens` that stores only hashes at rest
  (decision D4 of docs/identity-security.md).

  The digest is written by the INSERT itself: the changeset built by
  `Boruta.Ecto.Token` carries the generated plaintext, and this adapter
  swaps it for `Comma.OauthIdp.hash_token/1` before the row ever reaches
  the database. The plaintext therefore never appears in a statement,
  the WAL, replication streams, or backups — not merely "not in the
  final row". The struct returned to the caller is the only place the
  plaintext exists.

  Lookups hash the presented plaintext before delegating, so the cache
  and database only ever key on digests.

  **No refresh tokens, ever** (v1 contract in docs/identity-security.md):
  Boruta's authorization-code flow asks for one, and this adapter is the
  enforcement point — the option is ignored, none is generated, and the
  returned struct always carries `refresh_token: nil`, so no client is
  handed a credential the contract says must not exist.
  """

  @behaviour Boruta.Oauth.AccessTokens

  import Boruta.Config, only: [repo: 0]
  import Ecto.Changeset, only: [get_change: 2, put_change: 3]

  alias Boruta.Ecto
  alias Boruta.Ecto.OauthMapper
  alias Boruta.Ecto.TokenStore
  alias Boruta.Oauth
  alias Comma.OauthIdp

  @impl Boruta.Oauth.AccessTokens
  def get_by(value: value) do
    Ecto.AccessTokens.get_by(value: OauthIdp.hash_token(value))
  end

  def get_by(refresh_token: refresh_token) do
    Ecto.AccessTokens.get_by(refresh_token: OauthIdp.hash_token(refresh_token))
  end

  @impl Boruta.Oauth.AccessTokens
  def create(
        %{client: %Oauth.Client{id: client_id, access_token_ttl: access_token_ttl}, scope: scope} =
          params,
        _options
      ) do
    token_attributes = %{
      client_id: client_id,
      sub: params[:sub],
      redirect_uri: params[:redirect_uri],
      state: params[:state],
      scope: scope,
      access_token_ttl: access_token_ttl,
      previous_token: params[:previous_token],
      previous_code: params[:previous_code]
    }

    # v1 issues no refresh tokens: always use the plain changeset, no
    # matter what the caller's options request (the core asks for one on
    # the authorization-code flow).
    changeset =
      Ecto.Token.changeset(
        %Ecto.Token{resource_owner: params[:resource_owner]},
        token_attributes
      )

    plaintext = get_change(changeset, :value)

    hashed_changeset = put_change(changeset, :value, OauthIdp.hash_token(plaintext))

    with {:ok, row} <- repo().insert(hashed_changeset),
         token = OauthMapper.to_oauth_schema(row),
         {:ok, _cached} <- TokenStore.put(token) do
      {:ok, %{token | value: plaintext, refresh_token: nil}}
    else
      {:error, changeset} ->
        {:error,
         "Could not create access token : #{Ecto.Errors.message_from_changeset(changeset)}"}
    end
  end

  @impl Boruta.Oauth.AccessTokens
  def revoke(%Oauth.Token{} = token) do
    Ecto.AccessTokens.revoke(token)
  end

  @impl Boruta.Oauth.AccessTokens
  def revoke_refresh_token(%Oauth.Token{} = token) do
    Ecto.AccessTokens.revoke_refresh_token(token)
  end
end
