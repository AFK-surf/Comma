const frontMatterPattern = /^---\n([\s\S]*?)\n---(?:\n|$)/;

const normalizeNewlines = (content: string) =>
  content.replace(/^﻿/, "").replace(/\r\n?/g, "\n");

/** The SKILL.md body without its YAML front matter, for on-page rendering. */
export function skillMarkdownBody(content: string) {
  return normalizeNewlines(content).replace(frontMatterPattern, "").trim();
}

/**
 * SKILL.md rewritten so it reads the same wherever it is pasted.
 *
 * Raw YAML front matter is only understood by front-matter-aware tools; any
 * other CommonMark renderer (GitHub comments, Notion, chat apps) turns
 * `---`/`key: value`/`---` into a rule followed by a setext heading. The
 * metadata therefore moves into a fenced `yaml` block, which every renderer
 * shows verbatim, under a title when the body does not bring its own.
 */
export function portableSkillMarkdown(name: string, content: string) {
  const normalized = normalizeNewlines(content);
  const frontMatter = frontMatterPattern.exec(normalized)?.[1]?.trim();
  const body = normalized.replace(frontMatterPattern, "").trim();
  // The fence must outrun any backtick run inside the metadata it wraps.
  const longestRun = Math.max(
    0,
    ...(frontMatter?.match(/`+/g) ?? []).map((run) => run.length)
  );
  const fence = "`".repeat(Math.max(3, longestRun + 1));

  return `${[
    ...(/^#\s/.test(body) ? [] : [`# ${name}`]),
    ...(frontMatter ? [`${fence}yaml\n${frontMatter}\n${fence}`] : []),
    ...(body ? [body] : []),
  ].join("\n\n")}\n`;
}
