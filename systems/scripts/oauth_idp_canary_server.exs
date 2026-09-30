# Canary server for the OAuth IdP end-to-end test (docs/identity-security.md
# §11.2 PR 10). Boots the real comma_web HTTP surface with the IdP enabled,
# provisions a signing key, a user session, and a confidential client whose
# redirect URI comes from CANARY_REDIRECT_URI, then prints one ready line of
# JSON and blocks until stdin closes. Driven by
# e2e/tests/oauth_idp_canary_test.ts; run with MIX_ENV=test mix run.
#
# The user session is minted through the product session command rather than
# the OTP HTTP flow: the flow under test is the OIDC surface, not login.
# Everything from /oauth2/authorize onward happens over real HTTP driven by an
# unmodified OIDC client library on the Deno side.

redirect_uri = System.get_env("CANARY_REDIRECT_URI") || "http://127.0.0.1:8765/canary/callback"

# The IdP surface, off by default everywhere, is enabled for this process
# only; generous budgets keep the limiter out of the canary's way (its
# fail-closed behavior is covered by the PR 9 suites).
Application.put_env(:comma_web, :oauth_idp_enabled, true)

Application.put_env(:comma_core, :oauth_idp_rate_limit,
  token: [burst: 10_000, rate: 1000.0],
  authorize: [burst: 10_000, rate: 1000.0]
)

Application.put_env(:comma_core, :oauth_idp, kek: :crypto.hash(:sha256, "oauth-idp-canary-kek"))

{:ok, {_ip, port}} = ThousandIsland.listener_info(CommaWeb.HTTPServer)
base_url = "http://127.0.0.1:#{port}"

# The issuer is read from config on every request, so pointing it at the
# actual listener keeps discovery URLs, id_token iss, and the consent form's
# same-origin checks all anchored on one origin.
boruta_config = Application.get_env(:boruta, Boruta.Oauth)
Application.put_env(:boruta, Boruta.Oauth, Keyword.put(boruta_config, :issuer, base_url))

# Idempotent seeds: the script must be re-runnable against a dirty local DB.
# Every seed records whether THIS run created it — shutdown cleanup removes
# only what this run created, never shared state another consumer of the
# database (other clients' scopes, an existing signing key) depends on.
created_signing_key? =
  try do
    _ = Comma.OauthIdp.SigningKeys.signing_key!()
    false
  rescue
    _missing ->
      Comma.OauthIdp.SigningKeys.provision_initial!()
      true
  end

# No oauth_scopes rows are created: the v1 scope set is served from code by
# Comma.OauthIdp.Scopes, so the canary exercises the same unseeded state a
# fresh deployment has. Seeding here would hide an invalid_scope regression.

{:ok, user} = Comma.Accounts.get_or_create_user_by_email("oauth-idp-canary@example.com")
{:ok, session} = Comma.Accounts.create_session(user["id"])

# Reuse an earlier canary client when the local DB already has one with the
# same redirect URI, so repeated runs do not creep toward the client cap.
import Ecto.Query, only: [from: 2]

existing =
  Comma.Repo.one(
    from(client in Boruta.Ecto.Client,
      where: client.name == "oauth-idp-canary",
      order_by: [desc: client.inserted_at],
      limit: 1
    )
  )

client =
  case existing do
    %{redirect_uris: uris, id: id, secret: secret} = _reusable ->
      if redirect_uri in uris do
        %{"id" => id, "client_secret" => secret}
      else
        {:ok, created} =
          Comma.OauthIdp.ClientAdmin.create(%{
            "name" => "oauth-idp-canary",
            "redirect_uris" => [redirect_uri],
            "confidential" => true
          })

        created
      end

    nil ->
      {:ok, created} =
        Comma.OauthIdp.ClientAdmin.create(%{
          "name" => "oauth-idp-canary",
          "redirect_uris" => [redirect_uri],
          "confidential" => true
        })

      created
  end

ready = %{
  ready: true,
  base_url: base_url,
  client_id: client["id"],
  client_secret: client["client_secret"],
  redirect_uri: redirect_uri,
  cookie_name: CommaWeb.SessionCookie.cookie_name(),
  session_token: session["token"],
  user_id: user["id"],
  user_email: user["email"]
}

IO.puts("CANARY_READY " <> Jason.encode!(ready))

# Block until the driver closes stdin, then let the VM exit.
_ = IO.read(:stdio, :eof)

# Best-effort cleanup on the normal shutdown path so a later `mix test`
# against the same local database starts from the clean state its setups
# expect. Scoped strictly to what THIS run created: the canary client and
# its tokens/stashes, this run's session, and the scopes/signing key only
# when this run created them. A killed run may still leave rows; the seeds
# above stay idempotent for exactly that case.
{:ok, client_uuid} = Ecto.UUID.dump(client["id"])

Ecto.Adapters.SQL.query!(Comma.Repo, "DELETE FROM oauth_tokens WHERE client_id = $1", [client_uuid])

Ecto.Adapters.SQL.query!(
  Comma.Repo,
  "DELETE FROM comma_oauth_authorize_requests WHERE client_id = $1",
  [client_uuid]
)

Ecto.Adapters.SQL.query!(Comma.Repo, "DELETE FROM oauth_clients WHERE id = $1", [client_uuid])

if created_signing_key? do
  Ecto.Adapters.SQL.query!(Comma.Repo, "DELETE FROM comma_oauth_signing_keys", [])
end

{:ok, session_uuid} = Ecto.UUID.dump(session["id"])
Ecto.Adapters.SQL.query!(Comma.Repo, "DELETE FROM comma_auth_sessions WHERE id = $1", [session_uuid])
