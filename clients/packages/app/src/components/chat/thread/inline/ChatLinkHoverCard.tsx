import { HoverCard } from "@comma/ui/components/hover-card";
import { isValidElement, useMemo, type ReactElement, type ReactNode } from "react";
import {
  describeLinkDestination,
  LinkPreviewCard,
  LinkPreviewSkeleton,
  LinkProviderIcon,
  providerFromHref,
} from "../../../links/linkPreviewCards";
import { useLinkPreview } from "../../../links/useLinkPreview";

/**
 * Hovering an external chat message link, or a link inside a widget card,
 * previews where it goes. A link the
 * server can read opens on the rich card's skeleton and settles into the card
 * itself; every other link shows the generic destination tile (provider mark,
 * the link's own label, app · host/path). The fetch is lazy — nothing loads
 * until the card first opens — and a failed read falls back to that tile.
 */
export function ChatLinkHoverCard({
  anchor,
  href,
  label: givenLabel,
  open: hoverOpen,
  workspaceId,
}: {
  anchor: ReactElement;
  href: string;
  /** The link's visible text when `anchor` does not carry it. */
  label?: string | undefined;
  /** Set when the hover happens where `anchor` cannot see it (see HoverCard). */
  open?: boolean | undefined;
  workspaceId: string;
}) {
  // Read lazily: nothing loads until the card first opens.
  const [preview, handleOpenChange] = useLinkPreview({ workspaceId, href });
  const source = useMemo(() => providerFromHref(href), [href]);
  const label = useMemo(
    () => givenLabel?.trim() || anchorLabel(anchor, href),
    [anchor, givenLabel, href]
  );

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
      open={hoverOpen}
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
