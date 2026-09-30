import type { ReactNode } from "react";
import { recommendationLinkHrefAttribute } from "./recommendationLinkMenu";

// Parse only supported source tokens. Everything else remains React text,
// including HTML, unsupported schemes, and unresolved provider syntax.
export function SourceContext({
  text,
  sourceHref,
  onOpenUrl,
}: {
  text: string;
  sourceHref: string;
  onOpenUrl: (url: string) => void;
}) {
  const decoded = text
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
  const tokens =
    /<[@#][A-Z0-9]+(?:\|[^<>]+)?>|<https?:\/\/[^<>]+>|\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)|https?:\/\/[^\s<>"']+/g;
  const parts: ReactNode[] = [];
  let cursor = 0;
  for (const match of decoded.matchAll(tokens)) {
    parts.push(decoded.slice(cursor, match.index));
    const raw = match[0];
    let href: string | undefined;
    let label = raw;
    let trailing = "";
    if (/^<[@#]/.test(raw)) {
      const [id, name] = raw.slice(2, -1).split("|");
      label = raw[1] + (name || id!);
      const source = safeHttpUrl(sourceHref);
      // A Slack user/channel ID is meaningful only in its source workspace.
      if (source && source.hostname.endsWith(".slack.com") && id) {
        href = new URL(
          raw[1] === "@" ? `/team/${id}` : `/archives/${id}`,
          source.origin
        ).href;
      }
    } else if (raw.startsWith("<")) {
      const [url, ...name] = raw.slice(1, -1).split("|");
      href = safeHttpUrl(url!)?.href;
      label = name.join("|") || url!;
    } else if (match[2]) {
      href = safeHttpUrl(match[2])?.href;
      label = match[1]!;
    } else {
      let url = raw.replace(/[.,;!?。，；！？]+$/, "");
      for (const [open, close] of [
        ["(", ")"],
        ["[", "]"],
        ["{", "}"],
      ]) {
        while (
          url.endsWith(close!) &&
          url.split(close!).length > url.split(open!).length
        ) {
          url = url.slice(0, -1);
        }
      }
      trailing = raw.slice(url.length);
      href = safeHttpUrl(url)?.href;
      label = url;
    }
    const className =
      "comma-recommendation-inline comma-recommendation-inline-source comma-recommendation-context-link";
    parts.push(
      href ? (
        <button
          className={className}
          key={match.index}
          type="button"
          {...{ [recommendationLinkHrefAttribute]: href }}
          onClick={(event) => {
            event.stopPropagation();
            onOpenUrl(href!);
          }}
        >
          {label}
        </button>
      ) : (
        <span className={className} key={match.index}>
          {label}
        </span>
      )
    );
    parts.push(trailing);
    cursor = match.index + raw.length;
  }
  parts.push(decoded.slice(cursor));
  return <>{parts}</>;
}

function safeHttpUrl(value: string): URL | undefined {
  try {
    const url = new URL(value);
    if (["https:", "http:"].includes(url.protocol) && !url.username && !url.password)
      return url;
  } catch {
    // Invalid URLs remain inert source text.
  }
  return undefined;
}
