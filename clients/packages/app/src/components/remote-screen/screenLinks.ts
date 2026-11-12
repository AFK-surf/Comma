import type { MarkdownTree, MarkdownTreeNode } from "@comma/core/markdown";
import { trustedInlineTag } from "@comma/core/markdown";

/**
 * A screen named in a message: `comma:screen/<computer's device id>/<screen id>`, the scheme a Task's mention has
 * (`comma:task/<id>`). The screen id is `display`, `android:<serial>` or `simulator:<udid>`, escaped as a path's part is.
 */
export type ScreenLink = { device: string; screen: string; label: string | undefined };

const SCREEN_LINK = /^comma:screen\/([^/\s]{1,256})\/([^/\s]{1,256})$/;

export function parseScreenLink(href: string): Omit<ScreenLink, "label"> | null {
  const found = SCREEN_LINK.exec(href);
  if (!found) return null;
  try {
    const screen = decodeURIComponent(found[2]!);
    return screen === "display" || /^(android|simulator):[^/?#\s]{1,200}$/.test(screen)
      ? { device: decodeURIComponent(found[1]!), screen }
      : null;
  } catch {
    return null;
  }
}

const textOf = (nodes: readonly MarkdownTreeNode[]): string =>
  nodes
    .map((node) =>
      typeof node === "string" ? node : Array.isArray(node[1]) ? textOf(node[1]) : ""
    )
    .join("");

/**
 * A message's text with each screen link as its words, for where a message stands as one line of text (a reply's
 * excerpt): a link alone is its label, a bare address nothing.
 */
export function withoutScreenLinks(text: string): string {
  return text
    .replace(/\[([^\]\n]*)\]\(comma:screen\/[^)\s]*\)/g, "$1")
    .replace(/comma:screen\/\S+/g, "");
}

/** The link a line is, when it is nothing else: a link, or the address as plain text. */
function linkOf(line: readonly MarkdownTreeNode[]): ScreenLink | null {
  const parts = line.filter((node) => typeof node !== "string" || node.trim());
  const [only] = parts;
  if (parts.length !== 1 || only === undefined) return null;
  if (typeof only === "string") {
    const bare = parseScreenLink(only.trim());
    return bare && { ...bare, label: undefined };
  }
  const [kind, first, second] = only;
  if (kind !== "a") return null;
  const attributes = (Array.isArray(first) ? second : first) ?? {};
  const named = parseScreenLink(String(attributes.href ?? ""));
  if (!named) return null;
  return {
    ...named,
    label: (Array.isArray(first) ? textOf(first).trim() : "") || undefined,
  };
}

/** A paragraph's lines, as Markdown broke them; each keeps the break that ended it (a newline in its text, or `br`). */
type Line = { nodes: MarkdownTreeNode[]; end?: MarkdownTreeNode };

function linesOf(paragraph: readonly MarkdownTreeNode[]): Line[] {
  const lines: Line[] = [{ nodes: [] }];
  const current = () => lines[lines.length - 1]!;
  for (const node of paragraph) {
    if (typeof node === "string") {
      node.split("\n").forEach((text, index) => {
        if (index > 0) {
          current().end = "\n";
          lines.push({ nodes: [] });
        }
        if (text) current().nodes.push(text);
      });
    } else if (node[0] === "br") {
      current().end = node;
      lines.push({ nodes: [] });
    } else {
      current().nodes.push(node);
    }
  }
  return lines;
}

/** Lines back as one paragraph, without the break after the last; nothing when they hold no words. */
function paragraphOf(lines: readonly Line[]): MarkdownTreeNode[] {
  const children = lines.flatMap((line, index) =>
    index < lines.length - 1 && line.end !== undefined
      ? [...line.nodes, line.end]
      : line.nodes
  );
  const blank = children.every(
    (node) => (typeof node === "string" && !node.trim()) || node[0] === "br"
  );
  return blank ? [] : [["p", children]];
}

/**
 * A message's tree with each screen link alone on its line standing for its card, and those links by the key each stands
 * under. A paragraph with other lines is cut around the card, its words kept before and after. One within a sentence
 * stays the words it is. A tree with none comes back as it was.
 */
export function screenLinkCards(tree: MarkdownTree): {
  tree: MarkdownTree;
  links: Map<string, ScreenLink>;
} {
  const links = new Map<string, ScreenLink>();
  const out = tree.flatMap((node): MarkdownTreeNode[] => {
    if (typeof node === "string" || node[0] !== "p" || !Array.isArray(node[1]))
      return [node];
    const lines = linesOf(node[1]);
    const shown: MarkdownTreeNode[] = [];
    let words: Line[] = [];
    let carded = false;
    for (const line of lines) {
      const link = linkOf(line.nodes);
      if (!link) {
        words.push(line);
        continue;
      }
      carded = true;
      shown.push(...paragraphOf(words));
      words = [];
      const key = `screen-${links.size.toString(36)}`;
      links.set(key, link);
      shown.push(["p", [[trustedInlineTag, { key }]]]);
    }
    if (!carded) return [node];
    shown.push(...paragraphOf(words));
    return shown;
  });
  return { tree: links.size > 0 ? out : tree, links };
}
