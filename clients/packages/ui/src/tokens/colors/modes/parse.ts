type FigmaColorValue = { hex?: string };
type FigmaTokenNode = { $value?: FigmaColorValue | string };

export interface ColorModeToken {
  name: string;
  hex: string | null;
  alias: string | null;
}

export interface ColorModeGroup {
  path: string;
  tokens: ColorModeToken[];
}

export interface ParsedColorMode {
  categories: {
    name: string;
    groups: ColorModeGroup[];
  }[];
  tokenCount: number;
}

const parseLeaf = (
  name: string,
  value: FigmaColorValue | string | undefined
): ColorModeToken => {
  if (typeof value === "string") {
    return { name, hex: null, alias: value };
  }
  return { name, hex: value?.hex ?? null, alias: null };
};

const walk = (
  node: Record<string, unknown>,
  path: string[],
  bucket: Map<string, ColorModeToken[]>
): void => {
  for (const [key, raw] of Object.entries(node)) {
    if (key.startsWith("$")) continue;
    const child = raw as FigmaTokenNode & Record<string, unknown>;
    if (!child || typeof child !== "object") continue;

    if ("$value" in child) {
      const groupPath = path.join(" / ");
      const list = bucket.get(groupPath) ?? [];
      list.push(parseLeaf(key, child.$value as FigmaColorValue | string));
      bucket.set(groupPath, list);
      continue;
    }

    walk(child, [...path, key], bucket);
  }
};

export const parseColorModeTokens = (
  data: Record<string, unknown>
): ParsedColorMode => {
  const categories: ParsedColorMode["categories"] = [];
  let tokenCount = 0;

  for (const [categoryName, categoryNode] of Object.entries(data)) {
    if (
      categoryName.startsWith("$") ||
      typeof categoryNode !== "object" ||
      !categoryNode
    )
      continue;

    const bucket = new Map<string, ColorModeToken[]>();
    walk(categoryNode as Record<string, unknown>, [], bucket);

    const groups = [...bucket.entries()]
      .toSorted(([a], [b]) => a.localeCompare(b))
      .map(([path, tokens]) => ({
        path,
        tokens: tokens.toSorted((a, b) => a.name.localeCompare(b.name)),
      }));

    tokenCount += groups.reduce((sum, group) => sum + group.tokens.length, 0);
    categories.push({ name: categoryName, groups });
  }

  return { categories, tokenCount };
};
