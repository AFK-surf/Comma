---
name: feishu
description: "飞书 Feishu / Lark: messages, docs, wiki, sheets, Base, calendar, tasks, meetings, approvals, and mail through the official Lark CLI."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

Feishu recommends its official CLI `@larksuite/cli` (github.com/larksuite/cli)
for agents. It stores tokens in the OS keychain, so run it with `env.exec` on
the user's Mac.

## Setup

1. `npm i -g @larksuite/cli` (or `npx @larksuite/cli@latest install`).
2. `lark-cli config init` needs the App ID and App Secret of a self-built
   Feishu app. The user enters them in their own terminal.
3. User identity: `lark-cli auth login --domain <calendar|docs|im|...> --no-wait`
   returns a verification URL. Give it to the user, then resume with
   `lark-cli auth login --device-code <code>`. Use `--as bot` for bot actions.

## Use

- Discover commands with `lark-cli --help` and `lark-cli <domain> --help`. Do
  not guess flags.
- Output is a JSON envelope. Check `ok == true` before you report success.
- Use Lark international with `--domain https://open.larksuite.com` where the
  command asks for a domain.

The stdio `@larksuiteoapi/lark-mcp` package is older and cannot edit docs. The
personal remote MCP link covers cloud docs only and expires after 7 days. Use
them only when the CLI is not possible.

Sending messages, calendar invites, approvals, and deletes affect other people
or are permanent. Confirm the recipients and content first.
