# Salix Prompt Atlas: full source-inventory task

You are the extraction engine for the local Salix Prompt Atlas developer tool.
Work exhaustively and do not ask questions.

## Write boundary

- Treat the Comma repository as read-only.
- The only file you may create or modify is
  `data/catalog.generated.json` under the current `devtools/salix-prompt-editor`
  directory.
- Do not modify Salix source, skills, tests, lockfiles, or any other file.
- Do not create a Git commit.

## Required catalog

Generate the source inventory for one schema-version-1 catalog matching
`shared/schema.ts`. Line explanations are handled later by one persistent,
repository-aware Codex session; this task owns only source discovery and rule
classification.
Include:

1. **System** documents: every repo-authored, static system-prompt source used
   by Salix, including the main agent modules and independent Judge, title,
   meeting, triage, recommendation, and meeting-agent system prompts.
   Represent source modules separately. Do not invent a single runtime-composed
   prompt. Preserve repo-authored dynamic/interpolated template lines and
   composition expressions as editable source lines with precise provenance;
   do not replace them with synthetic labels or expand their runtime values.
2. **Tool** documents: one document per statically registered Salix tool. Only
   include human-authored description/manual prose. Exclude generated flags,
   schemas, and examples. If prose is assembled from literals, render the
   logical prose lines and cite the smallest accurate source range.
3. **Skill** documents: every `SKILL.md` and every `references/*.md` beneath
   `../../resources/salix-system-files/skills/`. A skill's `SKILL.md` is one
   document and each reference is a child document identified in its title and
   description. Exclude scripts, examples, and assets. Parse top-level YAML
   frontmatter into `frontmatter`; do not duplicate those YAML lines in `lines`.

Start by running `bun run catalog:base`. It deterministically inventories all
Skill/Reference Markdown and straightforward static System Prompt heredocs with
exact physical line provenance. Then inspect and enrich that catalog: add
missing concatenated/function-based System prompts, add every registered Tool
description, replace heuristic/pending rule classifications, and correct any
source-form nuance the base inventory could not infer. The helper is a scaffold,
not a substitute for the required Codex review. The schema-version-1 legacy
`translation` field must always be an empty string; explanations are never
stored in the generated catalog.

For each logical content line:

- Use a stable id derived from repo-relative path, source symbol when present,
  and logical source offset. Never use text as identity.
- Preserve English source text exactly in `text`.
- Set the legacy `translation` field to an empty string.
- Set the exact repo-relative source path and 1-based line range.
- Mark direct static prose and repo-authored dynamic template/source
  expressions editable. Preserve interpolation tokens such as `#{...}` and
  `{{...}}` exactly. Only generated runtime values with no writable repository
  source node are read-only.
- Classify the line as `positive`, `negative`, `mixed`, or `non_rule` and give
  a short Chinese reason. Imperative requirements are positive; prohibitions,
  “never”, “do not”, and forbidden behavior are negative; lines containing
  both are mixed; headings, examples, fragments, and descriptive context are
  non-rules.
- Fold each consecutive run of blank source lines into one `blank_range` line.
  Its source range must cover the full run and its text/translation are empty.

Use `placeholder` only when a runtime value has no editable repository source
node. Never recover a source by searching for matching final text: repeated
text is common. Cite the actual defining node.

## Main prompt orientation

The main composer is in
`../../systems/apps/salix_agent/lib/salix_agent/tool_policy.ex`. Its static
module attributes, multi-agent collaboration templates, editable Tool
Disclosure / Agent config / Skill / Agent Instructions source expressions,
Slack rules, and router language contract must be represented as separate
source modules. Preserve the dynamic source expressions; do not expand their
runtime values.

Tool registry orientation starts at
`../../systems/apps/salix_agent/lib/salix_agent/tools.ex`; descriptions are
distributed across `tools/*.ex`. Inspect registry membership rather than
assuming every module is a tool.

## Validation and final response

After writing the catalog:

1. Run `bun run validate:catalog` in this tool directory.
2. Count documents, lines, and already classified lines.
3. Return only the structured result required by the supplied output schema.
4. `success` is true only when the catalog validates and all required source
   groups were inspected. Put any deliberately read-only or unsupported source
   form in `warnings`; do not silently omit it.
