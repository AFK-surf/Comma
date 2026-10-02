import { HoverCard } from "@comma/ui";
import {
  isValidElement,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactElement,
  type ReactNode,
} from "react";
import type { CommaApiClient, CommaRecommendationLinkPreview } from "../../../../api";
import {
  describeLinkDestination,
  LinkPreviewCard,
  LinkPreviewSkeleton,
  LinkProviderIcon,
  providerFromHref,
} from "../../../links/linkPreviewCards";
import {
  hasRecommendationLinkPreview,
  loadRecommendationLinkPreview,
  peekRecommendationLinkPreview,
} from "../../../recommendations/linkPreviewCache";

/**
 * Hovering an external chat message link previews where it goes. A link the
 * server can read opens on the rich card's skeleton and settles into the card
 * itself; every other link shows the generic destination tile (provider mark,
 * the link's own label, app · host/path). The fetch is lazy — nothing loads
 * until the card first opens — and a failed read falls back to that tile.
 */
export function ChatLinkHoverCard({
  anchor,
  api,
  href,
  workspaceId,
}: {
  anchor: ReactElement;
  api: CommaApiClient;
  href: string;
  workspaceId: string;
}) {
  const [preview, setPreview] = useState<CommaRecommendationLinkPreview | "loading">();
  const requestGeneration = useRef(0);
  const source = useMemo(() => providerFromHref(href), [href]);
  const label = useMemo(() => anchorLabel(anchor, href), [anchor, href]);

  // MarkdownStream only invokes the link decorator once the stream is final
  // (see MarkdownStreamLinkDecorator's finality guarantee), so `href` never
  // changes over this card's lifetime. The reset below is therefore only
  // reachable via api/workspace swaps — the href dependency is kept as
  // harmless belt-and-braces should that contract ever loosen.
  useEffect(() => {
    requestGeneration.current += 1;
    setPreview(undefined);
    return () => {
      requestGeneration.current += 1;
    };
  }, [api, href, workspaceId]);

  const handleOpenChange = (open: boolean) => {
    if (!open || preview !== undefined || !hasRecommendationLinkPreview(href)) return;
    // A settled answer renders at once: no skeleton flash, no request.
    const cached = peekRecommendationLinkPreview(api, workspaceId, { href });
    if (cached === "missing") return;
    if (cached) {
      setPreview(cached);
      return;
    }
    const generation = ++requestGeneration.current;
    setPreview("loading");
    void loadRecommendationLinkPreview(api, workspaceId, { href }).then(
      (next) => {
        if (requestGeneration.current === generation) setPreview(next);
      },
      () => {
        // Unavailable: the generic card is the complete answer.
        if (requestGeneration.current === generation) setPreview(undefined);
      }
    );
  };

  const destination = describeLinkDestination(href);
  return (
    <HoverCard
      className={
        preview
          ? "comma-recommendation-prompt-hover-card comma-recommendation-link-hover-card comma-recommendation-rich-link-hover-card"
          : "comma-recommendation-prompt-hover-card comma-recommendation-link-hover-card"
      }
      content={
        preview === "loading" ? (
          <LinkPreviewSkeleton />
        ) : preview ? (
          <LinkPreviewCard preview={preview} source={source} />
        ) : (
          <div className="comma-recommendation-link-preview">
            <span
              aria-hidden="true"
              className="comma-recommendation-link-preview-thumb"
            >
              <LinkProviderIcon source={source} />
            </span>
            <div className="comma-recommendation-link-preview-body">
              <strong>{label}</strong>
              <span className="comma-recommendation-link-preview-url" title={href}>
                {source?.appName ? `${source.appName} · ${destination}` : destination}
              </span>
            </div>
          </div>
        )
      }
      onOpenChange={handleOpenChange}
      placement="bottom start"
    >
      {anchor}
    </HoverCard>
  );
}

/** The anchor's visible text, falling back to the link's host. */
function anchorLabel(anchor: ReactElement, href: string) {
  const text = reactNodeText(anchor).trim();
  if (text) return text;
  try {
    return new URL(href).host;
  } catch {
    return href;
  }
}

// MarkdownStream's anchor children are not always plain strings: streamed text
// renders as elements carrying a string `content` prop, and nested inline
// nodes hold their text inside a markdown `node` structure. Walk all three
// shapes; anything unreadable degrades to the host fallback above.
function reactNodeText(node: ReactNode): string {
  if (typeof node === "string") return node;
  if (typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(reactNodeText).join("");
  if (!isValidElement(node)) return "";
  const props = node.props as {
    children?: ReactNode;
    content?: unknown;
    node?: unknown;
  };
  if (typeof props.content === "string") return props.content;
  if (props.node !== undefined) {
    const fromNode = markdownNodeText(props.node);
    if (fromNode) return fromNode;
  }
  return reactNodeText(props.children);
}

function markdownNodeText(node: unknown): string {
  if (!node || typeof node !== "object") return "";
  const value = node as {
    children?: unknown;
    content?: unknown;
    raw?: unknown;
    text?: unknown;
  };
  if (typeof value.content === "string") return value.content;
  if (Array.isArray(value.children) && value.children.length > 0) {
    return value.children.map(markdownNodeText).join("");
  }
  if (typeof value.text === "string") return value.text;
  if (typeof value.raw === "string") return value.raw;
  return "";
}
