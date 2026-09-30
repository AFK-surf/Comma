---
name: google
description: Work with Google services through Salix-managed Google OAuth and the Google Workspace CLI (`gws`), including Gmail, Drive, Calendar, Sheets, Docs, and other Google Workspace APIs.
---

# Google

Use this skill whenever the task involves Google Workspace / Google APIs and the `gws` CLI is available or should be made available. Prefer Salix-managed OAuth token injection, and prefer direct Google REST API calls when they are simpler or more reliable than the dynamic `gws` command surface.

Tool names below are canonical call targets. In the internal LLM runtime, invoke them with `call(tool="<name>", params={...})`.

Retain the selected `device_id` and its `environment_id`. Pass `device_id` and
`environment` (the environment ID) to every `env.exec` call. Reuse known targets
without repeating discovery.

## Typical Goals

- List, read, search, summarize, label, archive, or draft Gmail messages when scopes allow.
- List, inspect, upload, download, move, or share Google Drive files when scopes allow.
- Read or update Google Sheets, Docs, and Calendar resources when scopes allow.
- Discover and call Google Workspace API methods through `gws`.
- Install or verify the Google Workspace CLI on a persistent environment.
- Authenticate Google access using the Salix-managed OAuth flow.

## Operating Principles

- Use managed OAuth (`oauth.request_authorization` / `oauth.complete_authorization`) for Google credentials.
- Inject OAuth credentials only into the subprocess that needs them via `env.exec` with `credential_env`.
- Use read-only scopes unless the user explicitly asks for a write operation.
- Confirm destructive or hard-to-reverse actions before executing them, including deleting Drive files, sending emails, modifying large Sheets ranges, or changing Calendar events.
- If a `gws` command fails with `accessNotConfigured` or `API not enabled`, treat it as a Google Cloud project API-enable issue unless token verification also fails.
- Do not claim a Google object was changed until the API or CLI command succeeds.

## Managed OAuth

Before asking the user to authorize Google, check for an existing Google OAuth credential:

1. Call `oauth.list_credentials`.
2. Look for an active credential with:
   - `provider`: `google`
   - alias: usually `google-workspace` unless another suitable alias was returned
3. If no usable Google credential exists, call `oauth.request_authorization` with `provider: "google"`, a stable alias such as `"google-workspace"`, and scopes matching the task.
4. Share the returned `authorization_url` with the user and wait for them to confirm completion.
5. Call `oauth.complete_authorization` with the returned `state`.
6. Use the completed credential with `env.exec` using `credential_env`.

Managed OAuth injects the access token into subprocesses.

### Common scopes

Prefer the narrowest scopes that can complete the task.

Read-only scopes:

```text
https://www.googleapis.com/auth/gmail.readonly
https://www.googleapis.com/auth/drive.readonly
https://www.googleapis.com/auth/calendar.readonly
https://www.googleapis.com/auth/spreadsheets.readonly
https://www.googleapis.com/auth/documents.readonly
```

Write scopes, only when needed:

```text
https://www.googleapis.com/auth/gmail.modify
https://www.googleapis.com/auth/gmail.send
https://www.googleapis.com/auth/drive.file
https://www.googleapis.com/auth/drive
https://www.googleapis.com/auth/calendar
https://www.googleapis.com/auth/spreadsheets
https://www.googleapis.com/auth/documents
```

### If oauth.\* tools are unavailable (Composio tenants)

Some tenants use Composio instead of per-provider OAuth apps, and the tool
catalog only ever shows the configured path. If the `oauth.*` tools are not in
the current tool catalog but `composio.*` tools are, do not try this skill's
managed-OAuth or `env.exec` `credential_env` flow for Google. Instead:

1. Check `composio.list_connections` for an ACTIVE `gmail` connection.
2. If none, connect with `composio.request_connection` (toolkit `gmail`),
   post the returned Connect Link to the requester, and verify with
   `composio.check_connection`.
3. Run Google operations directly with `composio.execute`
   (e.g. `GMAIL_FETCH_EMAILS`); discover tool slugs and schemas with
   `composio.list_tools` / `composio.get_tool`.

See the `composio` skill for the full flow and how to choose between the two
paths when both are available.

## Credential Injection

For `gws`, inject the token directly as `GOOGLE_WORKSPACE_CLI_TOKEN`:

```json
[
  {
    "env_var": "GOOGLE_WORKSPACE_CLI_TOKEN",
    "provider": "google",
    "alias": "google-workspace",
    "value": "access_token"
  }
]
```

For direct REST API scripts, inject it as `GOOGLE_ACCESS_TOKEN`:

```json
[
  {
    "env_var": "GOOGLE_ACCESS_TOKEN",
    "provider": "google",
    "alias": "google-workspace",
    "value": "access_token"
  }
]
```

If a script needs both, inject both environment variables in the same `env.exec` call using the same provider/alias.

## Initial Checks

Use `device.list` followed by `device.get` before choosing where to run commands. Prefer a persistent VM such as `cloud-vm` when available.

Check `gws`:

```bash
export PATH="/home/sprite/.local/bin:$PATH"
gws --version
gws auth status
```

Expected successful token-in-env authentication includes:

```json
{
  "credential_source": "token_env_var",
  "token_env_var": true
}
```

Verify the Google OAuth token without printing it:

```bash
python3 - <<'PY'
import json, os, urllib.request
TOKEN = os.environ.get('GOOGLE_ACCESS_TOKEN') or os.environ['GOOGLE_WORKSPACE_CLI_TOKEN']
req = urllib.request.Request(
    'https://www.googleapis.com/oauth2/v2/userinfo',
    headers={'Authorization': 'Bearer ' + TOKEN},
)
with urllib.request.urlopen(req, timeout=20) as r:
    data = json.load(r)
print('google_user_email=' + data.get('email', ''))
PY
```

## Installing `gws` On `cloud-vm`

The intended npm package is `@googleworkspace/cli`, not the unrelated package named `gws`.

Install with a clean npm cache if needed:

```bash
set -e
command -v node && node -v
command -v npm && npm -v
npm cache clean --force || true
rm -rf /tmp/npm-cache-gws
npm install -g @googleworkspace/cli --cache /tmp/npm-cache-gws
```

Put `gws` on the persistent user PATH:

```bash
set -e
mkdir -p /home/sprite/.local/bin
NPM_PREFIX="$(npm prefix -g)"
NPM_BIN="$NPM_PREFIX/bin"
if [ -e "$NPM_BIN/gws" ]; then
  ln -sf "$NPM_BIN/gws" /home/sprite/.local/bin/gws
else
  echo "gws is not in $NPM_BIN; check the install output and npm ls -g @googleworkspace/cli" >&2
  exit 1
fi
export PATH="/home/sprite/.local/bin:$PATH"
command -v gws
gws --version
```

Avoid deriving the binary directory as `$(dirname "$(npm root -g)")/bin`; on `cloud-vm`, `npm root -g` may be `.../lib/node_modules`, so that derivation points to `.../lib/bin` instead of `.../bin`.

## Using `gws`

`gws` builds its command surface dynamically from Google's Discovery Service, so inspect help/schema before assuming exact arguments:

```bash
gws --help
gws drive --help
gws gmail --help
gws schema drive.files.list
```

Run `gws` with token injection:

```bash
export PATH="/home/sprite/.local/bin:$PATH"
gws auth status
gws drive files list --params '{"pageSize": 5}'
```

If a specific `gws` command is awkward, unavailable, or failing for command-syntax reasons, call the Google REST API directly with `GOOGLE_ACCESS_TOKEN`.

## Gmail REST Examples

For Gmail listing and message inspection, direct REST calls are often simpler than `gws`.

### Gmail thread-reading rule

For any Gmail task that reads, summarizes, triages, labels based on context, or drafts a reply, inspect the complete Gmail thread before deciding. Search or list messages first, take each result's `threadId`, then call Gmail `users.threads.get` (`GET /gmail/v1/users/me/threads/{threadId}`) for the full Gmail thread. Use `format=full` when message bodies, attachments, or inline content may matter; `format=metadata` with selected headers is acceptable only for lightweight triage.

Sort all messages in the thread by `internalDate` before interpreting the conversation. Capture stable headers for each message: From, To, Cc, Subject, Date. Direct `users.messages.get` / `messages/{id}` single-message reads are fallback only when `threadId` is unavailable, permissions fail, or `threads.get` fails. Do not silently present single-message context as complete thread context; say that full-thread context was unavailable.

List recent INBOX conversations and read complete thread metadata for lightweight triage:

```bash
python3 - <<'PY'
import json, os, urllib.parse, urllib.request
TOKEN = os.environ['GOOGLE_ACCESS_TOKEN']


def api(path, params=None):
    url = 'https://gmail.googleapis.com/gmail/v1/users/me/' + path
    if params:
        # doseq=True is required for repeated metadataHeaders parameters.
        url += '?' + urllib.parse.urlencode(params, doseq=True)
    req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + TOKEN})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def header_map(msg):
    return {h['name'].lower(): h['value'] for h in msg.get('payload', {}).get('headers', [])}


lst = api('messages', {'maxResults': 10, 'labelIds': 'INBOX'})
seen_thread_ids = []
for msg in lst.get('messages', []):
    thread_id = msg.get('threadId')
    if thread_id and thread_id not in seen_thread_ids:
        seen_thread_ids.append(thread_id)

for thread_id in seen_thread_ids:
    # Use format=full instead when message bodies or attachment metadata may matter.
    thread = api('threads/' + thread_id, {
        'format': 'metadata',
        'metadataHeaders': ['From', 'To', 'Cc', 'Subject', 'Date'],
    })
    messages = sorted(thread.get('messages', []), key=lambda m: int(m.get('internalDate', '0')))
    print('THREAD', thread_id, 'messages=', len(messages))
    for msg in messages:
        headers = header_map(msg)
        print('Message:', msg.get('id', ''))
        print('From:', headers.get('from', ''))
        print('To:', headers.get('to', ''))
        print('Cc:', headers.get('cc', ''))
        print('Subject:', headers.get('subject', ''))
        print('Date:', headers.get('date', ''))
        print('Snippet:', msg.get('snippet', ''))
        print()
PY
```

Search Gmail and then read full threads for each hit:

```bash
python3 - <<'PY'
import json, os, urllib.parse, urllib.request
TOKEN = os.environ['GOOGLE_ACCESS_TOKEN']
query = 'from:example@example.com newer_than:30d'


def api(path, params=None):
    url = 'https://gmail.googleapis.com/gmail/v1/users/me/' + path
    if params:
        url += '?' + urllib.parse.urlencode(params, doseq=True)
    req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + TOKEN})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


results = api('messages', {'q': query, 'maxResults': 10}).get('messages', [])
thread_ids = []
for hit in results:
    thread_id = hit.get('threadId')
    if thread_id and thread_id not in thread_ids:
        thread_ids.append(thread_id)

for thread_id in thread_ids:
    thread = api('threads/' + thread_id, {'format': 'metadata', 'metadataHeaders': ['From', 'To', 'Cc', 'Subject', 'Date']})
    messages = sorted(thread.get('messages', []), key=lambda m: int(m.get('internalDate', '0')))
    print(json.dumps({'threadId': thread_id, 'messageCount': len(messages), 'messages': messages}, indent=2))
PY
```

## Drive REST Examples

List recent Drive files:

```bash
python3 - <<'PY'
import json, os, urllib.parse, urllib.request
TOKEN = os.environ['GOOGLE_ACCESS_TOKEN']
params = {
    'pageSize': 10,
    'fields': 'files(id,name,mimeType,modifiedTime,webViewLink)',
    'orderBy': 'modifiedTime desc',
}
url = 'https://www.googleapis.com/drive/v3/files?' + urllib.parse.urlencode(params)
req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + TOKEN})
with urllib.request.urlopen(req, timeout=30) as r:
    print(json.dumps(json.load(r), indent=2))
PY
```

## Sheets REST Examples

Read a range from a spreadsheet:

```bash
python3 - <<'PY'
import json, os, urllib.parse, urllib.request
TOKEN = os.environ['GOOGLE_ACCESS_TOKEN']
SPREADSHEET_ID = 'replace-with-spreadsheet-id'
RANGE = 'Sheet1!A1:D20'
url = f'https://sheets.googleapis.com/v4/spreadsheets/{SPREADSHEET_ID}/values/{urllib.parse.quote(RANGE, safe="")}'
req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + TOKEN})
with urllib.request.urlopen(req, timeout=30) as r:
    print(json.dumps(json.load(r), indent=2))
PY
```

## Calendar REST Examples

List upcoming Calendar events:

```bash
python3 - <<'PY'
import datetime, json, os, urllib.parse, urllib.request
TOKEN = os.environ['GOOGLE_ACCESS_TOKEN']
time_min = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + 'Z'
params = {
    'timeMin': time_min,
    'maxResults': 10,
    'singleEvents': 'true',
    'orderBy': 'startTime',
}
url = 'https://www.googleapis.com/calendar/v3/calendars/primary/events?' + urllib.parse.urlencode(params)
req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + TOKEN})
with urllib.request.urlopen(req, timeout=30) as r:
    print(json.dumps(json.load(r), indent=2))
PY
```

## Troubleshooting

- If API calls return `403 accessNotConfigured` or a message like "API has not been used in project ... before or it is disabled", the token may still be valid. Enable the relevant API in the Google Cloud project tied to the OAuth client, then retry.
- If Gmail metadata headers are empty, make sure repeated `metadataHeaders` parameters are encoded with `doseq=True`.
- If OAuth scopes are insufficient, request a new managed OAuth authorization with the missing scopes. Use read-only variants when possible.
