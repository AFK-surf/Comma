// The plain ops of a delta (collections.ts makes them, with the keyed ones): what changed between two values of a
// topic, so a long transcript that grew by one message goes out as one `append`. Objects are compared key by key (in
// the order serde_json keeps them: sorted), an array that only grew is an `append`, one of the same length is
// compared item by item, a string that only grew (a reply streaming in) is an `extend` by what it gained, anything
// else is `set` whole.

export type Segment = string | number;
export type Op =
  | { path: Segment[]; set: unknown }
  | { path: Segment[]; append: unknown[] }
  | { path: Segment[]; extend: string }
  | { path: Segment[]; remove: true };

/// A string that only gained text at its end: the text it gained.
export function grown(path: Segment[], old: unknown, next: unknown): Op | null {
  return typeof old === "string" &&
    typeof next === "string" &&
    old !== "" &&
    next.length > old.length &&
    next.startsWith(old)
    ? { path: [...path], extend: next.slice(old.length) }
    : null;
}
