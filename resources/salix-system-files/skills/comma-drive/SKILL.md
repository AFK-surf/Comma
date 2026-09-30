---
name: comma-drive
description: Read and write files in the user's Comma Drive, mounted at /drive/... for the fs.* tools. Use when the user asks to look at, search, save to, or organize files in their Drive, or when a deliverable should land in their Drive rather than only in the workspace.
metadata:
  displayName: Comma Drive
  icon: externaldrive
  color: blue
  visibility: toggled
---

# Comma Drive

The mount `/drive/...` is the user's Comma Drive. The ordinary file tools work
on it. `fs.list_files` with prefix `/drive` or `/drive/<folder>` browses it.
`fs.read_file` reads. `fs.write_file` and `fs.edit_file` publish. `fs.copy_file`
and `fs.move_file` move files between the Drive and the workspace.
`fs.delete_file` withdraws. `drive.status` says whether the Drive is reachable
right now and whether it accepts writes.

Reads and writes go through the Drive's hosted copy in the cloud, not through
the user's computer. That has consequences worth knowing before you promise
anything.

## Rules

- Call `drive.status` first when a task depends on the Drive. If it is not
  available, say so and use the workspace instead. Do not retry in a loop.
- `fs.glob` and `fs.grep` over the whole tree do not include the Drive. Name
  `/drive/...` as the prefix to search it. A listing stops at the first 2,000
  files. Ask the user for a folder when the Drive is larger.
- A file the user just saved on their computer may not be in the hosted copy
  yet. If a read misses a file they say exists, tell them it has not synced
  yet rather than that it does not exist.
- A write publishes the hosted copy's version of the path. If the user's
  computer already has its own version of that path, their Drive keeps both
  versions and shows them side by side. The write never overwrites theirs.
  Prefer a new path or a folder such as `/drive/Comma/...` unless the user asked
  you to replace a specific file.
- The user's computer sees a write at its next sync, usually within a minute.
  Say "saved to your Drive" and, if they cannot find it yet, that it is on its
  way.
- `fs.delete_file` withdraws the hosted copy's version only. When the tool
  reports that one of the user's devices still publishes the file, only that
  device can remove it. Say so and stop. This is not an error.
- A full read stops at 10 MB, and the tool says when it cut a file short. Use
  `start_line` and `num_lines` for long text files.
- A Drive that was never opened in the Comma desktop app has no synced folder
  yet. If every read answers not found and `drive.status` reports no replica
  attached, ask the user to open Comma Drive on their computer once.
