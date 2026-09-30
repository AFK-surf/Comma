---
name: verify
description: Verify requested Comma/BridgeForTeams behavior against a local development stack. Use for running-app validation, not customer onboarding or shared-environment authentication.
---

# Verify changes against the running dev stack

## Launch

Resolve the current stack and port overrides before starting or restarting it.
Use `docs/development.md` from the repository root for current setup.
Do not reset databases to make a validation pass. Do not restart a process
owned by another task without coordinating with its owner.

For the native local stack only, from `systems/`:

```bash
elixir --sname comma --cookie comma-dev-cookie -S mix run --no-halt   # run in background
```

Check the selected endpoint until ready or the startup budget expires. Use two
minutes when the stack has no documented budget, then report the startup error.
Default ports: **4101 = BridgeForTeams dashboard**, 4000 = Salix/Comma web
(`/dash/login`), plus 4200/4400. The server runs the code as compiled at boot —
**restart it after editing** (LiveView code reloading is not reliable for core
contexts).

## Auth handles

These development shortcuts apply only to an explicitly selected local fixture.
Use normal product authentication for onboarding and shared environments.
Do not treat fixture setup or direct erpc calls as proof of product authorization.

- **Dashboard session (browser/curl):** `GET http://localhost:4101/dev/login?email=<user>&to=/`
  sets a real session and redirects (needs `bridge_for_teams.dashboard.dev_login: true`
  in the gitignored effective `config.json`; flags there are read by
  `config/runtime.exs` at boot). Works with `curl -c cookies.txt` and with headless
  chromium (`chromium-browser --headless --screenshot=... --virtual-time-budget=20000 "<dev-login-url>"`)
  — the login redirect carries the cookie within one navigation.
- **CLI bearer token (for `/v1` `:cli_api` routes):** run the device flow over erpc
  against the live node — `BridgeForTeams.CLI.Login.start_device_authorization(%{})`,
  then `approve_device_authorization(dev.authorization.user_code, user, [org_id])`
  (note: user_code is on `.authorization`), then `poll_device_authorization(dev.device_code)`
  → `result.token`. Tokens are org-granted; requests to other orgs 403.

## Poking the live node

For authorized local fixture setup/inspection: `elixir --sname x_$RANDOM --cookie comma-dev-cookie script.exs`
with `:erpc.call(:"comma@<hostname>", Mod, :fun, [args])`. Useful calls:
`Accounts.get_user_by_email/1`, `Memberships.put_org_member/3`,
`UserOnboardings.ensure_onboarding/1` + `complete/1` (users must be onboarded or
dashboard pages redirect to `/onboarding`), `Conversations.list_project_conversation_messages/3`.
Prefer script files over `elixir -e` one-liners (quoting/match errors fail silently).
Standard dev tenants: afk-ai, test-1, board-demo (`demo@comma.local`, project demo-swarm).

## Gotchas

- Feature flags follow the dev_login pattern: value in effective `config.json` →
  `runtime.exs` at boot → `Application.get_env` guard in the controller. Flip at
  runtime for probes via erpc `Application.put_env(:bridge_for_teams_web, <flag>, false)`
  (restore after).
- Server-rendered LiveView HTML is grep-able evidence (`curl -b cookies.txt .../orgs/<slug>`),
  since mount runs the sync/mirror logic even on the dead render.
