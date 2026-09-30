const locales = ["en", "zh-CN"] as const;
const messages = await Promise.all(
  locales.map((locale) =>
    Bun.file(new URL(`../messages/${locale}.json`, import.meta.url)).json()
  )
);

const entries = (value: unknown): Map<string, unknown> => {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("message object expected at root");
  }
  const result = new Map<string, unknown>();
  for (const [key, child] of Object.entries(value)) {
    if (key === "$schema") continue;
    result.set(key, child);
  }
  return result;
};

const source = entries(messages[0]);
for (let index = 0; index < locales.length; index += 1) {
  const locale = locales[index]!;
  const target = entries(messages[index]);
  const sourceKeys = [...source.keys()].sort();
  const targetKeys = [...target.keys()].sort();
  if (JSON.stringify(sourceKeys) !== JSON.stringify(targetKeys)) {
    throw new Error(`${locale} message keys differ from en`);
  }
  for (const key of sourceKeys) {
    const value = target.get(key);
    const strings = (entry: unknown): string[] =>
      typeof entry === "string"
        ? [entry]
        : Array.isArray(entry)
          ? entry.flatMap(strings)
          : entry && typeof entry === "object"
            ? Object.values(entry).flatMap(strings)
            : [];
    if (strings(value).length === 0 || strings(value).some((text) => !text.trim()))
      throw new Error(`${locale}.${key} is empty`);
    const parameters = (entry: unknown) =>
      [
        ...new Set(
          strings(entry).flatMap((text) =>
            [...text.matchAll(/\{\s*([\w]+)\s*\}/g)].map((match) => match[1])
          )
        ),
      ].sort();
    if (
      JSON.stringify(parameters(source.get(key))) !== JSON.stringify(parameters(value))
    ) {
      throw new Error(`${locale}.${key} parameters differ from en`);
    }
    const shape = (entry: unknown): string[] => {
      if (Array.isArray(entry)) return entry.flatMap(shape);
      if (!entry || typeof entry !== "object") return [];
      return Object.entries(entry).flatMap(([name, child]) => [
        name,
        ...(name === "match" && child && typeof child === "object"
          ? Object.keys(child).sort()
          : shape(child)),
      ]);
    };
    if (JSON.stringify(shape(source.get(key))) !== JSON.stringify(shape(value))) {
      throw new Error(`${locale}.${key} selector shape differs from en`);
    }
  }
}

const process = Bun.spawn(["bun", "run", "i18n:compile"], {
  cwd: new URL("..", import.meta.url).pathname,
  stdout: "inherit",
  stderr: "inherit",
});
if ((await process.exited) !== 0) throw new Error("Paraglide compilation failed");
