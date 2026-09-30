---
name: website-manager
description: Create, publish, inspect, modify, or roll back websites, webpages, HTML pages, web demos, and multi-file sites in the agent VFS. Also use for `/.salix/websites`, `_api.json`, `/_api/` endpoints, or when telling the user about a published website.
metadata:
  displayName: Website Manager
---

# Websites

Manage public sites from `/.salix/websites/{site-name}/`.

Each subdirectory under `/.salix/websites/` is a separate website:

- `/.salix/websites/docs/index.html` -> site `docs`
- `/.salix/websites/app/index.html` -> site `app`
- `/.salix/websites/app/css/style.css` -> asset for `app`

Site names must be lowercase alphanumeric with hyphens. No leading or trailing hyphens.

The canonical `site_name` is the website identity. Reusing the exact canonical
name returned by the first publish updates that website at the same URL. A
different canonical name creates a different website. If several existing
sites could match a modification request, ask which one rather than guessing.

If `agent_website_url_template` is present, the platform can publish the site publicly. If it is not present, you can still prepare the files in the VFS, but do not claim the site is reachable from the internet.

## Static Site Rules

- Put the site entry point at `/.salix/websites/{site-name}/index.html`.
- Keep all static assets under the same site directory.
- Publish every new or changed site through `preview.publish_html`. Do not
  directly overwrite the current public files before an update publish: the
  publisher snapshots those files before replacing them.
- A same-name update automatically snapshots the current public files under
  `/.salix/websites/{site-name}/_versions/vNNNN/` in the same atomic workspace
  operation. It retains the newest 20 versions.
- `html` and `source_path` replace only `index.html` and preserve other public
  assets. `source_root` mirrors a complete multi-file site and removes public
  files that are absent from the source tree.
- Removing a site means deleting `/.salix/websites/{site-name}/` recursively.
- Directory requests resolve to `index.html`.
- Paths starting with `/_` are reserved and are never served as static files.
- Never put public assets under `/_*`.

## Site APIs

Site APIs are disabled by default. Enable them by writing:

- `/.salix/websites/{site-name}/_api.json`

`_api.json` is not publicly served. It controls two backend capabilities exposed from the website origin:

- `POST /_api/llm/chat`
- `GET|PUT|DELETE /_api/documents/{key}`
- `GET /_api/documents?prefix=...&after=...&limit=...`

Use relative paths like `fetch("/_api/documents/public/homepage")` from site JavaScript.

## Validation

Always use the bundled validator instead of ad hoc `_api.json` checks.

Validator script:

- `scripts/validate_website.c`

Execution pattern:

1. Call `script.run_file` with the validator path.
2. Pass `API_JSON_PATH` in `env`; the validator reads that VFS file through `salix.call` with `fs.read_file`. The file must be under 16 KiB; a larger file is reported as an error.
3. Pass `SITE_NAME` and `WEBSITE_ROOT` too.
4. If `_api.json` is required for the task, set `REQUIRE_API_JSON` to `"true"`.
5. Do not pass `_api.json` contents through `env`.

The script returns a JSON object with:

- `ok`
- `errors`
- `warnings`
- `checks.api_json`

Use `errors` as hard validation failures. Treat `warnings` as follow-up items or security review notes.

Example tool call:

```json
{
  "path": "scripts/validate_website.c",
  "env": [
    { "name": "SITE_NAME", "value": "docs" },
    { "name": "WEBSITE_ROOT", "value": "/.salix/websites/docs" },
    { "name": "API_JSON_PATH", "value": "/.salix/websites/docs/_api.json" },
    { "name": "REQUIRE_API_JSON", "value": "true" }
  ]
}
```

## `_api.json` Shape

Use JSON like this:

```json
{
  "auth": {
    "bearer_tokens": ["secret-token-1"]
  },
  "storage": {
    "default_policy": "deny",
    "rules": [
      {
        "key_prefix": "public/",
        "operations": ["read", "list"],
        "require_auth": false
      },
      {
        "key_prefix": "",
        "operations": ["read", "write", "delete", "list"],
        "require_auth": true,
        "max_value_size": 1048576
      }
    ]
  },
  "llm": {
    "enabled": true,
    "require_auth": true,
    "rate_limit_rpm": 60,
    "max_tokens": 1024
  }
}
```

Important behavior:

- `auth.bearer_tokens` are accepted via `Authorization: Bearer <token>`.
- Storage rules are evaluated in order. First matching `key_prefix` wins.
- For document list requests, the `prefix` query parameter is what storage rules match against.
- If no storage rule matches, `storage.default_policy` applies. Default to `"deny"` unless the user clearly wants public write access.
- `llm.enabled` must be `true` to expose the LLM proxy.
- The site LLM endpoint always uses the agent's configured template model. Clients cannot choose the model.
- `llm.max_tokens` caps request output tokens. `0` means use the template default.
- LLM rate limiting is per agent, per node.

## Document Storage Rules

- Document values are JSON.
- Keys must start with an alphanumeric character.
- Keys may only contain `[a-zA-Z0-9._/-]`.
- Maximum key length is 256 characters.
- The default maximum document value size is 1 MB unless the matching rule sets `max_value_size`.
- Each site gets its own persistent document namespace.
- Agents can create at most 10 site document namespaces total.

## LLM Proxy Rules

Request body fields:

- `messages` required
- `max_tokens` optional
- `stream` optional

Keep LLM proxy request bodies minimal. Do not include `temperature` or `top_p`
unless the user explicitly asks for sampling controls. Some template models
reject explicit sampling parameters; omitting them lets the provider use its
model defaults.

When `stream` is `true`, the endpoint returns SSE in OpenAI-style `data: ...` chunks and finishes with `[DONE]` on successful completion.

## Workflow

1. Use the Router's routing and follow-up rules: website creation/modification
   requires a Task, even for a small page. Updates retain the original publishing Agent and
   canonical site identity, including when a replacement Task is unavoidable;
   a new Task does not make another Agent the owner of the existing site.
2. For a simple new one-file page, inline `html` is allowed. For a complex or
   multi-file site, prepare `index.html` and assets under
   `/.salix/websites/{site-name}/_work/` and publish that directory with
   `source_root`.
3. Before modifying an existing website, inspect and read its current files
   under `/.salix/websites/{site-name}/`. Prepare the changed file or tree under
   that site's reserved `/_work/` directory without changing the current public
   files.
4. If the site needs backend behavior, include `_api.json` in the prepared site
   tree. Put browser-callable data behind document rules and private behavior
   behind bearer-token-protected rules.
5. Run `scripts/validate_website.c` against the prepared tree, then call
   `preview.publish_html` once. For an update, pass the exact canonical
   `site_name` returned by the original publish. The tool creates the pre-update version snapshot.
6. Use relative `/_api/...` URLs in the site code so the frontend stays on the
   same origin.
7. Return only the canonical URL from the successful publish result. When
   describing the site, mention static pages and site APIs separately.

## Rollback

Historical versions are ordinary VFS files under
`/.salix/websites/{site-name}/_versions/vNNNN/`. Do not edit a historical
version in place. To roll back, call `preview.publish_html` with that version
directory as `source_root` and the same canonical `site_name`. The publisher
first snapshots the current public version, then publishes the selected tree as
the new current version at the same URL.

## Safe Defaults

- Expose read-only public document prefixes such as `public/`.
- Require bearer auth for writes, deletes, and LLM calls.
- Anyone can read the HTML, JavaScript, and other files that a site serves. Never put a bearer token in them. Browser code can send a token only when the person who uses the page supplies it, for example in an admin form. A system that you or the user control can keep the token as a secret and call the site API directly.
- Keep `default_policy` as `"deny"`.
- Do not store secrets in public document keys.
- Do not claim `_api.json` or `/_api/*` are visible as static files.
- Expect site API errors to come back as HTML pages, not JSON.

## Common Calls

```js
await fetch("/_api/documents/public/homepage");
```

```js
// adminToken comes from the person who uses the page, for example an admin form.
// Never write a token into a site file.
await fetch("/_api/documents/private/profile", {
  method: "PUT",
  headers: {
    "Content-Type": "application/json",
    Authorization: `Bearer ${adminToken}`,
  },
  body: JSON.stringify({ value: { name: "Ada" } }),
});
```

```js
await fetch("/_api/llm/chat", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    Authorization: `Bearer ${adminToken}`,
  },
  body: JSON.stringify({
    messages: [{ role: "user", content: "Summarize this page." }],
    max_tokens: 512,
  }),
});
```
