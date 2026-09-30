---
name: apple-pim
description: "Apple Calendar, Reminders, and Notes on the user's Mac: read and create events, reminders, and notes, and run the user's Shortcuts."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

These apps have no cloud API for Salix. Run local tools with `env.exec` on the
initiating Message's client device (the user's Mac).

## Calendar

`ical` (github.com/BRO3886/ical, `brew install ical`) uses EventKit and returns
JSON:
- `ical today -o json`
- `ical add "<title>" -s "tomorrow 9am" -e "tomorrow 9:30am" -c <calendar>`
Check `ical --help` for list and delete commands.

## Reminders

`reminders-cli` (`brew install keith/formulae/reminders-cli`):
- `reminders show-lists`
- `reminders show <list> --format json`
- `reminders add <list> "<text>" --due-date "tomorrow 9am"`
- `reminders complete <list> <index>`

## Notes

Use `osascript`. Note bodies are HTML. Locked notes cannot be read.
`tell application "Notes" to make new note at folder "Notes" with properties {name:"<title>", body:"<p>text</p>"}`
To read, get `name` and `plaintext` of notes whose name contains the query.

## Shortcuts

`shortcuts list` and `shortcuts run "<name>" -i <input file>` run flows the user
already built.

## Permissions

The first use shows a macOS prompt for Calendar or Reminders full access, or
for Automation of Notes. Ask the user to click Allow. If it was denied, they
turn it on in System Settings > Privacy & Security.

Do not use the archived `apple-mcp` package. Deleting events or notes and
sending invites are hard to undo. Confirm them first.
