# Create Skill from Current Conversation

Convert the current multi-turn chat solution into a reusable custom skill. Use when the user wants to "save this workflow as a skill" so future chats can complete similar tasks faster.

## Core Principles

### Concise is Key

The context window is a public good. The new skill will share context with everything else (system prompt, conversation history, other skills). Keep it lean.

**Default assumption: the agent is already capable.** Only add non-obvious procedural knowledge, hard constraints, and fragile edge cases. Prefer concise examples over verbose explanations.

### Capability reuse first (do not re-invent the agent)

You are converting a workflow that already succeeded in this agent environment.

The default goal is to **compose existing capabilities**:

- Existing tools (e.g. web search, browser context, file operations, bash)
- Existing skills (built-in workflow guides, domain procedures, quality gates)

Only add scripts when they provide clear value that existing tools/skills do not:

- Deterministic reliability for fragile steps
- Repeated code you would otherwise rewrite
- Offline transformation/validation helpers

**Anti-pattern:** writing a single Python script that reimplements the whole workflow, especially when the agent already has tools/skills that do parts of it.

### Set Appropriate Degrees of Freedom

Match the level of specificity to the workflow's fragility and variability:

- **High freedom (text-based instructions)**: Multiple approaches are valid, decisions depend on context, or heuristics guide the approach.
- **Medium freedom (pseudocode or scripts with parameters)**: A preferred pattern exists, inputs vary, or configuration affects behavior.
- **Low freedom (specific scripts, few parameters)**: Operations are fragile and error-prone, consistency is critical, or a precise sequence must be followed.

### Progressive Disclosure

Keep SKILL.md body to the essentials and under ~500 lines. Split details into separate files when approaching this limit. Prefer one-level references: all reference files should link directly from SKILL.md (avoid deep nesting).

For reference files longer than ~100 lines, include a small table of contents at the top.

### What to Not Include

Do NOT create extraneous documentation files that are not used by the agent:

- README.md
- CHANGELOG.md
- QUICK_REFERENCE.md
- etc.

## Anatomy of the Output Skill

Create a new editable group skill through `skill.create`:

- `skill_id`: sanitized lower-case slug
- `name`: user-facing skill name
- `description`: trigger description
- `content`: initial `SKILL.md` content

The skill should contain:

- `SKILL.md` (required)
- Optional bundled resources (only if they add real value):
  - `scripts/` (deterministic reliability / repeated code)
  - `references/` (schemas, policies, API docs, deep patterns; loaded only when needed)
  - `assets/` (templates or files used in outputs; not intended to be loaded into context)

### No install-style tooling (important)

When creating resources (scripts, helpers, automation), keep them **inside the skill folder**.

- Do NOT create or modify global executables (e.g. `~/bin/*`, `/usr/local/bin/*`).
- Do NOT require installation steps for the user.
- Prefer running scripts by **path** from the skill folder (see below).

The goal is that the skill is self-contained and portable as a folder.

## Frontmatter Rules (critical)

- The folder name MUST be a sanitized slug:
  - replace spaces with `-`
  - remove characters other than `[A-Za-z0-9-]`
- The frontmatter `name` MUST equal the folder name (use the slug).
- The frontmatter `description` is the primary trigger mechanism:
  - Include what the skill does AND concrete triggers/contexts for when to use it.
  - Include negative triggers (when NOT to use it) if ambiguity is likely.
  - The max length is 240 words.

## Required clarification (ask only if missing)

Ask at most **3** questions, only if necessary:

1. New skill name (slug; e.g. `export-figma-assets`)
2. Trigger description (what it does + when to use it + when NOT to)
3. What should be parameters vs fixed assumptions (inputs/constraints)

If user already provided these, do not ask.

## Creation Process

Follow these steps in order, skipping only if there is a clear reason why they are not applicable.

### Step 0: Extract concrete examples from the current conversation

Do NOT copy the full chat log.

Instead, distill 1–3 concrete examples that represent the solved task class:

- What did the user ask, in a single sentence?
- What inputs existed (files, URLs, environment constraints)?
- What outputs were produced (files, commands, side effects)?
- What checks confirmed correctness?
- What mistakes/false starts happened that the new skill should explicitly avoid?

Conclude this step when the task class, constraints, and success criteria are clear.

### Step 0.5: Extract mistakes → guardrails (required)

Turn failed attempts from the conversation into explicit guardrails so future chats avoid the same detours.

Write guardrails as:

- **Do**: the proven path that worked (tools/skills used, order, checks)
- **Don't**: approaches that wasted time or caused errors (and why)
- **Only if**: conditions under which a discouraged approach becomes appropriate

Every **Don't** rule must be traceable to a real failure mode observed in this conversation.

### Step 1: Plan the reusable contents (scripts, references, assets)

From the examples above, identify what should be bundled to improve reliability and reduce repeated work:

- Use `scripts/` when code gets rewritten repeatedly or reliability is fragile.
- Use `references/` when detailed knowledge is needed but shouldn't bloat SKILL.md.
- Use `assets/` for templates/boilerplate that should be copied or modified.

Avoid duplication: information should live in either SKILL.md or reference files, not both.

For scripts:

- Place them under: `/.runtime/skills/<skill_id>/scripts/`
- Reference them from SKILL.md using relative paths (e.g. `scripts/generate.py`)
- Run them by copying or reading through the runtime file tools as needed; do not rely on a hidden storage path.

Script boundary rules:

- Prefer scripts that are **small and local** (one responsibility, clear inputs/outputs).
- Do not embed platform-level capabilities into scripts when the agent already has them (e.g. web search, web page fetching, file discovery).
- If a script uses network fetching or heavy dependencies, add a justification in SKILL.md explaining why existing tools/skills are insufficient.

Use these bundled references when helpful:

- Workflow structuring patterns: `references/workflows.md`
- Output/format quality patterns: `references/output-patterns.md`

### Step 2: Initialize the skill

Call `skill.create` with the chosen slug, name, description, and initial `SKILL.md` content. The returned path is `/.runtime/skills/<skill_id>/SKILL.md`.

If the skill already exists, ask whether to use a different slug such as `<skill-slug>-v2`.

### Step 3: Edit the skill (write SKILL.md and resources)

Write the skill for a fresh agent instance that does not have this chat context. Edit `SKILL.md` and any resource files through normal file tools under `/.runtime/skills/<skill_id>/...`.

**Writing guidelines:** Use imperative/infinitive form.

Avoid "template lock-in": do NOT force every generated skill to share the same body structure.

The SKILL.md body must clearly cover:

- What the skill does and does not do
- Inputs and parameters (required vs optional; defaults)
- Output artifacts and success criteria
- Reliable workflow (steps, checks, stop conditions)
- Validation checklist
- Guardrails ("Do / Don't / Only if") based on this conversation's failures
- Failure modes and recovery
- A couple of minimal examples

### Step 4: Verify (self-test)

Before finishing:

- Re-read the generated SKILL.md and confirm it is concise.
- Confirm frontmatter validity and name/folder match.
- Simulate a fresh conversation: confirm triggers + steps make sense without hidden context.
- Verify the new skill does not rely on hidden state (specific one-off paths, credentials, unstated assumptions).

Optionally run the bundled validator on the newly created skill files after copying them to an execution environment:

- `python3 scripts/quick_validate.py <local-copy-of-skill-folder>`

### Step 5: Iterate

After the next real use of the new skill:

1. Notice struggles or inefficiencies
2. Identify which part of SKILL.md/resources should change
3. Update and re-test

## Output requirements

After saving, report:

- skill name
- runtime path
- what parameters the user should provide next time
- one example invocation text the user can paste in a new chat
