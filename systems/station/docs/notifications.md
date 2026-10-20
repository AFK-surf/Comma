# Notifications

A person hears about a chat they take part in when something there wants them:
an agent finished a turn with something new to read, an agent is blocked on
them, an agent failed, or another person said something. Two ways carry it:

- **Local**, while a client runs: the client core notices it from the chat
  rows it keeps in sync (`notices` topic) and the client shows it.
- **Push**, while no client runs: the station tells the control plane, which
  pushes to the person's registered devices: Web Push (VAPID) for browsers,
  Firebase Cloud Messaging for Android. The desktop app has no push. It keeps
  running in the background on macOS and hears them locally.

A notice is never shown for the chat the person is looking at. One chat has one
notification at a time (its `tag`: a newer one replaces the older). Both ways
use the same tag, so a push and a local notice for the same chat do not pile up.

Only chats of still.fail's own page are noticed (a Slack thread has Slack's
notifications), and only for people who take part in them (the sidebar's
`mine`: they made the chat, spoke in it, or started it).

The `notices` topic and the `push.*`, `notify.*`, `client.focus` and
`notice.*` calls are in still.fail's client core, not in Comma's.

## What is noticed

| kind | when | body |
| --- | --- | --- |
| `done` | an agent's turn ended (not blocked, not failed) and it said something in the chat during the turn that the person has not read | `<agent>: <its last message>` |
| `block` | an agent's turn ended blocked (`chat_post kind:"block"` / `chat_state block`) | `需要处理 · <its last message>` |
| `failed` | something went wrong: the station says so in the chat, `⚠️` first (a turn that failed, an agent that could not start) | `出错了 · <what it says>` |
| `message` | another person said something in the chat, while no agent there is at work | `<name>: <text>` |

The title is the chat's title as the sidebar shows it. Texts are one line
(whitespace collapsed). A notification opens the chat:
`/o/<workspace>/<station>/<session>`.

## still.fail cloud

- `GET /v1/push/key` → `{ vapid }` (no auth).
- `POST /v1/push` (bearer access token) `{ kind: "web", endpoint, keys: { p256dh, auth } }` or `{ kind: "fcm", token }` → 204. One row per account and endpoint/token. A device signed in with several accounts has one for each (registered again with the same account, it moves to this session). A device that two of a notice's people are signed in with gets it once.
- `DELETE /v1/push` (bearer) `{ endpoint }` or `{ token }` → 204. Only the caller's account's row goes.
- A session signed out (`/v1/auth/logout`, revoked) takes its registrations with it.
- `POST /v1/stations/notify`, signed by the station like its traces: headers
  `x-stillfail-station`, `x-stillfail-ts`, `x-stillfail-signature` = ed25519
  over `ember-station-notify-v1:<origin>:<station>:<ts>:<sha256 of the body, hex>`.
  The station also sends the same values in `x-ember-*` headers.
  Body:

  ```jsonc
  { "notices": [{
    "to": ["a@b.c"],               // people's emails; only members of the station's workspace get it
    "kind": "done", "session": "<key>", "thread": 7,
    "title": "部署挂了", "by": "Claude", "text": "修好了", "at": 1790000000000
  }] }
  ```

  → `{ "sent": n }`. The cloud makes the body as the table above says, and
  pushes to each member's registrations. A device its push service answers
  404/410 (gone) for is dropped, with every account it was registered with.

Comma's control plane takes the same body at `/v1/comma/stations/notify`, signed
under `comma-station-notify-v1` in the `x-stillfail-*` headers only
(`src/cloud/provider.ts`).

Push payload (Web Push: the encrypted body, `aes128gcm`. FCM: a data message,
high priority, every value a string):

```jsonc
{ "type": "notice", "kind": "done", "title": "…", "body": "…",
  "tag": "ws/st/<session>", "url": "/o/ws/st/<session>",
  "workspace": "ws", "station": "st", "session": "<key>", "at": "1790000000000" }
```

Secrets: `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` (P-256, base64url raw
public point / private scalar `d`), `VAPID_SUBJECT` (a `mailto:`),
`FCM_SERVICE_ACCOUNT` (the Firebase service account's JSON). Without VAPID keys
`/v1/push/key` answers 404 and web registrations are refused. Without the
service account FCM pushes are skipped.

## Station

The station notices an agent's turn ending, and a message in one of its own
chats: a person's, or the station's own ⚠️ (`src/cloud/notify.ts`,
`src/read/notices.ts`). It posts them to the control plane in batches. A batch
that cannot be sent is dropped. A station not enrolled with a control plane
sends nothing. An older cloud answers 404, and nothing more comes of it.
