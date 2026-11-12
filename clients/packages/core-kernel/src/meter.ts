// What the core's work on a change costs, counted rather than timed, so a test can hold it to a bound. A change's cost
// should follow what changed, not how much there is: a source keeps the objects of what did not change (the diff then
// steps over them), every list of objects says how its items are known (a key, or by place), and what the core keeps
// on disk is written only when it changed. A core given a Meter counts each of these as it goes.
import type { Topic } from "./protocol.ts";

/// The work one emission of a topic took.
export type Work = {
  /// Objects and arrays the diff compared (each not the same object as the one before it).
  compared: number;
  /// Of those, the ones equal to what they replace: made again for nothing (the source did not keep them).
  rebuilt: number;
  /// Of those, the items of lists: what grows with the data (a source must keep the items that did not change).
  rebuiltItems: number;
  /// Those by the place of their list.
  remadeIn: Record<string, number>;
  /// Item keys written out to match the items of keyed lists.
  keys: number;
  /// Items of keyed lists matched by object, between the same objects at a list's start and end that it steps over.
  matched: number;
  /// Bytes written out to weigh ops against the value they make.
  weighed: number;
  /// Paths of lists of objects that changed and have no spec saying how their items are known.
  unkeyed: string[];
  /// While an item of a keyed list is diffed: where that list is (to place what is found in the item).
  within: string[];
};

export function noWork(): Work {
  return {
    compared: 0,
    rebuilt: 0,
    rebuiltItems: 0,
    remadeIn: {},
    keys: 0,
    matched: 0,
    weighed: 0,
    unkeyed: [],
    within: [],
  };
}

export interface Meter {
  /// A topic's value went out: what diffing it took, and the bytes of what was sent.
  emitted(topic: Topic, work: Work, bytes: number): void;
  /// A topic has a new value: what it made again of its last one (`rebuiltItems`, `remadeIn`).
  remade(topic: Topic, work: Work): void;
  /// The core wrote a document it keeps; `same` when it held these bytes already.
  wrote(table: string, bytes: number, same: boolean): void;
  /// A topic's value is being computed (null: no more). A schema check meanwhile checks what the core made itself,
  /// which was checked where it came in.
  computing(topic: Topic | null): void;
}
