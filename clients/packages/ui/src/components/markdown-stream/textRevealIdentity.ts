export interface TextIdentitySpan {
  previousStart: number;
  currentStart: number;
  length: number;
}

// Ordinary appends are linear prefix comparisons. Structural rewrites use at
// most 32,768 LCS cells (64 KiB), never a document-sized quadratic diff.
export const MAX_TEXT_IDENTITY_CELLS = 32_768;
const MAX_CHANGED_TEXT_LENGTH = 4_096;
const MAX_ANCHOR_LENGTH = 64;

// A suffix alone can steal the identity of a newly appended duplicate. Only
// adopt it when a bounded anchor identifies the same ordered occurrence in
// both roots. Two fixed-size candidates keep searching linear in root length.
function uniqueSuffix(previous: string, current: string, prefix: number) {
  let length = 0;
  while (
    length < previous.length - prefix &&
    length < current.length - prefix &&
    previous[previous.length - length - 1] === current[current.length - length - 1]
  ) {
    length++;
  }
  if (!length) return 0;
  const size = Math.min(length, MAX_ANCHOR_LENGTH);
  for (const fromEnd of [size, length]) {
    const oldStart = previous.length - fromEnd;
    const newStart = current.length - fromEnd;
    const anchor = current.slice(newStart, newStart + size);
    if (
      previous.indexOf(anchor) === oldStart &&
      previous.indexOf(anchor, oldStart + 1) === -1 &&
      current.indexOf(anchor) === newStart &&
      current.indexOf(anchor, newStart + 1) === -1
    ) {
      return length;
    }
  }
  return 0;
}

/** Ordered, root-local visible-text identity; this is not a source map. */
export function matchTextIdentity(previous: string, current: string) {
  let prefix = 0;
  while (
    prefix < previous.length &&
    prefix < current.length &&
    previous[prefix] === current[prefix]
  ) {
    prefix++;
  }
  const spans: TextIdentitySpan[] = prefix
    ? [{ previousStart: 0, currentStart: 0, length: prefix }]
    : [];
  let oldLength = previous.length - prefix;
  let newLength = current.length - prefix;
  if (!oldLength || !newLength) {
    return { spans, complete: true, comparedCells: 0 };
  }
  let cells = (oldLength + 1) * (newLength + 1);
  let suffix = 0;
  if (cells > MAX_TEXT_IDENTITY_CELLS) {
    suffix = uniqueSuffix(previous, current, prefix);
    oldLength -= suffix;
    newLength -= suffix;
    cells = (oldLength + 1) * (newLength + 1);
  }
  const appendSuffix = () => {
    if (suffix) {
      spans.push({
        previousStart: previous.length - suffix,
        currentStart: current.length - suffix,
        length: suffix,
      });
    }
  };
  if (
    oldLength > MAX_CHANGED_TEXT_LENGTH ||
    newLength > MAX_CHANGED_TEXT_LENGTH ||
    cells > MAX_TEXT_IDENTITY_CELLS
  ) {
    // An uncertain remapping must not make already-readable words pale again.
    // Proven prefix/suffix ages survive; uncertain text stays clear.
    appendSuffix();
    return { spans, complete: false, comparedCells: 0 };
  }
  const width = newLength + 1;
  const lengths = new Uint16Array(cells);
  for (let old = oldLength - 1; old >= 0; old--) {
    for (let next = newLength - 1; next >= 0; next--) {
      lengths[old * width + next] =
        previous[prefix + old] === current[prefix + next]
          ? lengths[(old + 1) * width + next + 1]! + 1
          : Math.max(
              lengths[(old + 1) * width + next]!,
              lengths[old * width + next + 1]!
            );
    }
  }
  let old = 0;
  let next = 0;
  while (old < oldLength && next < newLength) {
    if (previous[prefix + old] === current[prefix + next]) {
      const prior = spans.at(-1);
      if (
        prior &&
        prior.previousStart + prior.length === prefix + old &&
        prior.currentStart + prior.length === prefix + next
      ) {
        prior.length++;
      } else {
        spans.push({
          previousStart: prefix + old,
          currentStart: prefix + next,
          length: 1,
        });
      }
      old++;
      next++;
    } else if (lengths[(old + 1) * width + next]! >= lengths[old * width + next + 1]!) {
      old++;
    } else {
      next++;
    }
  }
  appendSuffix();
  return { spans, complete: true, comparedCells: oldLength * newLength };
}
