// What one version of a document changes of another, as one document that shows both: text and blocks the newer
// version added are marked `ins`, those it took away `del` (`documentBodyHtml` draws the marks). The comparison is
// of the parsed documents, so a change of Markdown spelling that draws the same is no change.
//
// Blocks are matched first; a block that changed in place (a paragraph, a heading, a list, a table) is compared
// inside, down to its words.
//
// Bounds: a comparison of more than `maxCells` pairs (blocks of one level, or words of one block) is not made:
// the older side shows as taken away and the newer as added.
import type { MarkdownTree, MarkdownTreeNode } from "@comma/core/markdown";

type Attributes = Record<string, unknown>;
type Parsed = { kind: string; children: MarkdownTreeNode[]; attributes: Attributes };
type Op = { kind: "same" | "del" | "ins"; before?: number; after?: number };

const maxCells = 4_000_000;

function parsed(node: Exclude<MarkdownTreeNode, string>): Parsed {
  const [kind, first, second] = node;
  return {
    kind,
    children: Array.isArray(first) ? first : [],
    attributes: (Array.isArray(first) ? second : first) ?? {},
  };
}

const kindOf = (node: MarkdownTreeNode) =>
  typeof node === "string" ? "text" : node[0];

/** The steps from `before` to `after`: each item kept, taken away or added, with a run's removals before its additions. */
function steps(before: readonly string[], after: readonly string[]): Op[] {
  let head = 0;
  while (head < before.length && head < after.length && before[head] === after[head])
    head += 1;
  let tail = 0;
  while (
    tail < before.length - head &&
    tail < after.length - head &&
    before[before.length - 1 - tail] === after[after.length - 1 - tail]
  )
    tail += 1;
  const rows = before.length - head - tail;
  const columns = after.length - head - tail;
  const ops: Op[] = [];
  for (let index = 0; index < head; index += 1)
    ops.push({ kind: "same", before: index, after: index });
  if (rows * columns > maxCells) {
    for (let row = 0; row < rows; row += 1)
      ops.push({ kind: "del", before: head + row });
    for (let column = 0; column < columns; column += 1)
      ops.push({ kind: "ins", after: head + column });
  } else {
    // The longest run both sides share, from the end, so the walk forward takes removals first.
    const width = columns + 1;
    const length = new Uint32Array((rows + 1) * width);
    for (let row = rows - 1; row >= 0; row -= 1)
      for (let column = columns - 1; column >= 0; column -= 1)
        length[row * width + column] =
          before[head + row] === after[head + column]
            ? length[(row + 1) * width + column + 1]! + 1
            : Math.max(
                length[(row + 1) * width + column]!,
                length[row * width + column + 1]!
              );
    let row = 0;
    let column = 0;
    while (row < rows || column < columns) {
      if (
        row < rows &&
        column < columns &&
        before[head + row] === after[head + column]
      ) {
        ops.push({ kind: "same", before: head + row, after: head + column });
        row += 1;
        column += 1;
      } else if (
        row < rows &&
        (column === columns ||
          length[(row + 1) * width + column]! >= length[row * width + column + 1]!)
      ) {
        ops.push({ kind: "del", before: head + row });
        row += 1;
      } else {
        ops.push({ kind: "ins", after: head + column });
        column += 1;
      }
    }
  }
  for (let index = 0; index < tail; index += 1)
    ops.push({
      kind: "same",
      before: before.length - tail + index,
      after: after.length - tail + index,
    });
  return ops;
}

// ── Words ───────────────────────────────────────────────────────────────────

/** The marks around a word, outermost first: what wraps it again in the compared text. */
type Path = [kind: string, attributes: Attributes][];
type Token = {
  key: string;
  path: Path;
  pathKey: string;
  text?: string;
  atom?: MarkdownTreeNode;
};

const words = new Intl.Segmenter(undefined, { granularity: "word" });

/** The inline nodes as words, each with the marks it is in; a node that is one thing (code, a picture) is one word. */
function tokens(nodes: MarkdownTreeNode[], path: Path, out: Token[]) {
  const pathKey = JSON.stringify(path);
  for (const node of nodes) {
    if (typeof node === "string") {
      for (const { segment } of words.segment(node))
        out.push({ key: `${pathKey}\n${segment}`, path, pathKey, text: segment });
      continue;
    }
    const { kind, children, attributes } = parsed(node);
    if (children.length > 0) tokens(children, [...path, [kind, attributes]], out);
    else
      out.push({
        key: `${pathKey}\n${JSON.stringify(node)}`,
        path,
        pathKey,
        atom: node,
      });
  }
  return out;
}

function wrapped(content: MarkdownTreeNode[], path: Path): MarkdownTreeNode[] {
  return path.reduceRight<MarkdownTreeNode[]>(
    (inner, [kind, attributes]) => [
      Object.keys(attributes).length > 0 ? [kind, inner, attributes] : [kind, inner],
    ],
    content
  );
}

const anchorLength = 16;
const keptShare = 0.6;
const lengthOf = (token: Token) => token.text?.length ?? 1;

/**
 * The steps with a rewritten passage shown as one: where a stretch of changes keeps only a few words between
 * them, those words read as part of what was taken away and what was added, not as text that stayed. Words kept
 * for `anchorLength` characters or more end a stretch.
 */
function settled(ops: Op[], olds: Token[], news: Token[]): Op[] {
  const out: Op[] = [];
  for (let at = 0; at < ops.length; ) {
    if (ops[at]!.kind === "same") {
      out.push(ops[at]!);
      at += 1;
      continue;
    }
    let last = at;
    for (let next = at; next < ops.length; ) {
      if (ops[next]!.kind !== "same") {
        last = next;
        next += 1;
        continue;
      }
      let end = next;
      let kept = 0;
      for (; end < ops.length && ops[end]!.kind === "same"; end += 1)
        kept += lengthOf(news[ops[end]!.after!]!);
      if (kept >= anchorLength || end === ops.length) break;
      next = end;
    }
    const stretch = ops.slice(at, last + 1);
    let kept = 0;
    let removed = 0;
    let added = 0;
    for (const op of stretch)
      if (op.kind === "same") kept += lengthOf(news[op.after!]!);
      else if (op.kind === "del") removed += lengthOf(olds[op.before!]!);
      else added += lengthOf(news[op.after!]!);
    if (kept > 0 && kept < Math.max(removed, added) * keptShare)
      out.push(
        ...stretch.flatMap((op): Op[] =>
          op.kind === "ins" ? [] : [{ kind: "del", before: op.before! }]
        ),
        ...stretch.flatMap((op): Op[] =>
          op.kind === "del" ? [] : [{ kind: "ins", after: op.after! }]
        )
      );
    else out.push(...stretch);
    at = last + 1;
  }
  return out;
}

/** A changed block's inline content with its words compared. */
function inlineDiff(
  before: MarkdownTreeNode[],
  after: MarkdownTreeNode[]
): MarkdownTreeNode[] {
  const olds = tokens(before, [], []);
  const news = tokens(after, [], []);
  const out: MarkdownTreeNode[] = [];
  // Words next to one another with the same marks and the same fate are one run of text again.
  let run:
    | { kind: Op["kind"]; pathKey: string; path: Path; content: MarkdownTreeNode[] }
    | undefined;
  const flush = () => {
    if (!run) return;
    const nodes = wrapped(run.content, run.path);
    const last = out.at(-1);
    if (run.kind === "same") out.push(...nodes);
    // One mark spans what was added (or taken away) in a row, whatever marks its words are in.
    else if (Array.isArray(last) && last[0] === run.kind && Array.isArray(last[1]))
      last[1].push(...nodes);
    else out.push([run.kind, nodes]);
    run = undefined;
  };
  for (const op of settled(
    steps(
      olds.map((token) => token.key),
      news.map((token) => token.key)
    ),
    olds,
    news
  )) {
    const token = op.kind === "del" ? olds[op.before!]! : news[op.after!]!;
    if (!run || run.kind !== op.kind || run.pathKey !== token.pathKey) {
      flush();
      run = { kind: op.kind, pathKey: token.pathKey, path: token.path, content: [] };
    }
    const last = run.content.at(-1);
    if (token.atom !== undefined) run.content.push(token.atom);
    else if (typeof last === "string")
      run.content[run.content.length - 1] = last + token.text!;
    else run.content.push(token.text!);
  }
  flush();
  return out;
}

// ── Blocks ──────────────────────────────────────────────────────────────────

const inlineBlocks = new Set(["p", "h", "td"]);
const nestedBlocks = new Set(["list", "li", "quote", "table"]);

function marked(node: MarkdownTreeNode, diff: "ins" | "del"): MarkdownTreeNode {
  if (typeof node === "string") return ["p", [node], { diff }];
  const { kind, children, attributes } = parsed(node);
  return node.length === 1 || !Array.isArray(node[1])
    ? [kind, { ...attributes, diff }]
    : [kind, children, { ...attributes, diff }];
}

/** Two blocks of one kind, compared inside; undefined where the kind is compared whole. */
function changed(
  before: MarkdownTreeNode,
  after: MarkdownTreeNode
): MarkdownTreeNode | undefined {
  if (typeof before === "string" || typeof after === "string") return undefined;
  const old = parsed(before);
  const now = parsed(after);
  if (old.kind !== now.kind) return undefined;
  const rebuilt = (children: MarkdownTreeNode[]): MarkdownTreeNode =>
    Object.keys(now.attributes).length > 0
      ? [now.kind, children, now.attributes]
      : [now.kind, children];
  if (inlineBlocks.has(now.kind))
    return rebuilt(inlineDiff(old.children, now.children));
  // A bulleted list that became a numbered one is another list.
  if (now.kind === "list" && old.attributes.ordered !== now.attributes.ordered)
    return undefined;
  if (nestedBlocks.has(now.kind)) return rebuilt(blockDiff(old.children, now.children));
  // A row's cells are compared place by place: a table's columns do not move.
  if (now.kind === "tr")
    return rebuilt(
      Array.from(
        { length: Math.max(old.children.length, now.children.length) },
        (_, index) => {
          const left = old.children[index];
          const right = now.children[index];
          return left === undefined
            ? marked(right!, "ins")
            : right === undefined
              ? marked(left, "del")
              : (changed(left, right) ?? right);
        }
      )
    );
  return undefined;
}

function blockDiff(
  before: MarkdownTreeNode[],
  after: MarkdownTreeNode[]
): MarkdownTreeNode[] {
  const ops = steps(
    before.map((node) => JSON.stringify(node)),
    after.map((node) => JSON.stringify(node))
  );
  const out: MarkdownTreeNode[] = [];
  for (let at = 0; at < ops.length; ) {
    const op = ops[at]!;
    if (op.kind === "same") {
      out.push(after[op.after!]!);
      at += 1;
      continue;
    }
    // A run of blocks taken away and added: those of one kind, in order, changed in place.
    const removed: MarkdownTreeNode[] = [];
    const added: MarkdownTreeNode[] = [];
    for (; at < ops.length && ops[at]!.kind !== "same"; at += 1)
      if (ops[at]!.kind === "del") removed.push(before[ops[at]!.before!]!);
      else added.push(after[ops[at]!.after!]!);
    const pairs = Math.min(removed.length, added.length);
    for (let index = 0; index < pairs; index += 1) {
      const inside =
        kindOf(removed[index]!) === kindOf(added[index]!)
          ? changed(removed[index]!, added[index]!)
          : undefined;
      if (inside) out.push(inside);
      else out.push(marked(removed[index]!, "del"), marked(added[index]!, "ins"));
    }
    for (const node of removed.slice(pairs)) out.push(marked(node, "del"));
    for (const node of added.slice(pairs)) out.push(marked(node, "ins"));
  }
  return out;
}

/** `after` with what it changed of `before` marked: one document that shows both versions. */
export const documentDiff = (before: MarkdownTree, after: MarkdownTree): MarkdownTree =>
  blockDiff(before, after);

/** Whether a compared document marks anything: two versions that draw the same mark nothing. */
export function documentDiffHasChanges(tree: MarkdownTree): boolean {
  return tree.some((node) => {
    if (typeof node === "string") return false;
    const { kind, children, attributes } = parsed(node);
    return (
      kind === "ins" ||
      kind === "del" ||
      attributes.diff !== undefined ||
      documentDiffHasChanges(children)
    );
  });
}
