// Character references in Markdown text (`&amp;`, `&#169;`, `&#x1F600;`) as the characters they name, the way
// CommonMark reads them. Without a DOM: the core runs where there is none.
import { characterEntities } from "character-entities";

const REFERENCE =
  /&(?:#[xX]([0-9a-fA-F]{1,6})|#([0-9]{1,7})|([A-Za-z][A-Za-z0-9]{1,31}));/g;

export function decodeCharacterReferences(text: string): string {
  if (!text.includes("&")) return text;
  return text.replace(
    REFERENCE,
    (reference, hex?: string, decimal?: string, name?: string) => {
      if (name !== undefined) {
        const named = (characterEntities as Record<string, unknown>)[name];
        return typeof named === "string" ? named : reference;
      }
      const code = Number.parseInt(hex ?? decimal!, hex === undefined ? 10 : 16);
      return code === 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)
        ? "�"
        : String.fromCodePoint(code);
    }
  );
}
