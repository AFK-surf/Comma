# Comma OAuth IdP canary (NextAuth)

A deliberately minimal, **unmodified** NextAuth (Auth.js v5) app used to
verify the Comma OAuth/OIDC IdP from a mainstream framework's default OIDC
integration. The CI canary (`systems/e2e/tests/oauth_idp_canary_test.ts`)
covers the protocol continuously with the openid-client library; this app is
the manual staging/production smoke with a real browser.

See docs/identity-security.md for the staging procedure.

## Quick start

1. Register a confidential client (Comma.OauthIdp.ClientAdmin.create/1) with
   redirect URI `http://127.0.0.1:8765/api/auth/callback/comma`.
2. `npm install`
3. Run with the issuer and credentials:

   ```bash
   AUTH_SECRET=$(openssl rand -base64 32) \
   COMMA_ISSUER=https://<comma-api-host> \
   COMMA_CLIENT_ID=<client id> \
   COMMA_CLIENT_SECRET=<client secret> \
   COMMA_REDIRECT_PROXY_URL=http://127.0.0.1:8765/api/auth \
   npm run dev
   ```

   `COMMA_REDIRECT_PROXY_URL` is required: `next dev` normalizes the
   request origin to `localhost` regardless of the visited host (and
   `AUTH_URL` is ignored for origins by Auth.js v5), while Comma registers
   loopback redirect URIs as IP literals only, per RFC 8252 §8.3. The
   variable feeds Auth.js's own `redirectProxyUrl` — a documented,
   IdP-agnostic setting — so the framework sends the registered
   `127.0.0.1` callback and handles the round trip itself.

4. Open http://127.0.0.1:8765, click **Continue with Comma**, sign in /
   consent on the Comma side, and confirm the page shows your `usr_*` id and
   email.

The dev server binds 127.0.0.1 only — it holds a real client secret and
must never listen on the LAN.

The page prints the session subject; the acceptance check is that it
shows your `usr_*` id. The `jwt`/`session` callbacks in `auth.ts` that
surface it are Auth.js's own documented pattern for exposing the OIDC
`sub` — identical for any IdP, so they do not violate the unmodified-
client rule. Anything COMMA-specific would.

This package is intentionally outside the pnpm workspace and every build
pipeline: it exists to be pointed at deployed environments by a human.
`AGENTS.md` is generated and maintained by `next dev`; it is committed
because the tool recreates it on every run.
