import { createHash } from "node:crypto";

// Only this fixed script may run on the credential callback page.
export const authorizationReturnScript = `
const returnLink = document.getElementById("comma-return");
const closeLater = () => window.setTimeout(() => window.close(), 1500);
returnLink?.addEventListener("click", closeLater);
if (document.body.dataset.autoClose === "true") closeLater();
`;
export const authorizationReturnCsp =
  "default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-" +
  createHash("sha256").update(authorizationReturnScript).digest("base64") +
  "'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

export type AuthorizationReturn = { url: string; open(): void };

export function isAuthorizationReturnUrl(value: string, scheme: string): boolean {
  try {
    const url = new URL(value);
    return (
      url.protocol === `${scheme}:` &&
      url.hostname === "authorization" &&
      url.pathname === "/return" &&
      !url.username &&
      !url.password &&
      !url.port &&
      !url.search &&
      !url.hash
    );
  } catch {
    return false;
  }
}
