import { useTopic } from "@comma/core-client";
import { useCallback, useState } from "react";
import type { CommaRecommendationLinkPreview } from "@comma/core/api-schemas";

// Mirrors CommaWeb.RecommendationLinkPreview: GitHub pull requests, Linear
// issues, Notion pages, Google Calendar events (public ones render; the
// server keeps the rest link-only), Slack messages and Google Drive files.
// Outlook and Gmail links match by host; the server previews only an exact,
// currently collected member item or owned Home MailInteraction entry.
const STILLFAIL_CHAT_LINK_SHAPE =
  /^https:\/\/(?:app\.youdid\.wtf|still\.fail)\/o\/[^/]+\/[^/]+\/[^/?#]+(?:[/?#].*)?$/;
const OUTLOOK_LINK_SHAPE =
  /^https:\/\/(?:outlook\.office(?:365)?\.com|outlook\.live\.com)\//;
const GMAIL_LINK_SHAPE = /^https:\/\/mail\.google\.com\//;

export function isStillfailChatLink(href: string) {
  return STILLFAIL_CHAT_LINK_SHAPE.test(href.trim());
}

export function isMailPreviewLink(href: string) {
  const trimmed = href.trim();
  return OUTLOOK_LINK_SHAPE.test(trimmed) || GMAIL_LINK_SHAPE.test(trimmed);
}

const RICH_LINK_SHAPES = [
  STILLFAIL_CHAT_LINK_SHAPE,
  OUTLOOK_LINK_SHAPE,
  GMAIL_LINK_SHAPE,
  /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+(?:[/?#].*)?$/,
  /^https:\/\/linear\.app\/[\w-]+\/issue\/[A-Za-z][A-Za-z0-9]*-\d+(?:[/?#].*)?$/,
  /^https:\/\/(?:www\.)?notion\.so\/(?:[^/?#]+\/)?(?:[^/?#]*?-)?[0-9a-fA-F]{32}(?:[/?#].*)?$/,
  /^https:\/\/(?:www\.google\.com|calendar\.google\.com)\/calendar\/(?:u\/\d+\/)?(?:r\/)?(?:event\?(?:[^#]*&)?eid=[\w=-]+|eventedit\/[\w=-]+)/,
  /^https:\/\/[\w-]+\.slack\.com\/archives\/([A-Z0-9]+)\/p(\d{10,})(?:[/?#].*)?$/,
  // Drive ids demand >= 10 chars (mirrors the server's hardening) so pseudo-id
  // path segments like the published-form `/d/e/` never read as a file id.
  /^https:\/\/docs\.google\.com\/(?:document|spreadsheets|presentation|forms)\/d\/([\w-]{10,})(?:[/?#].*)?$/,
  /^https:\/\/drive\.google\.com\/file\/d\/([\w-]{10,})(?:[/?#].*)?$/,
  /^https:\/\/drive\.google\.com\/open\?(?:[^#]*&)?id=([\w-]{10,})/,
];

/**
 * Provider resources use their authenticated reader. Other public HTTP pages
 * use website metadata. Unsupported private-service links remain link-only.
 */
export function hasRecommendationLinkPreview(href: string) {
  const trimmed = href.trim();
  if (RICH_LINK_SHAPES.some((shape) => shape.test(trimmed))) return true;
  try {
    const url = new URL(trimmed);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password)
      return false;
    if (trimmed.length > 2048 || (url.port && !["80", "443"].includes(url.port)))
      return false;
    const host = url.hostname.toLowerCase();
    if (
      [
        "slack.com",
        "notion.so",
        "notion.site",
        "linear.app",
        "still.fail",
        "app.youdid.wtf",
      ].some((domain) => host === domain || host.endsWith(`.${domain}`))
    )
      return false;
    return (
      ![
        "mail.google.com",
        "calendar.google.com",
        "docs.google.com",
        "drive.google.com",
      ].includes(host) &&
      !(host === "www.google.com" && url.pathname.startsWith("/calendar"))
    );
  } catch {
    return false;
  }
}

/**
 * A link's rich preview, once its hover card has opened (`opened(true)`): `"loading"` until the core answers, then
 * the preview, or undefined when there is none (the generic card is the answer). A later card shows the core's recent
 * preview at once while the core asks the server again (the link can be private).
 */
export function useLinkPreview(
  link: { workspaceId: string; href: string; sourceId?: string | undefined } | undefined
): [CommaRecommendationLinkPreview | "loading" | undefined, (open: boolean) => void] {
  const key =
    link && hasRecommendationLinkPreview(link.href)
      ? `${link.workspaceId} ${link.sourceId ?? ""} ${link.href.trim()}`
      : null;
  // The link whose card has opened: another link starts unasked.
  const [asked, setAsked] = useState<string | null>(null);
  const opened = useCallback(
    (open: boolean) => {
      setAsked(open ? key : null);
    },
    [key]
  );
  const shown = asked !== null && asked === key && link;
  const { value } = useTopic(
    shown
      ? {
          topic: "linkPreview",
          workspace: link.workspaceId,
          href: link.href,
          source: link.sourceId ?? "",
        }
      : null,
    // Let go as the card closes; the next card asks the server again.
    { lingerMs: 0 }
  );
  if (!shown) return [undefined, opened];
  if (!value || value.status === "loading") return ["loading", opened];
  return [value.status === "ready" ? value.preview : undefined, opened];
}
