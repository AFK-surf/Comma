// The colours a reader gives to text of a document, and to the ground behind it. A colour is one of a fixed set of
// names: the page draws each from the document's palette (`documentPreview.css`), so a colour reads right in a light
// and a dark theme, and a document keeps the name, not a value.
//
// In the Markdown a colour is inline HTML around the text: `<span data-color="red">` for the text's colour and
// `<mark data-color="red">` for its ground. A reader of the file elsewhere sees the text, and a highlight for a mark.

export const documentColors = [
  "gray",
  "brown",
  "orange",
  "yellow",
  "green",
  "blue",
  "purple",
  "pink",
  "red",
] as const;

export type DocumentColor = (typeof documentColors)[number];

/** What a colour is of: the text, or the ground behind it. */
export type DocumentColorKind = "color" | "ground";

const tags: Record<string, DocumentColorKind> = { span: "color", mark: "ground" };
const opening = /^<(span|mark)\s+data-color="([a-z]+)"\s*>/u;

/** The colour an inline HTML element gives, by its source; undefined for any other element. */
export function documentColorOf(
  source: string
): { kind: DocumentColorKind; color: DocumentColor } | undefined {
  const [, tag, name] = opening.exec(source) ?? [];
  const color = documentColors.find((one) => one === name);
  return tag && color ? { kind: tags[tag]!, color } : undefined;
}

/** A colour's element around `inner` (Markdown or HTML alike: the tags are the same). */
export function documentColorElement(
  kind: DocumentColorKind,
  color: string,
  inner: string
): string {
  // A name the palette has not is no colour: the text stays.
  if (!documentColors.some((one) => one === color)) return inner;
  const tag = kind === "color" ? "span" : "mark";
  return `<${tag} data-color="${color}">${inner}</${tag}>`;
}
