const CJK =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\u3000-\u303F\uFF00-\uFFEF]/u;
const CJK_LETTER =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;
const WORD = /[\p{L}\p{N}]/u;

/**
 * Words that continue `draft`, joined as Quick Chat joins what was said: Latin
 * words keep a space between them, and so does an English sentence's end
 * before the next; Chinese and a Latin word, digit or English punctuation get
 * one (as Comma's Chinese text is written), CJK text has none.
 */
export function joinSpoken(draft: string, words: string) {
  const head = draft.trim();
  const last = Array.from(head).at(-1);
  const first = Array.from(words)[0];
  if (!last || !first) return head + words;
  const latin = (c: string) => WORD.test(c) && !CJK.test(c);
  const spaced =
    (latin(last) || /[.,!?;:]/u.test(last) || CJK_LETTER.test(last)) &&
    (latin(first) || CJK_LETTER.test(first)) &&
    !(CJK_LETTER.test(last) && CJK_LETTER.test(first));
  return spaced ? `${head} ${words}` : head + words;
}
