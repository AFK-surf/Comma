import type { ReactNode } from "react";
import { recommendationLinkHrefAttribute } from "./recommendationLinkMenu";

// The server renders every product's quote in one markup
// (CommaWeb.RecommendationSourceQuote): one line per source line, "• " before
// a list item, <https://…|label> links, Slack <@U…|name> and <#C…|name>
// mentions, and &lt; &gt; &amp; for literal characters. Only these tokens and
// bare http(s) URLs become links; everything else is React text.
export function SourceContext({
  text,
  sourceHref,
  onOpenUrl,
}: {
  text: string;
  sourceHref: string;
  onOpenUrl: (url: string) => void;
}) {
  return (
    <>
      {text
        .split("\n")
        .map((line) => line.trim())
        .filter((line) => line !== "")
        .map((line, index) => {
          const listItem = line.startsWith("• ");
          return (
            <span
              className="comma-recommendation-source-line"
              data-list-item={listItem ? "true" : undefined}
              key={index}
            >
              {sourceTokens(listItem ? line.slice(2) : line, sourceHref, onOpenUrl)}
            </span>
          );
        })}
    </>
  );
}

// Tokens are read before entities are decoded, so escaped text stays text.
const decode = (text: string) =>
  text.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");

function sourceTokens(
  text: string,
  sourceHref: string,
  onOpenUrl: (url: string) => void
) {
  const tokens =
    /<[@#][A-Z0-9]+(?:\|[^<>]+)?>|<https?:\/\/[^<>]+>|https?:\/\/(?:(?!&[lg]t;)[^\s<>"'])+/g;
  const parts: ReactNode[] = [];
  let cursor = 0;
  for (const match of text.matchAll(tokens)) {
    parts.push(decode(text.slice(cursor, match.index)));
    const raw = match[0];
    let href: string | undefined;
    let label = raw;
    // A shortened URL label keeps the full address as the link's title.
    let title: string | undefined;
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
      const target = safeHttpUrl(decode(url!));
      href = target?.href;
      label = name.join("|") || url!;
      if (!name.length && target) [label, title] = [urlLabel(target), target.href];
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
      const target = safeHttpUrl(decode(url));
      href = target?.href;
      label = url;
      if (target) [label, title] = [urlLabel(target), target.href];
    }
    const className =
      "comma-recommendation-inline comma-recommendation-inline-source comma-recommendation-context-link";
    // An anchor, not a button: a button is one box, so a long link would move
    // to its own line and leave the words around it behind.
    parts.push(
      href ? (
        <a
          className={className}
          href={href}
          key={match.index}
          rel="noopener noreferrer"
          target="_blank"
          title={title}
          {...{ [recommendationLinkHrefAttribute]: href }}
          onClick={(event) => {
            event.preventDefault();
            event.stopPropagation();
            onOpenUrl(href!);
          }}
        >
          {decode(label)}
        </a>
      ) : (
        <span className={className} key={match.index}>
          {decode(label)}
        </span>
      )
    );
    parts.push(decode(trailing));
    cursor = match.index + raw.length;
  }
  parts.push(decode(text.slice(cursor)));
  return parts;
}

// A link without a label names its host and path. A long path keeps only its
// last segment, so an image or tracking URL does not fill the preview.
function urlLabel(url: URL) {
  const path = url.pathname.replace(/\/$/, "");
  const segments = path.split("/").filter(Boolean);
  return `${url.host}${path}`.length > 40 && segments.length > 1
    ? `${url.host}/…/${segments.at(-1)}`
    : `${url.host}${path}`;
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
