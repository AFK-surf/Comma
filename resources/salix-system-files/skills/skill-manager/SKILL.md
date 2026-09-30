---
name: skill-manager
description: |
  Manage skills: create, install, modify, or delete skills.
  Trigger when user asks to: "create a skill", "save this as a skill", "install this skill" (from URL/link), "edit/modify a skill", "delete a skill".
  Cloud-managed skills are exposed through /.runtime/skills/.
metadata:
  displayName: Skill Manager
  icon: folder.badge.plus
  color: red
  visibility: toggled
  placeholder: Describe the skill to create, install, or manage
---

# Skill Manager

This skill provides guidance for all skill-related operations: creating, installing, modifying, and deleting skills.

## About Skills

Skills are modular, self-contained packages that extend the agent by providing specialized workflows and bundled resources. Think of them as an "onboarding guide" for a specific task category.

## Skill Files

Cloud-managed skills are exposed through the session runtime files mount:

```text
/.runtime/skills/index.md
/.runtime/skills/<skill_id>/SKILL.md
/.runtime/skills/<skill_id>/<resource_path>
```

Read discovery data from `/.runtime/skills/index.md`. Read or edit skill files with normal file tools under `/.runtime/skills/<skill_id>/...`.

Create, copy, and delete skill records with the skill catalog tools. Do not create a skill by writing an arbitrary directory first.

---

## Operation: Install Skill from URL

When the user provides a URL to a skill (e.g., `https://example.com/dot_claude/skills/xxx/SKILL.md`) and asks to "install this skill".

**Read the detailed guide**: `references/install-from-url.md`

---

## Operation: Install Skill via npx skills CLI

When the user asks to install a skill using `npx skills add`.

**Read the detailed guide**: `references/install-from-npx-skills.md`

---

## Operation: Create Skill from Current Conversation

Convert the current multi-turn chat solution into a reusable custom skill.

**Read the detailed guide**: `references/create-from-conversation.md`

---

## Operation: Modify Existing Skill

When the user asks to modify, edit, or update an existing skill:

1. **Locate** the skill in `/.runtime/skills/index.md`.
2. **Read** current content from `/.runtime/skills/<skill_id>/SKILL.md`.
3. **Apply changes** through normal file tools under `/.runtime/skills/<skill_id>/...`.
4. **Validate** if possible
5. **Report** what was changed

**Note**: Read-only skills cannot be modified in place. To customize behavior, copy them with `skill.copy`, then edit the new editable skill under `/.runtime/skills/<new_skill_id>/`.

---

## Operation: Delete Skill

When the user asks to delete or remove a skill:

1. **Confirm ownership**: only editable skills created by this agent can be deleted.
2. **Confirm with user** (list what will be removed)
3. **Delete** with `skill.delete`.
4. **Report** deletion

**Cannot delete**: read-only system skills or skills created by another agent.
