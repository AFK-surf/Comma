---
name: feishu
description: "飞书 Feishu: groups, members, cloud documents, wiki pages, Base and spreadsheet reads, and Minutes through the Feishu connect; writes to sheets and Base, calendar, tasks, approvals, and mail through the official Lark CLI."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Groups through the Feishu connect

Use `im_api.feishu.create_chat` to create a private group and
`im_api.feishu.add_chat_members` to add people to a group.
Use `im_api.feishu.search_chats` to find groups, and `im_api.feishu.join_chat` to join
a public group a person asked for. A private group needs a member to add the bot.
Read their parameters with `im.provider_apis_list`.
Resolve each person to an open_id with `feishu.list_chat_members` or `feishu.get_user`.
Do not use display names as IDs.
The app needs published `im:chat:create` and `im:chat.members:write_only` permissions.
Each invited person must be in the app's availability range.
After creation, check `feishu.list_chat_members` before reporting that everyone joined.
An unknown result does not prove that creation failed. Do not create a duplicate group.

## Message formatting

Pass ordinary Markdown in `feishu.send_message.text`. Omit `format`, or use
`format: "markdown"`. Use `format: "text"` only for literal text.
Separate paragraphs with a blank line. Use bold labels, short lists, links,
and fenced code blocks when they help the reader.
Pass real mentions through `mentions: [{user_id, name}]`, using verified open_ids.
An `@name` string does not notify anyone. Do not embed raw `<at>` or `<font>` tags.
To give a message or a file to another chat or person, use
`feishu.forward_message`.

## Cloud documents and Minutes through the Feishu connect

When `im.connects_list` shows a Feishu connect, use its document operations
first: `im_api.feishu.fetch_doc`, `update_doc`, `create_doc`, and the other
`*doc*` operations listed by `im.provider_apis_list`. The bot opens only
documents shared with a chat it is in, shared with the app, or open by link
inside the company.

Read a document, spreadsheet or Base in this order:

1. Read it as the app (no `account`).
2. If the app is denied, read it again with `account` set to the signed-in
   account of the person who asked (`feishu.list_accounts`). Never use the
   account of another person.
3. If that person has no signed-in account, or it is expired or needs
   authorization again, call `oauth.request_authorization` with provider
   `feishu`, send its `authorization_url` in the chat the request came from,
   and read with their account when it completes. The default sign-in reads
   documents only. For a spreadsheet or Base, pass `scopes`
   `["sheets:spreadsheet:readonly", "bitable:app:readonly"]`, also when
   their account exists but lacks them. Such a sign-in keeps the default
   scopes.
4. If their account is denied too, offer to ask the owner for access as them
   with `feishu.request_doc_access`. Call it only after they agree.

The person may prefer to share the document with the chat. That is their
choice, not your first answer. A missing app scope (error 99991672) is not a
sharing problem: a tenant admin must enable the scope in the Feishu developer
console and publish a new app version. If a sign-in lacks a scope (error
99991679), call `oauth.request_authorization` again with that scope in
`scopes`. If the authorization page refuses it (error 20027), a tenant admin
must enable it as a user scope first.

Write in the same order. If the app may not edit the document, ask the
person who asked if you may write as them, because the edit history shows
them as the author. Only after they agree, pass their `account` to
`update_doc`, `insert_doc_media` or the comment operations. If they have no
account, or their sign-in lacks the write scopes, call
`oauth.request_authorization` with `scopes` `["docx:document",
"docx:document:write_only", "docs:document.comment:create",
"docs:document.comment:write_only", "docs:document.media:upload"]`. If their
account may not edit either, offer `feishu.request_doc_access` with `perm`
`edit`.
`create_doc`, sharing, link settings and `delete_doc` run as the app only.

Minutes recordings work the same way through `get_minute`, `list_minutes`,
and `fetch_minute_media`. Use the CLI below only for work these operations
do not do, such as editing Minutes or writing to a Base or spreadsheet, or a
document type these operations do not support.

## Base and spreadsheets through the Feishu connect

A `/base/` link (多维表格) or a `/sheets/` link is read in the same order
as a document, and every table read takes `account`. Do not ask a person to
export it to Excel or CSV. Read a Base with `im_api.feishu.get_base` (its tables),
`feishu.list_base_fields` (the columns and views of one table) and
`feishu.list_base_records` (one page of rows at a time, until `has_more` is
false). Pass the link as `base`: its `?table=` and `?view=` are the defaults,
and the view keeps the person's filter. Read a spreadsheet with
`feishu.get_sheet` (its sheets and row counts) and `feishu.get_sheet_range`
(at most 500 rows per call; follow `next_range` until `has_more` is false).
A wiki page that holds a Base or spreadsheet reads the same way. A Base
with advanced permissions (`is_advanced`) stays private to you, because
each collaborator sees its own rows. These operations are read-only. Writes
to a Base or spreadsheet need the CLI below with the person's own identity.

## In a sandbox

A sandbox's disk can be lost whenever it stops, and a login kept on it is lost
with it. Do not run `lark-cli auth login` or `lark-cli config init` there.
Connect the person's account once and let Comma keep it:

1. Check `oauth.list_credentials` for a `feishu` entry with `usable: true`.
2. If there is none, call `oauth.request_authorization` with provider `feishu`,
   an alias such as `feishu-<their name>`, and a reason. In Comma, also from a
   sandbox, a card asks the person; the call returns when they answer. Do not
   ask them for a secret in the chat. For a customer's own app, pass
   `own_app: true`: the card asks a Workspace owner for its App ID and App
   Secret first. For work the default scopes do not cover, such as sending as
   the person, pass `scopes` (`im:message.send_as_user`). The app must offer
   each one as a user scope, have the redirect URL the card shows, and have
   "Refresh user_access_token" on.
3. Install the CLI if it is missing, then run each command with a fresh token:

   ```sh
   comma exec \
     --credential feishu/<alias>=LARKSUITE_CLI_USER_ACCESS_TOKEN \
     --credential feishu/<alias>:client_id=LARKSUITE_CLI_APP_ID \
     --env LARKSUITE_CLI_BRAND=feishu \
     -- lark-cli <domain> <command> --as user
   ```

The credential belongs to the person who connected it: only work done for them
can use it. Comma renews it, so it survives a lost disk. Use the Feishu connect for
bot actions.

Feishu recommends its official CLI `@larksuite/cli` (github.com/larksuite/cli)
for agents. On the user's own Mac it stores tokens in the OS keychain: run it
there with `env.exec`.

## Setup

1. `npm i -g @larksuite/cli` (or `npx @larksuite/cli@latest install`).
2. On the user's own Mac, `lark-cli config init --app-id <id> --app-secret-stdin`
   sets up a custom app. Never send a person to a terminal in a sandbox.
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
