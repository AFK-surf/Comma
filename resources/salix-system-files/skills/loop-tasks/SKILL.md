---
name: loop-tasks
description: Create, change, resume, complete and report on Loop Tasks, the Tasks whose Worker repeats work on a schedule or keeps watching something ("every morning at 9", "watch PR #12 until it is merged"). Read before any im_api.internal.task.create or task.update with loop.
metadata:
  displayName: Loop Tasks
prompt_summary: "Read before creating, updating, resuming, completing, or reporting on a repeating or watching Loop Task (task.create/update with loop)."
---

# Loop Tasks

Delegated work that repeats or keeps watching something is one Loop Task: one im_api.internal.task.create call with loop, covering every run ("every morning at 9", "every 6 hours, 5 times", "watch PR #12, handle each new comment, stop when it is merged"). Its Worker runs it with one Background Loop.

- Cadence: cron with timezone for clock times and days, every_minutes for an interval, events for "when X happens", including product events such as "after every meeting" (meeting.completed). Omit timezone when the user names none: the server uses the requester's device or source timezone.
- events is a label of at most 32 characters naming only the source and the change ("New comments on PR #12", "PR #12 新评论"). Conditions, people and work go in content; the stop condition in until.
- With no cadence, or a day without a clock time, ask once proposing a concrete one (every day at 09:00, when a new comment arrives), and create nothing until the user answers.
- max_runs only from a stated count, ends_at only from a stated end date or duration (from the request's time and timezone), until only from a stated stop condition.
- content describes one run with its conditions and people ("only comments from Alice"); cadence and limits go only in loop.
- A Loop Task runs inside Salix: runs_on {"kind":"default"} or {"kind":"salix"}, no model of kind runtime; the Group's default place does not apply. Where the Group has a Cloud VM, its Worker runs commands there with env.exec; otherwise, when a run needs a machine, its Worker creates a sandbox Task for it, and you receive that Task's result as for any Task.
- loop.status pending means the Worker has not created the Loop yet; say the Loop runs only when it is active.
- Following one existing matter for the user in Home without delegated work is proactive.watch. A reminder or message you send yourself is schedule.create.

A new Loop request in an ended Loop Task reuses that Task with im_api.internal.task.update, passing the full new loop and the command for one run: this reopens it with the count at zero. Do not create a replacement or revive the old cadence. An ordinary follow-up or status change does not restart the Loop.

A Loop Task stays active between runs; each Worker report is one run, and one failed run does not fail the Task. ready_for_review does not apply. When a run needs the user (a sign-in, permission or decision), ask them; escalated does not pause the Loop, though the Worker can pause it until they answer. The server completes the Task at its run limit or end time (a runtime notice says so). Complete it yourself when the Worker reports the stop condition holds or the user asks to stop. When the Worker reports the Loop stopped on its own, tell the user and, as they decide, ask the Worker to resume or end the Task. Completing, cancelling, failing or archiving the Task ends its Loop for good.
