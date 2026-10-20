import { useTopic } from "@comma/core-client";
import { useCallback, useState } from "react";
import type { CommaRecommendationLinkPreview } from "@comma/core/api-schemas";

// Mirrors CommaWeb.RecommendationLinkPreview: GitHub pull requests, Linear
// issues, Notion pages, Google Calendar events (public ones render; the
// server keeps the rest link-only), Slack messages and Google Drive files.
// Outlook mail and events match by host; the server previews only an exact,
// currently collected member item. Gmail never matches.
const RICH_LINK_SHAPES = [
  /^https:\/\/(?:outlook\.office(?:365)?\.com|outlook\.live\.com)\//,
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
 * Whether hovering this link can show a rich preview, so unsupported links
 * never pay a request for a 404.
 */
export function hasRecommendationLinkPreview(href: string) {
  const trimmed = href.trim();
  return RICH_LINK_SHAPES.some((shape) => shape.test(trimmed));
}

/**
 * A link's rich preview, once its hover card has opened (`opened(true)`): `"loading"` until the core answers, then
 * the preview, or undefined when there is none (the generic card is the answer). Closing the card lets the preview
 * go: the link can be private, so the core reads it again for a later card.
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
    // Let go as the card closes, so the next card asks the server again.
    { lingerMs: 0 }
  );
  if (!shown) return [undefined, opened];
  if (!value || value.status === "loading") return ["loading", opened];
  return [value.status === "ready" ? value.preview : undefined, opened];
}
