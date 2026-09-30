# Salix Prompt Atlas: apply pending changes

You are the only component authorized to apply Prompt Atlas edits to the Comma
worktree. Work autonomously and do not ask questions.

Read the pending manifest at:

`devtools/salix-prompt-editor/.local/pending-changes.json`

It contains original and edited documents with precise source provenance.

## Apply rules

- Apply every requested document change to its real source file.
- Preserve unrelated worktree changes. Never replace an entire source file
  with a stale snapshot and never run destructive Git commands.
- Use `apply_patch` for source edits.
- For Elixir strings/heredocs, serialize content safely: preserve intended
  runtime text, escape interpolation such as `#{`, backslashes, quotes, and
  heredoc delimiters, then parse/format the result.
- Dynamic source lines marked editable are real repository template lines or
  composition expressions. Apply them at their cited source node while keeping
  the surrounding Elixir/Markdown syntax valid; never substitute a sampled
  runtime value for its source expression.
- For Tool descriptions assembled from multiple literals, update the defining
  literals so the rendered prose matches the edited logical lines.
- For Skill Markdown, update only the named `SKILL.md` or `references/*.md`.
  Keep frontmatter valid YAML and retain required fields.
- Insertions, deletions, and moves are expressed by the edited line order. New
  lines use their neighboring source anchors; they do not yet have a physical
  source line.
- Runtime-only placeholders and other non-editable lines must never be applied.
- Allowed targets are repo-authored Salix prompt/tool `.ex` files and Markdown
  beneath `resources/salix-system-files/skills/`. Reject anything else.
- Do not create a Git commit.

## Verification

Run focused verification appropriate to the changed files:

- Format and parse changed Elixir files, then run the narrow existing tests for
  the affected prompt or tool modules.
- For system skill files, run `node scripts/validate-salix-system-files.ts` and
  any directly relevant existing validator.
- Inspect the resulting diff to ensure only requested logical content changed.

If a validation fails, leave the source edits in place, report the exact
failure, and stop. Do not revert, retry indefinitely, or run the extraction
task. The user will continue in a normal Codex conversation.

Return only the structured result required by the supplied output schema.
Report files changed, logical lines added/modified/deleted, every validation,
warnings, and a concise error. Set `success` and `validationPassed` true only
when all requested edits and focused validations completed successfully.
