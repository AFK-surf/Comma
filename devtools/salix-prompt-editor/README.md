# Salix Prompt Atlas

Local, source-aware editor for Salix system prompts, tool descriptions, and
preset skills. The browser only reads generated catalog data and stores drafts
in `localStorage`. It never reads or writes Salix source directly.

## Run

Requirements:

- Bun 1.3.14+
- A logged-in `codex` CLI available on `PATH`
- A local Comma checkout containing this directory

```sh
cd devtools/salix-prompt-editor
bun install
bun run dev
```

Open <http://127.0.0.1:4317>. The Vite frontend proxies its API to the Bun
backend on port 4318.

For a production-style local build:

```sh
bun run build
bun run start
```

Open <http://127.0.0.1:4318>.

## Data and task lifecycle

- `data/catalog.generated.json` is the generated, browser-readable snapshot.
- `prompts/extract.md`, `prompts/explain.md`, and `prompts/apply.md` are the
  fixed Codex prompts for extraction, line explanation, and apply.
- `.local/pending-changes.json` is the gitignored handoff that `Save & Apply`
  writes before it starts Codex.
- `.local/explanation-session.json` stores the Codex session id that later
  explanation clicks resume. Other files under `.local/` are temporary.

Full extraction asks Codex to inventory every supported source. Extraction is
blocked while browser drafts exist. The “解释” button on a line asks one
read-only Codex session, rooted at the repository, for a Chinese explanation.
Explanations are not stored in the catalog.

`Save & Apply` writes one pending manifest, then starts Codex with workspace
write access at the repository root. Bun never applies a source patch. If
focused validation passes, Bun starts a full extraction and clears the pending
manifest. If validation fails, source changes and pending data remain for the
user to handle in a normal Codex task.

## Safety boundary

- The server binds to `127.0.0.1` only.
- Mutating endpoints require a process-local CSRF token and trusted Origin.
- Browser requests cannot provide commands, repository roots, prompt paths,
  Codex arguments, or arbitrary destination paths.
- Codex is launched without a shell and receives fixed prompts through stdin.
- The extraction Codex can write only inside this tool directory. The
  explanation Codex session is rooted at the repository and runs read-only.
- Apply targets are constrained by the fixed prompt to Salix prompt/tool
  sources and Markdown under `resources/salix-system-files/skills/`.

## Checks

```sh
bun run typecheck
bun run test
bun run build
bun run validate:catalog
```
