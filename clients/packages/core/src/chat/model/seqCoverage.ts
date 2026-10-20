// The seq ranges of a conversation this device has read, for a transcript that is paged back through its history
// (conversationChannel.ts): what lies between two ranges is a gap not read yet.

/** `[first, last]`, both read. */
export type SeqRange = readonly [number, number];

/**
 * The seq ranges this device has read completely, as disjoint, non-adjacent, ascending ranges. Hidden messages count
 * as covered: coverage follows raw seq, never what is displayed.
 */
export class SeqCoverage {
  static readonly EMPTY = new SeqCoverage([]);
  readonly ranges: readonly SeqRange[];

  private constructor(ranges: readonly SeqRange[]) {
    this.ranges = ranges;
  }

  static of(ranges: readonly SeqRange[]): SeqCoverage {
    return ranges.reduce<SeqCoverage>(
      (all, [first, last]) => all.add(first, last),
      SeqCoverage.EMPTY
    );
  }

  /** The newest contiguous range. */
  get tail(): SeqRange | undefined {
    return this.ranges.at(-1);
  }

  /** The newest range strictly below the tail: the old watermark when the tail left a gap. */
  get beforeTail(): SeqRange | undefined {
    return this.ranges.length >= 2 ? this.ranges.at(-2) : undefined;
  }

  add(first: number, last: number): SeqCoverage {
    if (first > last || first <= 0) return this;
    const merged: SeqRange[] = [];
    let start = first;
    let end = last;
    for (const held of this.ranges) {
      if (held[1] + 1 < start || end + 1 < held[0]) merged.push(held);
      else {
        start = Math.min(start, held[0]);
        end = Math.max(end, held[1]);
      }
    }
    merged.push([start, end]);
    return new SeqCoverage(merged.toSorted((a, b) => a[0] - b[0]));
  }

  /** Adds each run of consecutive seqs in `seqs`. */
  addRuns(seqs: readonly number[]): SeqCoverage {
    const runs: SeqRange[] = [];
    let start = -1;
    let previous = -1;
    for (const seq of [...new Set(seqs)].toSorted((a, b) => a - b)) {
      if (start < 0) start = seq;
      else if (seq !== previous + 1) {
        runs.push([start, previous]);
        start = seq;
      }
      previous = seq;
    }
    if (start >= 0) runs.push([start, previous]);
    return runs.reduce<SeqCoverage>((all, [first, last]) => all.add(first, last), this);
  }

  /** Keeps only what lies inside the server's current bounds. */
  clip(first: number, last: number): SeqCoverage {
    return new SeqCoverage(
      this.ranges.flatMap((held): SeqRange[] => {
        const start = Math.max(held[0], first);
        const end = Math.min(held[1], last);
        return start <= end ? [[start, end]] : [];
      })
    );
  }

  equals(other: SeqCoverage): boolean {
    return (
      this.ranges.length === other.ranges.length &&
      this.ranges.every(
        (held, index) =>
          held[0] === other.ranges[index]![0] && held[1] === other.ranges[index]![1]
      )
    );
  }
}
