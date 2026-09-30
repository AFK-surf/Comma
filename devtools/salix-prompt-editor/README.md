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

Open <http://127.0.0.1:4317>. The Vite frontend proxies its fixed API to the
Bun backend on port 4318.

For a production-style local build:

```sh
bun run build
bun run start
```

Open <http://127.0.0.1:4318>.

## Data and task lifecycle

- `data/catalog.generated.json` is the generated, browser-readable snapshot.
- `prompts/extract.md` is the fixed Codex source-inventory prompt.
- `prompts/explain.md` is the fixed repository-aware line-explanation prompt.
- `prompts/apply.md` is the fixed Codex apply prompt.
- `.local/pending-changes.json` is the gitignored handoff written immediately
  before `Save & Apply` starts Codex.
- `.local/explanation-session.json` stores the dedicated Codex session id so
  later explanation clicks resume the same repository-aware conversation.
  Explanation request and structured result files under `.local/` are ephemeral.

Full extraction asks Codex to inventory every supported source and classify its
rules. The System Prompt view then composes those source documents in the
production `ToolPolicy.compose_session_prompt/6` order for Router and Worker;
shared source modules appear in both role views but write to one shared draft.
Runtime-composed Tool Disclosure, agent config, skills, and Agent Instructions
appear as editable source expressions when a repository source node exists. Only
runtime values with no writable source remain read-only. Extraction is blocked
while browser drafts exist.
Clicking a static line's “解释” button sends its text, source location, module,
and composition context to one dedicated Codex session rooted at the Comma
repository. The first click creates a persistent read-only GPT-5.6 Luna
session; later clicks are serialized through `codex exec resume` with the same
session id. Codex reads focused Salix source and call sites before returning a
concise Chinese explanation beneath the line. Explanations are not translations
and are not stored in the catalog.
Editable source lines use an in-place plain-text editing surface: clicking puts
the caret directly in the existing line element without swapping in a textarea.
Typing updates the local draft immediately, Escape restores the focused value,
and Enter inserts the next logical line.

`Save & Apply` writes one pending manifest, then launches Codex with workspace
write access at the Comma repository root. Bun never applies a source patch. If
focused validation passes, Bun starts a full extraction and clears the pending
manifest. If validation fails, source changes and pending data remain for the
user to handle in a normal Codex task.

## Safety boundary

- The server binds to `127.0.0.1` only.
- Mutating endpoints require a process-local CSRF token and trusted Origin.
- Browser requests cannot provide commands, repository roots, prompt paths,
  Codex arguments, or arbitrary destination paths.
- Codex is launched without a shell and receives fixed prompts through stdin.
- The extraction Codex can write only inside this tool directory; the dedicated
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
