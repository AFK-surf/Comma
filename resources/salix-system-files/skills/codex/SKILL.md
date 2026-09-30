---
name: codex
description: Use Codex CLI for ChatGPT login and stdio app-server subagent workflows for repository implementation tasks.
---

# Codex

Use this skill when a task involves Codex CLI login or using `codex app-server --listen stdio://` as a subagent to implement repository changes.

Retain the selected `device_id` and its `environment_id`. Pass `device_id` and
`environment` (the environment ID) to `env.exec` and every process operation.
Reuse known targets without repeating discovery.

## Core Rules

- Call `device.list` followed by `device.get` through the current runtime tool envelope before choosing where to work.
- Prefer `cloud-vm` by default when it is connected, because it has a durable Linux shell and often supports persistent process host APIs.
- If the user explicitly names a path on their local computer or another connected environment, use that requested environment/path instead of moving work to `cloud-vm`.
- Invoke Codex as `codex`; do not hard-code a machine-specific Codex binary path in commands or skill text.
- When starting Codex on `cloud-vm`, default to the global flag `--dangerously-bypass-approvals-and-sandbox` because `cloud-vm` is already an external sandbox. Put the flag before the subcommand, for example `codex --dangerously-bypass-approvals-and-sandbox app-server ...`. Do not apply this default to a user's local computer unless the user explicitly asks for it.
- Verify Codex before relying on it:
  ```bash
  command -v codex || true
  codex --version || true
  codex login status 2>&1 || true
  ```
- If the user says Bridge must not edit code directly, Codex must make repository file changes; Bridge may inspect, test, commit, push, and create/update PRs.
- Use the GitHub skill for clone/fetch/push/PR/review/checks work.

## ChatGPT Login

Use when the user asks to log in or re-authenticate Codex with a ChatGPT account.

1. Check status:

   ```bash
   command -v codex || true
   codex --version || true
   codex login status 2>&1 || true
   codex login --help 2>&1 | sed -n '1,120p' || true
   ```

   If already logged in and the user did not ask to re-authenticate, report success.

2. Start device-code login in a TTY wrapper:

   ```bash
   script -q -c 'codex login --device-auth' /tmp/codex-login-typescript.log
   ```

   Run this with `call(tool="env.exec", params={...})` in the chosen environment and record the returned `process_name`.

3. Tail the async process log to get the device URL and one-time code:

   ```javascript
   salix.call("env.process_tail", {
     device_id: "<device_id>",
     environment: "<environment_id>",
     process_name: "<process_name>",
     tail_bytes: 6000,
     max_bytes: 6000,
     wait_seconds: 3,
   });
   ```

   Give the user only the login URL, one-time code, expiry note, and a request to tell you when authorization is complete.

4. After the user authorizes, tail from the previous offset and verify:
   ```bash
   codex login status 2>&1 || true
   ```
   If the code expired, restart device-code login.

## Codex as a Stdio Subagent

Use this when Codex should implement repository changes while Bridge supervises. This is the preferred path when the user says Bridge should not edit files directly.

### Setup

1. Choose the environment/path according to the Core Rules.
2. In the target repo, ensure a clean or understood starting state:
   ```bash
   git status --short
   ```
3. Verify Codex is installed and logged in:
   ```bash
   command -v codex || true
   codex login status 2>&1 || true
   ```
4. Start stdio app-server as a persistent process from the repo root. On `cloud-vm`, include the bypass flag:
   ```text
   call(
     tool="env.exec",
     params={
       "device_id":"<device_id>",
       "environment":"<environment_id>",
       "working_dir":"/path/to/repo",
       "async":true,
       "description":"codex stdio",
       "command":"codex --dangerously-bypass-approvals-and-sandbox app-server --listen stdio://"
     }
   )
   ```
   Outside `cloud-vm`, omit `--dangerously-bypass-approvals-and-sandbox` unless the user explicitly requests it. Record the returned `process_name`.

### Protocol

Send newline-delimited JSON with `salix.call("env.process_write", ...)`.

Omit permission overrides to inherit the selected app-server configuration.
Relay approval requests through the supervising host. See the
[app-server protocol](https://learn.chatgpt.com/docs/app-server).

1. Initialize:

   ```json
   {
     "id": 1,
     "method": "initialize",
     "params": {
       "clientInfo": {
         "name": "bridge",
         "title": "Bridge",
         "version": "0.1.0"
       },
       "capabilities": { "experimentalApi": true }
     }
   }
   ```

2. Start a thread:

   ```json
   {
     "id": 2,
     "method": "thread/start",
     "params": {
       "cwd": "/path/to/repo",
       "developerInstructions": "You are running inside Codex app-server stdio. Bridge is orchestrating and must not edit repository files directly; you must make requested file changes. Inspect targeted files, avoid broad binary/asset scans, run focused tests when practical, and leave changes uncommitted.",
       "experimentalRawEvents": false,
       "persistExtendedHistory": true
     }
   }
   ```

   Save the returned `thread.id`.

3. Start a turn:
   ```json
   {
     "id": 3,
     "method": "turn/start",
     "params": {
       "threadId": "<thread-id>",
       "input": [
         {
           "type": "text",
           "text": "<specific task, relevant files, acceptance criteria, tests to run, and 'leave changes uncommitted'>",
           "text_elements": []
         }
       ],
       "cwd": "/path/to/repo"
     }
   }
   ```
   Save the returned `turn.id`.

### Monitor and control

- Tail by offset; do not repeatedly request the whole stream:
  ```javascript
  salix.call("env.process_tail", {
    device_id: "<device_id>",
    environment: "<environment_id>",
    process_name: "<process_name>",
    from_offset: <last_next_offset>,
    max_bytes: 120000,
    wait_seconds: 30
  })
  ```
- Look for `fileChange`, command execution events, final messages, and `turn/completed`.
- If Codex gets stuck or noisy, interrupt with both IDs:
  ```json
  {
    "id": 4,
    "method": "turn/interrupt",
    "params": { "threadId": "<thread-id>", "turnId": "<turn-id>" }
  }
  ```
  Then start a narrower follow-up turn.

### After Codex finishes

1. Review all changes, including untracked files:
   ```bash
   git status --short
   git diff --stat
   git diff --check
   git diff
   ```
2. Run focused tests yourself when practical. If a required toolchain is unavailable in the chosen environment, state that caveat.
3. If the changes are acceptable, use normal GitHub workflow to commit, push, and open/update a PR.
4. Final response should include PR/branch, commit SHA, summary, tests run, and caveats.

## Common Pitfalls

- Use `--listen stdio://` for JSON-lines orchestration.
- Do not claim tests ran if the chosen environment lacks the relevant toolchain.
- `git diff` does not show untracked files; always check `git status --short`.
