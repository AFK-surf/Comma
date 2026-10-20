---
name: stillfail-jobs
description: Run background jobs, long-running watches, web previews or tasks on another still.fail station. Use for work that outlives a turn or a browser service people need to use.
---

# Jobs and services

Jobs run in separate process groups with persistent logs. They survive turns and station restarts; interrupted jobs
restart. Completion and `stillfail-job notify` messages wake you. A job with a port is a service, kept running and
available to workspace members through its returned link.

## Background work

- Use `job_start` without a port for long builds, tests, data work or loops. Run quick commands directly; if a result
  is needed before answering, wait for it in the turn.
- Supply `command` (run by `sh -c`), a short `name`, and optionally `cwd` (defaults to the session workspace).
  Keep clones and outputs in that workspace.
- Tell people what is running, carry on with whatever does not depend on it, and end `waiting` only when nothing
  else is left; use `need_human` instead if you also need their input.
- To wait on CI or another remote run, start a job (or background command) that polls it and exits on the first
  failure: its completion wakes you. Do not end `waiting` on a guessed duration with nothing watching.
- Inside long jobs, `stillfail-job notify "<words>"` reports meaningful milestones or trouble, not every line.
  `ember-job` is an alias. Notices arrive via="ember"; relay only what matters and act on failures.
- Completion includes the exit code and log tail. `job_log` reads more (up to 1000 lines); `job_list` shows your
  jobs; `job_stop` stops one. A completed step needs no separate user post unless it is useful news.

## Watches

For an explicitly requested ongoing watch (CI, deployment, metrics, review queue) that outlives your own work, set `watch: true` and loop,
notifying on changes. The chat appears under 监控中, does not auto-archive, and asks before manual archiving.
End `waiting`: its timeout will not wake you while the watch runs; a notice, completion or user message will.
Give the next post a title naming the watch (e.g. 监控 · PR #482 的 CI); watch chats can be renamed immediately.
Stop the job when no longer needed; the chat then becomes ordinary again.

## Web services

Use a port for something people should try in a browser: a UI, prototype, dashboard or tool. A one-off answer,
static image or internal-only background task does not need a service.

1. Start with `command`, `name`, and `port` (1024–65535). Listen on `$PORT`; 127.0.0.1 is enough, e.g.
   `python3 -m http.server $PORT`. One service per port.
2. Verify it answers with `curl -sf http://127.0.0.1:<port>/`; retry briefly or inspect `job_log` on failure.
3. Post the returned `link` where requested (Slack: `<link|label>`), naming the service and what to try, not its
   port. It is private to workspace members, not a public URL.
4. Stop unused services with `job_stop`. To restart, stop then start (or let a dev server reload itself).
   Repeated crashes cause restarts with increasing delays and notices: inspect logs and fix the cause.

Services open in a frame on their own origin. Use root paths (`/`). Responses are relayed whole: WebSockets,
SSE and long-poll streams do not pass through. Disable browser hot reload; live data only appears when read.
Keep the shown version running during review; compare another version via a separate checkout/service.
The preview supports phone/tablet/desktop sizes, rotation, zoom and screenshot annotations; tell reviewers they
can mark places and comment. Use stillfail-show for evidence to accompany the link.

## Another station

Use `station_list` to discover workspace stations, then `station_list {station}` for capabilities and job access.
The target administrator controls permission; never enable `remoteJobs.allow` yourself to bypass it.

Prepare `station_job` with a stable `key`, upload inputs with `station_file`, then start the same key. Commands
run as the target OS user, not a sandbox. All jobs of this session share one directory on the target (the working
directory of each job), so a later job can build in what an earlier one cloned. Keep checkouts, worktrees and build
output inside it rather than elsewhere on that machine (or over ssh): it is removed with anything still running when
this chat is archived or deleted, or after 14 days unused, which is what keeps the target's disk free. Pin inputs and
versions: clone or fetch the intended revision there, or upload a bundle.

`station_job` lists, inspects, tails or stops your remote jobs. Completion and notices survive reconnects and
station restarts; no local polling job is needed. End `waiting`, naming the job. Download artifacts with
`station_file` and post them to the requesting chat. Downloads create new files, never overwrite; inputs may be
uploaded again before start.

After a timeout, inspect or retry the same key: work may already have run. Lost remote processes are not restarted
automatically; `failed` without an exit code means the outcome may be uncertain. Inspect before using a new key.
