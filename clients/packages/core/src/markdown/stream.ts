// A document that grows (a reply streaming in), parsed as it grows (`IncrementalMarkdown`). One parse for every
// client: the core parses a draft reply with it, and a renderer that shows Markdown it was handed as text uses it too.
import { IncrementalMarkdown, type MarkdownNode } from "./parse.ts";
import { toMarkdownTree, type MarkdownTree } from "./tree.ts";

export { IncrementalMarkdown };

const isMarkdownNode = (value: unknown): value is MarkdownNode =>
  typeof value === "object" &&
  value !== null &&
  typeof (value as { type?: unknown }).type === "string";

/** Whether a node, or one inside it, is still being parsed (an unclosed fence, a link not ended). */
export const hasLoadingMarkdownNode = (node: MarkdownNode): boolean => {
  if (node.loading) return true;

  return Object.values(node).some((value) => {
    if (isMarkdownNode(value)) return hasLoadingMarkdownNode(value);
    if (!Array.isArray(value)) return false;
    return value.some((item) => isMarkdownNode(item) && hasLoadingMarkdownNode(item));
  });
};

/** How many root blocks of a parse can no longer change: all once final, else those before the first still open. */
export const stableRootNodeCount = (
  parsedNodes: readonly MarkdownNode[],
  final: boolean
) => {
  if (final) return parsedNodes.length;
  if (parsedNodes.length === 0) return 0;

  const firstLoadingIndex = parsedNodes.findIndex(hasLoadingMarkdownNode);
  if (firstLoadingIndex >= 0) return firstLoadingIndex;

  return Math.max(0, parsedNodes.length - 1);
};

const DRAFT_PARSERS = 8;
const drafts = new Map<
  string,
  { parser: IncrementalMarkdown; text: string; final: boolean; tree: MarkdownTree }
>();

/**
 * A draft reply's Markdown as it streams (`ChatAssistantDraft.markdown`): parsed as it grows, the same tree for the
 * same text. The few drafts streaming at once each keep their parse.
 */
export function draftMarkdown(
  draftId: string,
  text: string,
  final: boolean
): MarkdownTree {
  const kept = drafts.get(draftId);
  if (kept && kept.text === text && kept.final === final) return kept.tree;
  const parser = kept?.parser ?? new IncrementalMarkdown();
  const tree = toMarkdownTree(parser.parse({ content: text, final }));
  drafts.delete(draftId);
  drafts.set(draftId, { parser, text, final, tree });
  if (drafts.size > DRAFT_PARSERS) drafts.delete(drafts.keys().next().value!);
  return tree;
}
