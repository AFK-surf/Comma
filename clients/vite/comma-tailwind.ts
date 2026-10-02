import { parse } from "postcss";
import { transform, type Selector } from "lightningcss";

/**
 * Keep Tailwind's rule order and specificity, but put the utility class at
 * the end of group selectors. A universal subject inside :is() makes Blink
 * invalidate unrelated descendants when the group state changes.
 */
function localGroupSubject(selector: Selector): Selector | undefined {
  if (
    selector.some((part) => part.type === "combinator") ||
    !selector.some((part) => part.type === "class" || part.type === "nesting")
  ) {
    return undefined;
  }
  const index = selector.findIndex(
    (part) =>
      part.type === "pseudo-class" && part.kind === "is" && part.selectors.length === 1
  );
  const part = selector[index];
  if (part?.type !== "pseudo-class" || part.kind !== "is") return undefined;
  const inner = part.selectors[0]!;
  const group = inner[0];
  const combinator = inner.at(-2);
  if (
    group?.type !== "pseudo-class" ||
    group.kind !== "where" ||
    group.selectors.length !== 1 ||
    group.selectors[0]?.length !== 1 ||
    group.selectors[0][0]?.type !== "class" ||
    !/^group(?:\/|$)/.test(group.selectors[0][0].name) ||
    combinator?.type !== "combinator" ||
    combinator.value !== "descendant" ||
    inner.at(-1)?.type !== "universal" ||
    inner.slice(0, -2).some((item) => item.type === "combinator")
  ) {
    return undefined;
  }
  return [
    ...inner.slice(0, -1),
    ...selector.slice(0, index),
    ...selector.slice(index + 1),
  ];
}

/** Apply the same CSS to production, Storybook and browser fixtures. */
export default function commaTailwind() {
  return {
    name: "comma:local-group-selectors",
    enforce: "pre" as const,
    transform(code: string, id: string) {
      if (
        !id.split("?")[0]?.endsWith(".css") ||
        (!code.includes(":where(.group") && !code.includes(".markstream-react"))
      ) {
        return undefined;
      }
      // Preserve declarations: recompiling them can change custom property
      // registration and animation behavior.
      const root = parse(code, { from: id });
      // Markstream ships two viewport rules. Query Comma's window container
      // without moving the rules or changing their cascade layer/specificity.
      // A width @media in the same sheet as @layer/@font-face triggers global
      // font invalidation on Chromium 148, even when no selector matches.
      root.walkAtRules("media", (rule) => {
        const condition = rule.params.replace(/\s/g, "");
        const selector = rule.nodes?.[0];
        if (selector?.type !== "rule") return;
        let width: string | undefined;
        if (
          condition === "(max-width:640px)" &&
          selector.selector === ".html-preview-frame"
        ) {
          width = "width <= 640px";
        } else if (
          condition === "notalland(min-width:1024px)" &&
          selector.selector.startsWith(".markstream-react .max-lg")
        ) {
          width = "width < 1024px";
        }
        if (width) {
          rule.name = "container";
          rule.params = `comma-window (${width})`;
        }
      });
      root.walkRules((rule) => {
        if (!rule.selector.includes(":is(:where(.group")) return;
        const result = transform({
          filename: "group-selector.css",
          code: Buffer.from(`${rule.selector} { --comma-selector: 0; }`),
          visitor: { Selector: localGroupSubject },
        });
        const rewritten = parse(result.code.toString()).first;
        if (rewritten?.type === "rule") rule.selector = rewritten.selector;
      });
      const result = root.toResult({
        to: id,
        map: { inline: false, annotation: false },
      });
      return { code: result.css, map: result.map?.toString() };
    },
  };
}
