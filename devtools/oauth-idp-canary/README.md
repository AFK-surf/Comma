# Comma OAuth IdP canary (NextAuth)

A minimal, **unmodified** NextAuth (Auth.js v5) app. A human uses it to smoke
test the Comma OAuth/OIDC IdP in staging or production with a real browser.
The CI canary (`systems/e2e/tests/oauth_idp_canary_test.ts`) covers the
protocol continuously.

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

   `COMMA_REDIRECT_PROXY_URL` is required. `next dev` rewrites the request
   origin to `localhost`, but Comma registers loopback redirect URIs only as
   IP literals (RFC 8252 §8.3).

4. Open http://127.0.0.1:8765, click **Continue with Comma**, sign in /
   consent on the Comma side, and confirm the page shows your `usr_*` id and
   email.

The dev server binds 127.0.0.1 only. It holds a real client secret and must
never listen on the LAN.

Do not add Comma-specific code. The `jwt`/`session` callbacks in `auth.ts` are
the standard Auth.js pattern to show the OIDC `sub`.

This package is outside the pnpm workspace and all build pipelines.
`next dev` generates `AGENTS.md` on every run, so it stays committed.
