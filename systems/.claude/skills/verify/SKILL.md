---
name: verify
description: Verify requested Comma/BridgeForTeams behavior against a local development stack. Use for running-app validation, not customer onboarding or shared-environment authentication.
---

# Verify changes against the running dev stack

## Launch

Resolve the current stack and port overrides before you start or restart it.
Use `docs/development.md` from the repository root for current setup.
Do not reset databases to make a validation pass. Do not restart a process
owned by another task without coordinating with its owner.

For the native local stack only, from `systems/`:

```bash
elixir --sname comma --cookie comma-dev-cookie -S mix run --no-halt   # run in background
```

Check the selected endpoint until it is ready or the startup budget expires. Use
two minutes when the stack has no documented budget, then report the startup error.
Default ports: **4101 = BridgeForTeams dashboard**, 4000 = Salix/Comma web
(`/dash/login`), plus 4200 and 4400. The server runs the code compiled at boot.
**Restart it after you edit code.**

## Auth handles

These development shortcuts apply only to an explicitly selected local fixture.
Use normal product authentication for onboarding and shared environments.
Do not treat fixture setup or direct erpc calls as proof of product authorization.

- **Dashboard session (browser or curl):** `GET http://localhost:4101/dev/login?email=<user>&to=/`
  sets a real session and redirects. It needs `bridge_for_teams.dashboard.dev_login: true`
  in the gitignored effective `config.json`, which `config/runtime.exs` reads at boot.
  It works with `curl -c cookies.txt` and with headless chromium
  (`chromium-browser --headless --screenshot=... --virtual-time-budget=20000 "<dev-login-url>"`).
- **CLI bearer token (for `/v1` `:cli_api` routes):** run the device flow over erpc
  against the live node. Call `BridgeForTeams.CLI.Login.start_device_authorization(%{})`,
  then `approve_device_authorization(dev.authorization.user_code, user, [org_id])`
  (`user_code` is on `.authorization`), then `poll_device_authorization(dev.device_code)`
  to get `result.token`. Tokens are org-granted. Requests to other orgs return 403.

## Poking the live node

For authorized local fixture setup or inspection, run
`elixir --sname x_$RANDOM --cookie comma-dev-cookie script.exs`
with `:erpc.call(:"comma@<hostname>", Mod, :fun, [args])`. Useful calls:
`Accounts.get_user_by_email/1`, `Memberships.put_org_member/3`,
`UserOnboardings.ensure_onboarding/1` and `complete/1` (users must be onboarded, or
dashboard pages redirect to `/onboarding`), `Conversations.list_project_conversation_messages/3`.
Use script files, not `elixir -e` one-liners. Quoting and match errors in
one-liners fail silently.
Standard dev tenants: afk-ai, test-1, board-demo (`demo@comma.local`, project demo-swarm).

## Gotchas

- Feature flags follow the dev_login pattern: a value in effective `config.json`,
  read by `runtime.exs` at boot, then an `Application.get_env` guard in the
  controller. To flip a flag at runtime for a probe, use erpc
  `Application.put_env(:bridge_for_teams_web, <flag>, false)`. Restore it after.
- Server-rendered HTML is grep-able evidence (`curl -b cookies.txt .../orgs/<slug>`).
