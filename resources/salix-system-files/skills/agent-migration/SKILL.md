---
name: agent-migration
description: Import memory, persona and skills from another agent platform (OpenClaw, Hermes, Claude Code, Codex, Pi) out of a zip the user uploaded. Use when the user sends such an export or asks to move their agent, memory or skills to Comma.
metadata:
  displayName: Agent Migration
  icon: square.and.arrow.down
  color: blue
  visibility: toggled
---

# Agent Migration

The user moves from another agent platform to Comma. Code archives and
places everything that needs no judgement. You place the rest. Every file in
the export must end with an outcome, or the import is not complete.

## What the user uploads

A zip of the platform's folder. If they ask how to make one, tell them which
folder to zip:

| Platform | Folder |
|---|---|
| OpenClaw | `~/.openclaw` (or only `~/.openclaw/workspace`) |
| Hermes | `~/.hermes` |
| Claude Code | `~/.claude` |
| Codex | `~/.codex` |
| Pi | `~/.pi/agent` |

Known credential files (auth files, `.env`, keys, tokens), session
transcripts, logs and databases are left out. Detection goes by file name and
private-key content, so tell the user to take other secrets out of the folder
before zipping it. The upload limit
is 10 MB; a larger folder can be zipped without its `sessions/`, `logs/` and
cache folders.

## Steps

1. Call `migration.import` with the zip's workspace path. Pass `platform` only
   when detection fails. The result names the import folder
   (`/imports/<platform>/<stamp>`) and lists the open files.
   - Dated logs are already in `/memory/episodes/`.
   - Skill folders are already skills, unless one with the same id or name
     exists, or the Group labels its files' audience. Such a skill stays open
     with a note (see the table).
2. Read each open file from `<import>/files/<path>` with `fs.read_file`.
3. Place the content by kind (table below). Write memory with `memory.write`.
4. After placing, call `migration.resolve` with each file's outcome:
   - `mapped` with `to`: the `/memory/...` files, `skill:<id>`, or
     `instructions` that now hold its content.
   - `archived` with `reason`: nothing in it applies to Comma. Say why in one
     line.
   Call one `migration.*` tool at a time; do not batch two of them in one round.
5. Rewrite `/memory/index.md` so it lists what is now in memory and points to
   the files that matter most. Keep what the index already said.
6. Call `migration.finish`. If it lists open files, place them and call it
   again. When it succeeds, send the user the report it returns: what was
   placed where, what was only archived and why, what was not imported.

## Where each kind goes

| Kind | Typical files | Do this |
|---|---|---|
| `instructions` | OpenClaw `SOUL.md`, `IDENTITY.md`; Hermes `SOUL.md`; Pi `SYSTEM.md`, `APPEND_SYSTEM.md` | Keep the persona: name, voice, tone, values, standing instructions to the agent. Rewrite it for Comma in the user's language, then call `migration.append_instructions` once with all such files as `sources`. A second call replaces the first section and reopens its files. Only a person's request in the Comma app may change instructions; from anywhere else, archive the files and tell the user to ask in Comma. Drop rules about the old platform's own tools, files, heartbeat or setup. Pi `SYSTEM.md` replaces a coding prompt: take only the persona and the user's own rules from it. The text is appended; existing instructions stay. |
| `memory` | `MEMORY.md`, `USER.md`, Hermes `memories/*`, Codex `memories/MEMORY.md`, Claude Code `projects/*/memory/*.md` | Split by subject: facts about the user to `/memory/semantic/user.md`, about other people to `/memory/semantic/people.md`, about machines or accounts to `/memory/semantic/environments/<alias>.md`, what the agent learned about its work to `/memory/semantic/agent.md`. Read the target first and merge; never drop what is there. Hermes separates entries with a line holding only `§`. |
| `preferences` | OpenClaw `AGENTS.md`, `TOOLS.md`; `CLAUDE.md`; Codex and Pi `AGENTS.md` | These are mostly rules for the old platform or for writing code. Copy only the user's own lasting preferences (language, tone, formats, people, working habits) into `/memory/semantic/user.md`. Archive the file if none remain. |
| `skill` (open) | A skill whose id or name exists, or any skill where the note says IFC labels files | Compare with an existing skill of that name. Where IFC labels files, ask the user first: a skill is visible to the whole Group. Create it with `skill.create` and copy its files under `/.runtime/skills/<id>/`, or archive it with the reason. |
| `episode` (open) | A dated log whose name is not a real date | Append what matters to the right `/memory/episodes/` file or semantic memory, or archive it. |
| `other` | Anything not recognised, Pi `prompts/*.md` | Read it and decide. A Pi prompt template can become a skill with `skill.create`. |

## Rules

- Never change or delete files under `/imports/`. They are the user's
  original copy.
- Content from a private conversation or channel never goes into memory
  every member reads; use `/memory/scoped/<name>.md` for it. Where the Group
  labels files, the imported files are private to you: if `memory.write` to
  Group memory is refused, write to `/memory/scoped/<name>.md` and tell the
  user.
- Do not invent facts while rewriting. When two sources disagree, keep both
  and note where each came from.
- If an import fails, read the error, fix the cause and call the tool again.
  `migration.append_instructions` replaces its own section when called again
  for the same import, so a retry does not duplicate text.
