# Comma for Raycast

Ask Comma, find your Tasks, and open Comma from Raycast.

## Commands

| Command          | What it does                                                                                             |
| ---------------- | -------------------------------------------------------------------------------------------------------- |
| Ask Comma        | Sends your words to Comma's Home chat. Comma decides whether to answer or to start a Task.               |
| Search Tasks     | Lists your Tasks one page at a time. Type to search titles and messages. Return opens the Task in Comma. |
| Comma Menu Bar   | Shows your active Tasks in the menu bar (macOS only). It reads one page every 5 minutes.                 |
| Switch Workspace | Selects the Workspace that the other commands use.                                                       |
| Connect Comma    | Connects the extension to your Comma account.                                                            |

Search Tasks, Switch Workspace, and the menu bar also have the actions **Open Comma** and **Disconnect Comma**.
Disconnect Comma signs the extension out. The Comma app stays signed in.

## Connect

You need the Comma desktop app, signed in.

1. Run **Connect Comma** in Raycast.
2. Select **Connect** in the dialog that Comma shows. The dialog names your account.
3. Confirm the command that Raycast asks to run.

The extension gets its own Comma session. The session ends after 30 days, when you select **Disconnect Comma**, or when
the desktop app signs out. Run **Connect Comma** again after that.

Before you connect, Ask Comma asks whether to connect. If you select **Connect Comma**, it copies your words and
starts the connection. After you connect, Ask Comma sends your words itself. If the session has ended, it opens
Comma with your words in the composer.

## How it works

The extension opens these links. The desktop app owns them
(`clients/apps/electron/src/main/launcher-link.ts`). A link never sends a message.

| Link                                              | Result                                                        |
| ------------------------------------------------- | ------------------------------------------------------------- |
| `comma://home`                                    | Shows the window.                                             |
| `comma://home/compose?text=…&entry=raycast`       | Puts the text in Home's draft. The limit is 8,000 characters. |
| `comma://task/<workspace>/<group>/<conversation>` | Opens the Task.                                               |
| `comma://connect/raycast?challenge=…`             | Asks you to connect the extension.                            |

To connect, the extension keeps a random verifier and sends only its SHA-256 as the challenge. After you confirm,
Comma opens `raycast://extensions/afk-inc/comma/connect` with a one-time pairing. The server issues a session only
for the verifier that matches the challenge. The extension ignores a pairing link that it did not ask for.

A message that you write in Raycast shows the Raycast mark in Comma. The extension's own session marks it
(`client_kind: raycast`). A message from a draft that a link filled carries `client_entry: raycast`.

## Develop

This directory is its own npm project. It is not part of the pnpm workspace, because `@raycast/api` pins a React
version that the workspace must not take.

```sh
npm install
npm run dev
```

`npm run build` checks the commands. CI runs the same check in the **Raycast Extension Build** job
(`npx ray build -e dist`). The logic in `src/lib` has no Raycast import. The repository's type check and unit
tests cover it:

```sh
pnpm --dir clients exec vitest run apps/raycast/src/lib/test
```

Select the Comma app and server with the **Comma Environment** preference. Remove that preference from a build for
the public Store.

The link owner and name in `clients/apps/electron/src/main/raycast-connect.ts` (`RAYCAST_EXTENSION`) must equal
`owner` and `name` in `package.json`.
