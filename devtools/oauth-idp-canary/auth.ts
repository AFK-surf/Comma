import NextAuth from "next-auth";

// An UNMODIFIED NextAuth (Auth.js v5) configuration pointed at the Comma
// OAuth/OIDC IdP purely through its standard OIDC provider shape: discovery,
// PKCE, state, and nonce all come from the framework. The jwt/session
// callbacks below are Auth.js's own documented pattern for surfacing the
// OIDC subject into the session — identical for any IdP, not a Comma special
// case. If this app ever needs a COMMA-specific workaround, that is an IdP
// bug — file it.
export const { handlers, auth, signIn, signOut } = NextAuth({
  secret: process.env.AUTH_SECRET,
  providers: [
    {
      id: "comma",
      name: "Comma",
      type: "oidc",
      issuer: process.env.COMMA_ISSUER,
      clientId: process.env.COMMA_CLIENT_ID,
      clientSecret: process.env.COMMA_CLIENT_SECRET,
      authorization: { params: { scope: "openid email profile" } },
      redirectProxyUrl: process.env.COMMA_REDIRECT_PROXY_URL,
      checks: ["pkce", "state", "nonce"],
    },
  ],
  callbacks: {
    jwt({ token, profile }) {
      if (profile?.sub) token.sub = profile.sub;
      return token;
    },
    session({ session, token }) {
      if (token.sub) (session.user as { id?: string }).id = token.sub;
      return session;
    },
    // next dev normalizes its own origin to localhost, but the session
    // cookie is set by the OAuth callback, which arrives on the registered
    // 127.0.0.1 host — so the post-login landing page must stay on
    // 127.0.0.1 or the browser will not send the cookie. Standard
    // documented callback; nothing Comma-specific.
    redirect({ url, baseUrl }) {
      const target = new URL(url, baseUrl);
      if (target.hostname === "127.0.0.1") return target.href;
      return target.href.startsWith(baseUrl) ? target.href : baseUrl;
    },
  },
});
