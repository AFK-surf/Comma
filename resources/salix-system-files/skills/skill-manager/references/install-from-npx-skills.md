# Install Skill via npx skills CLI

When the user asks to install a skill using `npx skills add`.

## Process

### Step 1: Run the CLI command

```bash
npx skills add <skill-name>
```

### Step 2: Parse output for installation path

The CLI will output the installation directory. Look for the path in the output (typically something like `.claude/skills/xxx/` or `.cursor/skills/xxx/`).

### Step 3: Create a cloud-managed skill

After successful installation, read the installed `SKILL.md`, choose a `skill_id`, and call `skill.create`. Then write any bundled files through normal file tools under `/.runtime/skills/<skill_id>/...`.

Preserve the source folder's internal relative paths when writing resources.

### Step 4: Report

Report both:

- Original installation location (from CLI output)
- Runtime skill path: `/.runtime/skills/<skill_id>/SKILL.md`

## Critical Rules

1. **Always create through `skill.create`** — this ensures the skill is available through the current SkillStore projection
2. **Preserve folder structure** — copy the entire skill folder, not just SKILL.md
3. **Handle name conflicts** — if the skill name or id already exists, append a counter (e.g., `skill-name-2`)
