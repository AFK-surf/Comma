import { spawnSync } from "node:child_process";
import { access, readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { selectorShape } from "./catalog-shape.mjs";

const require = createRequire(import.meta.url);
const locales = ["en", "zh-CN"];
const pluginUrls = [
  pathToFileURL(require.resolve("@inlang/plugin-message-format")),
  pathToFileURL(require.resolve("@inlang/plugin-m-function-matcher")),
];
await Promise.all(pluginUrls.map((url) => access(url)));
const catalogs = await Promise.all(
  locales.map(async (locale) =>
    JSON.parse(
      await readFile(new URL(`../messages/${locale}.json`, import.meta.url), "utf8")
    )
  )
);

function entries(catalog) {
  if (!catalog || typeof catalog !== "object" || Array.isArray(catalog)) {
    throw new Error("Each i18n catalog must be an object.");
  }
  return new Map(Object.entries(catalog).filter(([key]) => key !== "$schema"));
}

function strings(value) {
  if (typeof value === "string") return [value];
  if (Array.isArray(value)) return value.flatMap(strings);
  if (value && typeof value === "object") return Object.values(value).flatMap(strings);
  return [];
}

function parameters(value) {
  return [
    ...new Set(
      strings(value).flatMap((text) =>
        [...text.matchAll(/\{\s*([\w]+)\s*\}/g)].map((match) => match[1])
      )
    ),
  ].toSorted();
}

const source = entries(catalogs[0]);
const sourceKeys = [...source.keys()].toSorted();

for (const [index, locale] of locales.entries()) {
  const target = entries(catalogs[index]);
  const targetKeys = [...target.keys()].toSorted();
  if (JSON.stringify(sourceKeys) !== JSON.stringify(targetKeys)) {
    const missing = sourceKeys.filter((key) => !target.has(key));
    const extra = targetKeys.filter((key) => !source.has(key));
    throw new Error(
      `${locale} message keys differ from en (missing: ${missing.join(", ") || "none"}; extra: ${extra.join(", ") || "none"}).`
    );
  }
  for (const key of sourceKeys) {
    const value = target.get(key);
    const values = strings(value);
    if (values.length === 0 || values.some((text) => !text.trim())) {
      throw new Error(`${locale}.${key} is empty.`);
    }
    if (
      JSON.stringify(parameters(source.get(key))) !== JSON.stringify(parameters(value))
    ) {
      throw new Error(`${locale}.${key} parameters differ from en.`);
    }
    if (
      JSON.stringify(selectorShape(source.get(key))) !==
      JSON.stringify(selectorShape(value))
    ) {
      throw new Error(`${locale}.${key} selector shape differs from en.`);
    }
  }
}

const packageDirectory = fileURLToPath(new URL("..", import.meta.url));
const paraglideCli = fileURLToPath(
  new URL("../bin/run.js", pathToFileURL(require.resolve("@inlang/paraglide-js")))
);
const compile = spawnSync(
  process.execPath,
  [
    paraglideCli,
    "compile",
    "--project",
    "./project.inlang",
    "--outdir",
    "./src/paraglide",
    "--strategy",
    "globalVariable",
    "baseLocale",
    "--emit-ts-declarations",
  ],
  {
    cwd: packageDirectory,
    encoding: "utf8",
  }
);
if (compile.stdout) process.stdout.write(compile.stdout);
if (compile.stderr) process.stderr.write(compile.stderr);
if (compile.status !== 0) {
  throw new Error(`Paraglide compilation failed with exit code ${compile.status}.`);
}

const generated = await import(
  new URL(`../src/paraglide/messages.js?catalog-check=${Date.now()}`, import.meta.url)
    .href
);
const missingGenerated = sourceKeys.filter(
  (key) => typeof generated[key] !== "function"
);
if (missingGenerated.length > 0) {
  throw new Error(
    `Paraglide output is missing catalog messages: ${missingGenerated.join(", ")}.`
  );
}

console.log(
  `Validated and compiled ${sourceKeys.length} messages in ${locales.join(", ")}.`
);
