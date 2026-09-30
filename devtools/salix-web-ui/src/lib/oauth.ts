// Provider names supported by the managed-OAuth backend. Mirrors
// internal/oauth.Provider* constants in Go.
export const KNOWN_OAUTH_PROVIDERS = [
  "github",
  "google",
  "linear",
  "notion",
  "slack",
] as const;

export type OAuthProviderName = (typeof KNOWN_OAUTH_PROVIDERS)[number];

export function oauthProviderLabel(p: string): string {
  switch (p) {
    case "github":
      return "GitHub";
    case "google":
      return "Google";
    case "linear":
      return "Linear";
    case "notion":
      return "Notion";
    case "slack":
      return "Slack";
    default:
      return p.charAt(0).toUpperCase() + p.slice(1);
  }
}

export function defaultOAuthScopes(p: string): string {
  switch (p) {
    case "github":
      return "repo workflow";
    case "google":
      // OpenID minimum scopes; the backend always includes openid/email/profile
      // to resolve the authorizing user. Add Google API scopes here as needed.
      return "openid email profile";
    case "linear":
      return "read";
    case "slack":
      // User-on-behalf-of scopes; passed to Slack as `user_scope`.
      return "chat:write channels:read users:read";
    default:
      return "";
  }
}
