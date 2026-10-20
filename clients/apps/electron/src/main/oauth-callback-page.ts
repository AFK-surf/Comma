import type { CommaLocale } from "@comma/i18n";
import arrowSvg from "./assets/oauth-callback/arrow.svg?raw";
import commaSvg from "./assets/oauth-callback/comma.svg?raw";
import failedSvg from "./assets/oauth-callback/failed.svg?raw";
import googleSvg from "./assets/oauth-callback/google.svg?raw";

// Mirrors the Salix authorization callback page (SalixWeb.OAuthCallbackPage,
// Figma `P0HbtMUd3lTy0FcGn0ojxT` node `1618:14595`) so every browser hand-off
// back to Comma looks the same. The SVGs are copies of its Figma exports.
const style =
  "html,body{margin:0;height:100%;background:#fcfcfd;" +
  'font-family:"Inter Variable",Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;' +
  "-webkit-font-smoothing:antialiased}" +
  "body{display:flex;align-items:center;justify-content:center}" +
  "main{display:flex;flex-direction:column;align-items:center;gap:24px;" +
  "box-sizing:border-box;width:100%;max-width:514px;padding:0 16px 40px;text-align:center}" +
  ".logos{display:flex;align-items:center;gap:16px}" +
  ".tile{position:relative;box-sizing:border-box;width:56px;height:56px;overflow:hidden;" +
  "border:1px solid #dfe0e2;border-radius:11.667px;background:#fff;" +
  "box-shadow:0 1px 2px rgba(16,24,40,.05)}" +
  ".tile svg{position:absolute;top:-1px;left:-1px;width:56px;height:56px}" +
  ".logos>svg{display:block;flex:none}" +
  ".text{display:flex;flex-direction:column;gap:4px;width:100%;overflow-wrap:anywhere}" +
  "h1{margin:0;font-size:20px;font-weight:500;line-height:30px;letter-spacing:-.2px;color:#1b1c1d}" +
  "p{margin:0;font-size:16px;font-weight:400;line-height:24px;letter-spacing:-.16px;color:#5b5e62}";

export type OAuthCallbackPageState = "success" | "failed" | "plain";

/**
 * Renders the Google sign-in loopback page. `success` and `failed` show the
 * Comma ⇄ Google logos with an arrow or failure mark; `plain` shows only the
 * Comma logo for requests that are not part of a sign-in.
 */
export function renderOAuthCallbackPage({
  body,
  heading,
  locale,
  state,
}: {
  body?: string | undefined;
  heading: string;
  locale: CommaLocale;
  state: OAuthCallbackPageState;
}) {
  const logos =
    state === "plain"
      ? tile(commaSvg)
      : tile(commaSvg) + (state === "success" ? arrowSvg : failedSvg) + tile(googleSvg);

  return (
    `<!doctype html><html lang="${escapeHtml(locale)}"><head><meta charset="utf-8">` +
    `<title>${escapeHtml(heading)}</title>` +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    `<style>${style}</style></head><body><main>` +
    `<div class="logos">${logos}</div>` +
    `<div class="text"><h1>${escapeHtml(heading)}</h1>` +
    (body === undefined ? "" : `<p>${escapeHtml(body)}</p>`) +
    "</div></main></body></html>"
  );
}

function tile(svg: string) {
  return `<div class="tile">${svg}</div>`;
}

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
