---
name: apple-pim
description: "Apple Calendar, Reminders, Contacts, Notes, Messages and Mail on the user's Mac: read and create events, reminders and notes, look people up, send messages, draft email, and run the user's Shortcuts."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

These apps have no cloud API for Salix. The user installs Mac apps in Comma >
Plugins on their Mac and turns each app on there; Comma then serves its tools
as `mcp.mac.<tool>`:
`calendar_*`, `reminders_*`, `contacts_*`, `notes_*`, `messages_*` and
`mail_create_draft`. Use `mcp.list` and `help` for the current tools.

A missing tool means the app is off. Tell the user which app to turn on in
Comma > Plugins > Mac apps on their Mac. Do not install command-line tools or run
`osascript` for these apps instead.

## Results to act on

- `permission_required`: macOS has not allowed Comma. The user allows it in
  Comma > Plugins > Mac apps on that Mac.
- `plugin_off`: the user turned the app off.
- `device_offline`: the Mac is asleep, offline, or Comma is closed.
- `timeout` on a change: it may or may not have been made. Ask the user to check
  the app before trying again.

## Notes on the apps

- Dates are ISO 8601 in the Mac's time zone unless they carry an offset.
- Calendar cannot add invitees. Create the event, then draft an invitation with
  `mail_create_draft`.
- A recurring event's occurrence is its `id` with `occurrence_start`.
- Messages sends to one phone number or email. It cannot read Messages history.
- `mail_create_draft` opens the message in Mail. The user sends it.
- Deleting events, reminders or notes is hard to undo. Confirm it first.

## Shortcuts

`shortcuts list` and `shortcuts run "<name>" -i <input file>` run flows the user
already built. Run them with `env.exec` on the initiating Message's client device
(the user's Mac).
