// Chinese copy spaces a Router name on both sides so a Latin name reads
// "交给 Atlas"; a CJK name must sit flush ("交给小逗"). After the name is
// formatted in, drop every space that ends up between two CJK characters.
const cjk = String.raw`\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}　-〿＀-￯`;
const spaceBetweenCjk = new RegExp(`(?<=[${cjk}]) (?=[${cjk}])`, "gu");

export function withRouterNameSpacing(text: string) {
  return text.replace(spaceBetweenCjk, "");
}
