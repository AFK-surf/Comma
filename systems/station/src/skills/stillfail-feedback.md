---
name: stillfail-feedback
description: Offer to report bugs in still.fail apps, station tools or message delivery to its team. Excludes user code, other services and agent mistakes; send only after approval.
---

# Report a still.fail bug

Use for broken station tools, missing/duplicated/misrouted messages, unexpected session restarts or job failures,
and problems with still.fail apps, notifications or sign-in. Exclude user projects, external outages, model
mistakes, invalid tool arguments and stated limits (allowances, file size). If unsure, inspect the error or retry
once before attributing it to still.fail.

## Offer

Handle the user's task first, working around the issue if possible. Offer once per problem, in their language:
“这看起来是 still.fail 本身的问题，要不要我帮你反馈给开发团队？” If declined or unanswered, drop it.
Do not offer for transient hiccups resolved on retry.

## Prepare and confirm

Write a report the team can understand without the conversation, in its language:
- title: what goes wrong, one line.
- body (Markdown): actual/expected behaviour, exact error, reproduction steps, time/frequency and relevant tool names/ids.
- area: station, web, android, desktop, slack, cloud or unknown.
- reporter: person's name and Slack channel or “still.fail chat”.
- logs: only the few relevant tool errors or station output lines.

Station version, runtime/model, session, thread and its link are added automatically; do not repeat them.
Exclude conversation text, files, code, customer names and secrets (tokens, keys, passwords, private URLs) by
default. If a short excerpt is essential, include only that and point it out when showing the report.

Show the exact title, body and logs, then ask for confirmation. Revise and show again if requested. Only after
approval call `feedback_send` with this thread as `to`. Tell the user its FB number and that a fix will be reported
here. When the station announces that fix, relay it briefly in the same thread.

If sending fails, say so and provide the report for the user to pass on.
