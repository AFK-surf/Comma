# Station storage and change notifications

Two rules shape this:

- **One place for every message.** Whatever is said in a conversation, by a
  person on Slack or on still.fail's page, or by an agent, is one entry in its
  thread's log. Entries are only appended. An edit is an entry of its own.
  Nothing said is taken back: still.fail has no delete. Clients read "the
  entries after n", never the whole thing again, and keep what they read.
- **No polling inside still.fail.** A station tells its clients what changed.
  still.fail cloud tells devices what changed. The client core refetches
  nothing on a timer. Station timers only sample what cannot notify (host
  load, provider quotas while someone looks) or run deadlines and backoff.

## Words

- **Session**: one agent. One runtime conversation (a Claude Code or Codex
  session) with its profile, model, workspace directory and turns.
- **Thread**: a place people talk: a Slack thread, or a chat on still.fail's page.
  A thread has any number of sessions and people taking part.
- **Message**: something said in a thread, by a person, an agent (a session),
  or still.fail itself (a notice).

## Tables (stillfail.db)

The schema is in [`src/store/schema.ts`](../src/store/schema.ts). The core tables:

| table | holds |
| --- | --- |
| `sessions` | one row per agent: runtime, profile, model, workspace, token, archive state |
| `threads` | one row per place people talk, unique by `(surface, channel, thread_ts)`. Ids are never used again, so what a client keeps of a thread stays true |
| `thread_sessions` | which sessions take part in a thread, and through which connect each posts there |
| `entries` | everything said. Per thread a log numbered `n` = 1, 2, 3 … with no gaps. `kind` is `message` or `edit` (an edit names the `target` message and gives its whole new version). A message's `ts` (Slack ts) is unique per thread |
| `merged` (view) | each message as it reads now: its latest edit's words, files and quotes |
| `deliveries` | which messages a session still has to read. Person messages go to every session in the thread |
| `reads` | how far each viewer has read each thread |
| `identities` | the Slack users each viewer said are them ("这是我"). Not verified: it is the viewer's word |
| `task_index` | one row per chat on the station's page (a Task): `json` (task, thread, title, status, created_by, created_at, last_activity_at, runtime, model, labels, rev; no message text) as of `rev`, the index's next number at each change. A deleted chat leaves a tombstone (`removed`) until it is pruned. `marked` is done or cancelled as a person set it; `labels` (a JSON array of the Group's label ids, at most 20) as a person set them (`PUT /threads/:id/labels`). Slack threads and other stations' Tasks (`task` surface) have no row |
| `meta` | the station's own values by name: the Task index's epoch (made once) and last rev |

A database of another schema version is refused, and the station says to move
its data by hand. No migrations are kept in the code. Columns added after the
schema version are added in place on open.

### Writing

- **Slack message in**: upsert its thread, append the message, add a delivery
  for each session in the thread, then ack Slack. A duplicate `(thread, ts)` is
  the same message seen twice and is ignored. When the message starts a session,
  the session and its `thread_sessions` row are made first. Several connects in
  one channel share the thread row and its messages. Whichever sees a message
  first delivers it to every session in the thread.
- **Joining mid-thread**: when still.fail starts following a Slack thread at a
  reply, what Slack has before that reply is recorded first, with no
  deliveries. The log keeps Slack's order.
- **Person on still.fail's page**: the same, with surface `ember`. The text the
  agent reads (quotes, file paths) is made at delivery, not stored.
- **Agent posts** (`chat_post`): the surface posts it and returns its ts. The
  message is recorded with `author_kind = agent`, `author = session key` and
  `declared`. Slack posts are recorded too. A message Slack takes in several
  parts is recorded once, under the first part's ts. Agents' messages are not
  delivered to other sessions. still.fail's own notices are recorded as
  `author_kind = ember`.
- **`-stop`** is recorded like any message. It stops each session it is
  delivered to instead of reaching the agent.
- **Slack edits** (`message_changed`) append an `edit`. An edit with the same
  words changes nothing. A message still pending reaches the agent as it reads
  at delivery (merged).
- **Slack deletes** (`message_deleted`) are ignored. The message stays as it was said.
- Every entry takes its thread's next n in the same transaction.

### Reading

- `GET /threads?session=…` (all threads without `session`) and
  `GET /threads/:id`: threads with their sessions, their people, `firstText`,
  `last` (the last entry's n), `lastMessage` (merged), and the viewer's read
  position and unread count. Unread counts messages after the read position
  that are not the viewer's own, nor of a Slack user the viewer is.
- `GET /threads/:id/entries?after=n` gives what came since. `?before=n&limit=`
  gives older pages (no cursor: the latest page). `?from=a&to=b` gives a gap,
  both ends included. The answer is `{ last, entries }`. Entries carry
  `authorName`.
- `PUT /threads/:id/read {n}` sets the viewer's read position. It only moves
  forward, and the answer says where it is.
- `POST /threads/:id/messages {text, attachments, quotes, client?}` posts a
  person's message in a still.fail chat (Slack threads are written in Slack).
  The answer is `{ n }`. `client` is the app it was sent from
  ("android 0.1.1123"). It is kept for the chat's agent and not shown.
  Attachments must be files uploaded with `POST /uploads` (or `/uploads/parts`)
  or files already in the upload directory of a session in the thread.
- `PUT /threads/:id/status {status}` marks a still.fail chat's Task `done` or
  `cancelled`, or (`in_progress`) removes the mark. The answer is
  `{ thread, status }`. Otherwise the status comes from the chat: `archived`
  while the chat is archived; else the mark; else `needs_review` while a card
  waits or the agent's last turn ended all_done or need_help; else
  `in_progress`. A person's next message in the chat removes the mark.
- `POST /threads {session, title?}` opens another chat on a session.
  `POST /threads/:id/sessions {session}` brings another session into a
  still.fail chat. `POST /sessions` (a new chat) makes the session and its
  chat and answers `{ key, thread }`. A given `clientKey` (the key the asking
  client shows the chat by until it is made) is kept in memory for a short time
  and shown on the chat's sidebar item, because its `chat` event can reach the
  client before the answer does.
- A session's transcript comes only from the `live` event on `/events`
  (`?live=<key>&from=<n>&last=<m>`, repeatable): entries from index n, then as
  they are written.
- `GET /chats` gives the viewer's sidebar items (see The sidebar).
  `?archived=1` gives the archived ones.
- `PUT /me/slack/:user` and `DELETE /me/slack/:user`: the viewer says a Slack
  user is them ("这是我"), or no longer ("不是我"). Nothing checks it. The
  answer is the overview, whose `slackUsers` lists the viewer's Slack users.
- `GET /sessions/:key` is the session row, its threads and its turns: no
  entries, no transcript. `GET /sessions` lists shown sessions.
  `?archived=1` lists the archived ones.

### The sidebar

A chat is still.fail's own internal chat (a thread on surface `ember`), bound to
one or more sessions, with people. A Slack thread is not a chat: its messages
show only in its agent's execution history. The sidebar has one kind of item:
an agent (a shown session) with its internal chat. A chat with several agents
is one item. An agent with no chat yet is an item without a chat. An archived
session is in no item. A chat whose sessions are all archived is not listed.
The station builds the items per viewer, because unread marks and who takes
part depend on the viewer. The full shape is `chats` in
[`src/read/views.ts`](../src/read/views.ts). The main fields:

```jsonc
{
  "id": "ds:C1:1790000000.000100",  // the item's agent's session key, chat or no chat
  "session": "ds:C1:1790000000.000100",  // its agent (a chat's first)
  "thread": 7,                    // its internal chat, or null without one
  "title": "部署挂了",
  "agents": [{ "key", "runtime", "model", "effort", "process", "pending", "lastTurn" }],
  "last": { "seq", "authorKind", "author", "authorName", "text", "createdAt" } | null,  // the chat's latest message, merged
  "unread": true,
  "mine": true,
  "lastActiveAt": 1790000000000,
  "connect": "ds" | null,         // the connect its agent came from, or null for one made on ember
  "origin": { "teamName", "channel", "channelName", "threadTs" } | null
}
```

A Slack thread gives its agent's item only the title (while the chat has no
words of its own), the connect and the origin. A person is the viewer by id
(an email, or `local`), by a Slack user's email, or as a Slack user the viewer
said is them (`identities`). This counts for `mine` and for unread.

`GET /events` sends the viewer's items as they change. When anything they are
made of changes, the station reads the items again, once per viewer for a
burst. It sends `chat` with the whole item when one is new or changed, and
`chat-removed {id}` when one is gone. A stream starts from the items at the
moment it opened.

### Housekeeping

- `POST /sessions/:key/archive` and `DELETE /sessions/:key/archive` hide and
  show a session (and archive its threads, below). The answer is the session
  summary. `POST|DELETE /threads/:id/archive` does the same for a chat, with its
  session when it is that session's own chat. Every hour the station also
  archives what has idled past `autoArchiveDays` (config.json) and is done.
  Anything new said brings it back.
- `DELETE /sessions/:key` ends its process and deletes its rows (turns,
  deliveries, thread_sessions, and threads left with no session with their
  entries or archive files and reads). It also deletes its workspace directory
  and its transcript copy. The runtime's own transcript file is left alone,
  because it is in the profile's home, which may be a person's own.
  `thread-removed` tells clients about each thread that went.

## Append-only threads

Entries are appended and never changed, so whatever a client has fetched stays
true and can be kept on the device. Changes are new entries the client merges.
Entries disappear only with their whole thread (deleting a session removes
threads left without one). `thread-removed {id}` tells clients to drop what
they keep of it.

### Archiving

When a thread goes out of every list (archived itself, or every session of it
archived), its entries go to `<data>/archive/threads/<id>.jsonl.zst` (one
entry per line, zstd), in one step with deleting their rows. The thread row is
marked archived (`archived_at`). Because entries never change, clients' kept
copies stay valid. Reading an archived thread reads the file through the same
API. A new entry (someone writing in it, an edit too) or a session of it shown
again loads it back into the database first and removes the file.

Archiving a session also writes its transcript copy,
`<data>/archive/transcripts/<session>.jsonl.zst`. The runtime's own file in the
profile's home is left as it is. Showing the session again or deleting it
removes the copy.

### In the client core

Merging happens in one place (`client/core-ts/src/entries.ts`): a message shows
its latest edit's text, attachments and quotes, marked edited (`editedAt`).
Unread and read positions are entry numbers.

The client core keeps entries on the device, through `Host` storage (IndexedDB
on the web, files natively) in chunks. `thread/<station>/<thread>/<chunk>`
holds entries `chunk*256+1 … chunk*256+256`. `thread/<station>/<thread>/meta`
holds `{ first, last }` (one run) and the thread's summary as last seen, so
the chat opens before the station's thread list is read. Opening a chat shows
its latest kept page at once, then asks for `after=last`. Scrolling up reads
kept chunks before asking the station. The `thread` event carries new entries,
always contiguous. A client whose last n is below the first one it receives
asks for the gap (`from`/`to`) once.

A session's transcript is kept the same way under
`transcript/<station>/<session>/<chunk>`. A transcript written anew and shorter
is cut there too. Storage cannot list its keys, so `kept` indexes every kept
log with its chunks' sizes and when it was last opened. Past 50 MB the least
recently opened go first. Kept data is dropped:

- for a station the account can no longer reach (a workspace no signed-in
  account lists, decided once every account's `/v1/me` has answered, or a
  station its workspace no longer lists),
- on sign-out (what no remaining account reaches),
- with `thread-removed`,
- with `session-removed` (its transcript).

## Notifications

### Station → clients: `GET /events`

One event stream per client. Each event names what changed and carries it
when it is small. The main events:

| event | data |
| --- | --- |
| `session` | the session summary (row, state warm/cold/running, last turn, creator, participants) |
| `session-removed` | `{ key }` |
| `thread` | `{ id, entries: [appended entries, contiguous] }` |
| `thread-removed` | `{ id }`: it went with every entry (a deleted session took it along) |
| `read` | `{ viewer, thread, n }` (only to that viewer) |
| `chat` | an item of the viewer's sidebar, new or changed (only to that viewer) |
| `chat-removed` | `{ id }`: an item gone from the viewer's sidebar |
| `overview` | the whole overview, with the viewer and their Slack users (`slackUsers`), when any of it changes |
| `host` | host info, sampled **only while some client asks for it** (`/events?host=1`) and sent when it changed |
| `live` | a watched session's transcript entries (`?live=<key>`) |

Changes within one turn of the event loop are gathered: one `session` event
per session, one `overview`, one round of sidebar items.

### still.fail cloud → devices: `GET /v1/events` (WebSocket)

A device keeps one WebSocket per account to the directory.

- **Auth**: the access token travels as a subprotocol:
  `new WebSocket(url, ["ember-events", "ember-token." + accessToken])`. The
  answer selects `ember-events`. Query strings are not accepted. The token is
  checked at connect only. Events carry nothing a device may not see, and the
  device refetches with a fresh token. A refused socket gets 401 before the
  upgrade. A device reconnects with a fresh token.
- **Keepalive**: the device may send the text `ping`. The runtime answers
  `pong` without waking the directory.
- **Events** (JSON text frames), each to exactly the accounts it concerns:

| event | when | to |
| --- | --- | --- |
| `{"type":"workspaces"}` | the account's workspace list or its invitations changed (a workspace created, renamed, deleted, joined or left, a role, member or station counts, or an invitation to it arrived, went or had its inviter renamed) | that account |
| `{"type":"workspace","id"}` | the workspace view changed: members, roles, stations, names, invitations (the managers' list) | its members, and a member who just left or was removed |

A device refetches `/v1/me` on `workspaces` and `/v1/workspaces/:id` on
`workspace`. Nothing is replayed: after a reconnect the device refetches what
it shows.

### Station control channel: `GET /v1/stations/connect` (WebSocket)

The station keeps a WebSocket open to still.fail cloud (`src/cloud/presence.ts`).
The cloud tells it its name and workspace, the keys member credentials are
signed with, revocations, and its removal. The open socket is the station's
presence at the cloud. A station works without this socket (devices keep
their credentials). `last_seen` is when it last connected or disconnected.

- **Auth**: signed with the station's key at connect, in headers. For each
  prefix (`stillfail`, then `ember`): `x-<prefix>-station` (its key, hex),
  `x-<prefix>-ts` (unix seconds, within 5 minutes), `x-<prefix>-signature`
  (hex Ed25519 over `<prefix>-station-connect-v1:<origin>:<station>:<ts>`) and
  `x-<prefix>-version`. A station that is not enrolled gets 404. It takes that
  as removed and asks again every 10 minutes, or at once when it is enrolled
  anew. Comma's control plane is in [cloud.md](cloud.md).
- **From the cloud**: `{"type":"state","workspace","workspace_name","name","grant_keys","revocations"}`
  on connect and whenever these change (renamed, moved by re-enrolling), with
  the last 31 days' revocations (`{kind: "sub"|"sid", id, at}`: credentials of
  that account or login session issued at or before `at` are refused), and
  `{"type":"revoke", …}` as one happens.
  Close codes: 4000 replaced by a newer socket of the same station, 4004
  removed from its workspace, 4008 silent.
- **Liveness**: the station sends `ping` every 30 s and the runtime answers
  `pong` without waking the directory. A station that gets no `pong` before
  its next ping reconnects. While any station is connected, an alarm every
  90 s drops station sockets unanswered for 90 s.
- The station reconnects with backoff (1 s doubling to a minute, back to 1 s
  after a socket held a minute). A reconnect replaces the old socket without
  an offline in between.

### The client core

The client core holds one `/events` stream per station in use and one
`/v1/events` socket per account. Topics change only when these say so. A
write's answer updates the topic it returns (for example, a profile edit
returns the overview). A call returns only after the topics it touches are
current, so a page that navigates right after a write finds what it wrote.
