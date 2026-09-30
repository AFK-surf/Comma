---
name: bft-operator
description: Operate Bridge for Teams through the bft CLI, especially device login, organization context, runner onboarding and lifecycle, runner readiness, and project device operations. Use when a user asks a local agent to configure or inspect BFT.
---

# BFT operator

Treat the installed CLI as the command authority. Start with:

```sh
bft commands --json
bft agent help overview --json
bft agent help auth --json
bft agent help output --json
```

Load the narrow help topic for the task, such as `runners` or `devices`, and
follow structured `next_action` fields instead of guessing command syntax.

## Safety contract

- Use JSON output for decisions. Parse `schema_version`, `ok`, and errors from
  stderr; exit 2 means the user has a manual step.
- Authenticate with `bft auth login` and let the user approve the device flow.
- Confirm the API base and organization before acting.
- Before a command marked `mutates`, explain its target and effect and get the
  user's explicit approval. Add `--confirm-mutating` when the command metadata
  or help requires it, and only after approval.
- Treat returned one-time install commands as secrets: execute them only on the
  target Mac and never repeat them in chat or logs.
- After approval, create exactly one install command and execute it immediately;
  do not make a second generation request just to inspect its response.
- Verify changes with a read command. Do not infer server readiness from a
  local process alone.

## Runner lifecycle

Load `bft agent help runners --json` and inspect `bft runners list` first. If a
runner must be installed, request approval before creating its one-time install
command.

After installation, run the installed runner's `doctor` check. For a temporary
run, start the runner in the foreground and keep that terminal open. For a
persistent run, use its `service start` command under the same non-root macOS
login and check both `service status` and `status`. Never run the foreground
worker and managed service at the same time. Finish by verifying a recent
online heartbeat with `bft runners list`.
