---
name: computer-use
description: Do the task in apps on the user's computer with env.computer_use in background mode. Use when the user tags /computer-use.
metadata:
  displayName: Computer use
---

# Computer use

Do this task with `env.computer_use` on the user's computer.

1. Call `env.computer_use` with `action="help"` and follow its workflow to find the device and environment.
2. Start the session: `action="start"`, `args={mode: "background", apps: [...]}`.
   On macOS, target app windows run on an isolated virtual desktop with a live Notch preview and AI cursor, keeping the user's primary screen, pointer and keyboard free.
3. Call `action="end"` when the task is done.

If no environment has `computer_use_tool`, tell the user to open the Comma app on their Mac or Windows computer. On a Mac, they also allow Computer use. Do not do the task another way without asking.
