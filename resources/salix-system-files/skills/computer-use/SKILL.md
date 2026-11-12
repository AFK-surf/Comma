---
name: computer-use
description: Do the task in apps on the user's computer with env.computer_use in background mode. Use when the user tags /computer-use.
metadata:
  displayName: Computer use
---

# Computer use

Do this task with `env.computer_use` on the user's computer.

1. Call `env.computer_use` with `action="help"` and follow its workflow to find the device and environment.
2. Start the session in background mode: `action="start"`, `args={mode: "background", apps: [...]}`.
   The user keeps their screen, pointer and keyboard.
3. Use foreground mode only when the app has no usable accessibility tree or the task needs drag-and-drop across windows.
   Tell the user before you change to it.
4. Call `action="end"` when the task is done.

If no environment has `computer_use_tool`, tell the user to open the Comma app on their Mac and allow Computer use. Do not do the task another way without asking.
