// A document's revisions as a writer's typing. The preview holds whole versions of a file, never keystrokes: when a
// writer's new version arrives, the page shows the change being written — the text the two versions share stays, the
// replacement is typed in between.
//
// Bounds: a version longer than `documentPlaybackLimit` is shown at once, and a change is typed in at most
// `maxSteps` frames.

/**
 * Where the writer's caret stands in the Markdown the page draws: an invisible character the renderer keeps as text,
 * so the caret is found in the page without a map from source to elements.
 */
export const documentCaretMark = "⁣";

/** The longest version whose change is typed; a longer one is shown at once. */
export const documentPlaybackLimit = 60_000;

const stepMs = 40;
const minMs = 480;
const maxMs = 3200;
const msPerCharacter = 6;
const maxSteps = maxMs / stepMs;

export type DocumentRevisionSpan = {
  /** Text both versions start with, ending at a line start. */
  head: string;
  /** What the new version has in place of the old one's middle. */
  insert: string;
  /** Text both versions end with, starting at a line start. */
  tail: string;
};

/** What `next` changes of `previous`, cut at line starts so no line is typed from its middle. */
export function documentRevisionSpan(
  previous: string,
  next: string
): DocumentRevisionSpan {
  const shared = Math.min(previous.length, next.length);
  let start = 0;
  while (start < shared && previous.charCodeAt(start) === next.charCodeAt(start))
    start += 1;
  start = next.lastIndexOf("\n", start - 1) + 1;

  let same = 0;
  while (
    same < shared - start &&
    previous.charCodeAt(previous.length - 1 - same) ===
      next.charCodeAt(next.length - 1 - same)
  )
    same += 1;
  let end = next.length - same;
  if (end > 0 && end < next.length && next.charCodeAt(end - 1) !== 10) {
    const line = next.indexOf("\n", end);
    end = line < 0 ? next.length : line + 1;
  }
  return {
    head: next.slice(0, start),
    insert: next.slice(start, end),
    tail: next.slice(end),
  };
}

/** How many characters of a change each frame types, so a short one is read and a long one does not drag. */
export function documentPlaybackStep(length: number) {
  const duration = Math.min(maxMs, Math.max(minMs, length * msPerCharacter));
  return Math.max(1, Math.ceil(length / Math.min(maxSteps, duration / stepMs)));
}

export const documentPlaybackStepMs = stepMs;

/** `count` moved on by `step`, never between the two halves of one character. */
export function advanceDocumentPlayback(insert: string, count: number, step: number) {
  const next = Math.min(insert.length, count + step);
  const code = insert.charCodeAt(next - 1);
  return next < insert.length && code >= 0xd800 && code <= 0xdbff ? next + 1 : next;
}

const fence = /^ {0,3}(`{3,}|~{3,})/u;
const words = /[\p{L}\p{N}]/u;

/**
 * The index in `text` where the caret mark goes: after the last character typed, when the line it ends is words.
 * A line of syntax alone (a fence, a rule, a table's delimiter row) with one more character is no longer that
 * syntax, so such a line takes no mark and the caret stays where it was.
 */
function markIndex(text: string) {
  let end = text.length;
  while (end > 0 && /\s/u.test(text[end - 1]!)) end -= 1;
  if (end === 0) return -1;
  const line = text.slice(text.lastIndexOf("\n", end - 1) + 1, end);
  return words.test(line) && !fence.test(line) ? end : -1;
}

/**
 * The Markdown a frame of the change draws: the shared head, the `count` characters typed so far, the caret mark,
 * and the shared tail on a line of its own.
 */
export function documentPlaybackFrame(span: DocumentRevisionSpan, count: number) {
  const written = span.head + span.insert.slice(0, count);
  const at = markIndex(written);
  const marked =
    at < 0 ? written : written.slice(0, at) + documentCaretMark + written.slice(at);
  const joins = span.tail !== "" && written !== "" && !written.endsWith("\n");
  return marked + (joins ? "\n" : "") + span.tail;
}

/** The title a document page shows when its text opens with none: its file's name without the extension. */
export function documentFileTitle(fileName: string) {
  const dot = fileName.lastIndexOf(".");
  return dot > 0 ? fileName.slice(0, dot) : fileName;
}

/** Whether the document opens with its own title: a first-level heading as its first line of text. */
export function documentOpensWithTitle(text: string) {
  return /^\s*# \S/u.test(text);
}
