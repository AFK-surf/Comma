import type { MarkdownStreamImageResolver } from "@comma/ui/components/markdown-stream";
import type { ChatAttachment } from "@comma/core/chat";
import type { MarkdownTree, MarkdownTreeNode } from "@comma/core/markdown";

const loadableAddress = /^(?:https?:|data:|blob:)/i;

// An Agent writes an image by its workspace path (`![](/artifacts/chart.png)`),
// which the app's origin does not serve.

/**
 * A reply's tree without the images that name a file the message attached:
 * its attachments show that file, so the text does not repeat it. A paragraph
 * that held only such images goes with them.
 */
export function withoutAttachedImages(
  tree: MarkdownTree,
  attachments: readonly ChatAttachment[]
): MarkdownTree {
  const attached = new Set(
    attachments.flatMap((attachment) =>
      [attachment.workspacePath, attachment.fileName].filter((name): name is string =>
        Boolean(name)
      )
    )
  );
  if (attached.size === 0) return tree;
  const keep = (nodes: MarkdownTreeNode[]): MarkdownTreeNode[] =>
    nodes.flatMap((node): MarkdownTreeNode[] => {
      if (typeof node === "string") return [node];
      const [kind, first, second] = node;
      const attributes = (Array.isArray(first) ? second : first) ?? {};
      if (kind === "img" && attached.has(decodedPath(String(attributes.src ?? ""))))
        return [];
      if (!Array.isArray(first)) return [node];
      const children = keep(first);
      if (
        children.length === first.length &&
        children.every((child, i) => child === first[i])
      )
        return [node];
      if (
        kind === "p" &&
        children.every((child) => typeof child === "string" && !child.trim())
      )
        return [];
      return [second ? [kind, children, second] : [kind, children]];
    });
  return keep(tree);
}

/** Any other image named by a path, not an address: its alt text, or the path. */
export const pathImageStandIn: MarkdownStreamImageResolver = ({ alt, src }) =>
  loadableAddress.test(src) ? undefined : alt || decodedPath(src);

function decodedPath(src: string) {
  try {
    return decodeURI(src);
  } catch {
    return src;
  }
}
