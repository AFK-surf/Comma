import { relative, resolve } from "node:path";
import { parse as parseYaml } from "yaml";
import type {
  Catalog,
  Classification,
  FrontmatterField,
  PromptDocument,
  PromptLine,
  SourceLocation,
} from "../shared/schema";

const toolRoot = resolve(import.meta.dir, "..");
const repoRoot = resolve(toolRoot, "../..");
const skillRoot = resolve(repoRoot, "resources/salix-system-files/skills");
const catalogPath = resolve(toolRoot, "data/catalog.generated.json");

function repoPath(path: string): string {
  return relative(repoRoot, path).replaceAll("\\", "/");
}

function classify(text: string): {
  classification: Classification;
  classificationReason: string;
} {
  const value = text.trim();
  if (
    !value ||
    /^(#{1,6}\s|```|~~~|\|)|^[-*_]{3,}$/.test(value) ||
    /^https?:\/\//.test(value)
  ) {
    return { classification: "non_rule", classificationReason: "结构、标题或非规则内容" };
  }

  const negative =
    /\b(do not|don't|never|must not|may not|cannot|can't|forbidden|avoid|without permission|only when)\b/i.test(
      value,
    );
  const positive =
    /\b(must|should|always|required|ensure|use|keep|provide|return|call|read|write|run|include|prefer|follow|treat|send|create|choose|check|verify|report)\b/i.test(
      value,
    ) || /^[-*]\s+[A-Z][a-z]+\b/.test(value);

  if (positive && negative) {
    return { classification: "mixed", classificationReason: "同时包含要求与禁止条件" };
  }
  if (negative) return { classification: "negative", classificationReason: "包含禁止或限制措辞" };
  if (positive) return { classification: "positive", classificationReason: "包含明确动作或要求" };
  return { classification: "non_rule", classificationReason: "描述、示例或上下文信息" };
}

function contentLine(
  idPrefix: string,
  text: string,
  source: SourceLocation,
  editable = true,
): PromptLine {
  return {
    id: `${idPrefix}:${source.lineStart}`,
    kind: "text",
    text,
    translation: "",
    source,
    editable,
    ...classify(text),
  };
}

function foldPhysicalLines(
  idPrefix: string,
  lines: string[],
  path: string,
  startLine: number,
  editable = true,
): PromptLine[] {
  const output: PromptLine[] = [];
  let index = 0;
  while (index < lines.length) {
    if (lines[index] !== "") {
      const lineNumber = startLine + index;
      output.push(
        contentLine(
          idPrefix,
          lines[index]!,
          { path, lineStart: lineNumber, lineEnd: lineNumber },
          editable,
        ),
      );
      index += 1;
      continue;
    }

    const blankStart = index;
    while (index < lines.length && lines[index] === "") index += 1;
    output.push({
      id: `${idPrefix}:blank:${startLine + blankStart}`,
      kind: "blank_range",
      text: "",
      translation: "",
      source: {
        path,
        lineStart: startLine + blankStart,
        lineEnd: startLine + index - 1,
      },
      editable,
      classification: "non_rule",
      classificationReason: "连续空白行",
    });
  }
  return output;
}

function flattenFrontmatter(
  sourceLines: string[],
  path: string,
  startLine: number,
): FrontmatterField[] {
  const yamlText = sourceLines.join("\n");
  const parsed = (parseYaml(yamlText) ?? {}) as Record<string, unknown>;
  const fields: FrontmatterField[] = [];

  function walk(value: unknown, prefix: string[] = []) {
    if (value && typeof value === "object" && !Array.isArray(value)) {
      for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
        walk(child, [...prefix, key]);
      }
      return;
    }
    const key = prefix.join(".");
    const leaf = prefix.at(-1)!;
    const sourceIndex = sourceLines.findIndex((line) =>
      new RegExp(`^\\s*${leaf.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}:`).test(line),
    );
    const line = startLine + Math.max(0, sourceIndex);
    fields.push({
      key,
      value: Array.isArray(value) ? value.join(", ") : String(value ?? ""),
      source: { path, lineStart: line, lineEnd: line },
      editable: true,
    });
  }

  walk(parsed);
  return fields;
}

async function skillDocuments(): Promise<PromptDocument[]> {
  const paths = new Set<string>();
  for (const pattern of ["**/SKILL.md", "**/references/**/*.md"]) {
    const glob = new Bun.Glob(pattern);
    for await (const path of glob.scan({ cwd: skillRoot, absolute: true, onlyFiles: true })) {
      paths.add(path);
    }
  }

  const documents: PromptDocument[] = [];
  for (const absolutePath of [...paths].sort()) {
    const path = repoPath(absolutePath);
    const physical = (await Bun.file(absolutePath).text()).replace(/\n$/, "").split("\n");
    const relativeSkillPath = relative(skillRoot, absolutePath).replaceAll("\\", "/");
    const skillName = relativeSkillPath.split("/")[0]!;
    const isRoot = relativeSkillPath.endsWith("/SKILL.md");
    let bodyStart = 0;
    let frontmatter: FrontmatterField[] = [];

    if (isRoot && physical[0] === "---") {
      const closing = physical.findIndex((line, index) => index > 0 && line === "---");
      if (closing > 0) {
        frontmatter = flattenFrontmatter(physical.slice(1, closing), path, 2);
        bodyStart = closing + 1;
      }
    }

    const title = isRoot
      ? skillName
      : `${skillName} / ${relativeSkillPath.split("/").at(-1)}`;
    const id = `skill:${relativeSkillPath}`;
    documents.push({
      id,
      category: "skill",
      title,
      description: isRoot
        ? `Preset Skill · ${relativeSkillPath}`
        : `Skill reference · ${relativeSkillPath}`,
      sourcePaths: [path],
      frontmatter,
      lines: foldPhysicalLines(id, physical.slice(bodyStart), path, bodyStart + 1),
    });
  }
  return documents;
}

type Heredoc = {
  symbol: string;
  start: number;
  end: number;
  content: string[];
  module: string;
};

function relevantAttribute(symbol: string, path: string): boolean {
  if (path.endsWith("multi_agent_collaboration_prompt.ex")) {
    return ["common", "worker", "router"].includes(symbol);
  }
  return /system_prompt|agent_prompt|base_prompt|tool_prompt|default_agent_prompt|source_prompt|message_language_prompt|slack_mentions_prompt/.test(
    symbol,
  );
}

function scanHeredocs(source: string, path: string): Heredoc[] {
  const lines = source.split("\n");
  const module = lines.find((line) => /^defmodule\s+/.test(line))?.match(/^defmodule\s+([^\s]+)/)?.[1] ?? path;
  const output: Heredoc[] = [];
  let pendingFunction: string | null = null;

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]!;
    const functionMatch = line.match(/^\s*defp?\s+(system_prompt(?:\([^)]*\))?)[^]*\bdo\s*$/);
    if (functionMatch) pendingFunction = functionMatch[1]!;

    const attributeMatch = line.match(/^\s*@([A-Za-z0-9_]+)\s+"""\s*$/);
    const functionStart = pendingFunction && /^\s*"""\s*$/.test(line);
    const symbol = attributeMatch?.[1] ?? (functionStart ? pendingFunction : null);
    if (!symbol || (!functionStart && !relevantAttribute(symbol, path))) continue;

    const closing = lines.findIndex(
      (candidate, candidateIndex) => candidateIndex > index && /^\s*"""(?:\s*\|>)?/.test(candidate),
    );
    if (closing < 0) continue;
    const indent = lines[closing]!.match(/^(\s*)/)?.[1].length ?? 0;
    const content = lines.slice(index + 1, closing).map((contentLine) =>
      contentLine.startsWith(" ".repeat(indent)) ? contentLine.slice(indent) : contentLine,
    );
    output.push({ symbol, start: index + 2, end: closing, content, module });
    index = closing;
    pendingFunction = null;
  }
  return output;
}

async function systemDocuments(): Promise<PromptDocument[]> {
  const roots = ["salix_agent", "salix_web", "comma_web", "salix_meet"];
  const documents: PromptDocument[] = [];
  for (const app of roots) {
    const cwd = resolve(repoRoot, `systems/apps/${app}`);
    const glob = new Bun.Glob("**/*.ex");
    for await (const absolutePath of glob.scan({ cwd, absolute: true, onlyFiles: true })) {
      const path = repoPath(absolutePath);
      const source = await Bun.file(absolutePath).text();
      for (const heredoc of scanHeredocs(source, path)) {
        const id = `system:${path}:${heredoc.symbol}:${heredoc.start}`;
        documents.push({
          id,
          category: "system",
          title: `${heredoc.module}.${heredoc.symbol}`,
          description: `Static system-prompt source module · lines ${heredoc.start}–${heredoc.end}`,
          sourcePaths: [path],
          frontmatter: [],
          lines: foldPhysicalLines(id, heredoc.content, path, heredoc.start),
        });
      }
    }
  }

  const path = "systems/apps/salix_agent/lib/salix_agent/tool_policy.ex";
  const dynamicSourceLines = [256, 257, 258, 259];
  const dynamicSource = (await Bun.file(resolve(repoRoot, path)).text()).split("\n");
  documents.push({
    id: "system:tool-policy:dynamic-placeholders",
    category: "system",
    title: "SalixAgent.ToolPolicy.dynamic_sections",
    description: "Editable runtime Prompt source expressions in compose_session_prompt/6.",
    sourcePaths: [path],
    frontmatter: [],
    lines: dynamicSourceLines.map((line) => ({
      id: `system:tool-policy:placeholder:${line}`,
      kind: "text",
      text: dynamicSource[line - 1]!.trim(),
      translation: "",
      source: {
        path,
        lineStart: line,
        lineEnd: line,
        symbol: "compose_session_prompt/6",
      },
      editable: true,
      classification: "non_rule",
      classificationReason: "运行时 Prompt 源表达式",
    })),
  });
  return documents.sort((left, right) => left.title.localeCompare(right.title));
}

const documents = [...(await systemDocuments()), ...(await skillDocuments())];
const hasher = new Bun.CryptoHasher("sha256");
hasher.update(
  documents
    .map((document) =>
      [document.id, ...document.lines.map((line) => `${line.id}:${line.text}`)].join("\n"),
    )
    .join("\n\n"),
);

const catalog: Catalog = {
  schemaVersion: 1,
  catalogVersion: hasher.digest("hex"),
  generatedAt: new Date().toISOString(),
  documents,
};

await Bun.write(catalogPath, `${JSON.stringify(catalog)}\n`);
console.log(
  `base catalog: ${documents.length} documents, ${documents.reduce((sum, document) => sum + document.lines.length, 0)} elements`,
);
