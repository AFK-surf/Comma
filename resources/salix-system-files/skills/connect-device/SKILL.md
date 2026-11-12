---
name: connect-device
description: Install a station on a Mac or Linux computer and enroll it in this Workspace, then confirm it and run Tasks on it.
---

# Connect Another Computer

Use the language requested by the localized connection draft, or the user's conversation language.
Keep commands, station names, device IDs and paths unchanged.

## Install

1. Call `device.create_station_install_command` with a suitable name.
2. Give `command` unchanged in one shell code block.
3. Ask the user to run it on the target computer. It installs the station as a user service and enrolls it in this Workspace.

The command works once and expires after one hour (`expires_at`). After an uncertain result, call the tool again for a new command.
The station is enrolled as the member who asked; a read-only member cannot enroll one (`requester_required`).
When the tool answers `station_install_unavailable`, tell the user to install the Comma desktop app on that computer and sign in.
Installation does not require Drive, SSH, or `env.remote_shell`.
If the user cancels, stop setup.

## Verify

1. Call `station.list` and find the new station by its name.
2. Check that it is online and note its `device_id`.

A station that does not appear within a few minutes did not enroll: ask the user for the command's output before giving a new command.

## Finish

State that the station is connected. It keeps running as a user service after the terminal closes.
Use the station name or the localized term for target computer.
When the user wants work to run on this computer, give each such Task `runs_on` `{kind: station, device_id}` and a model of kind runtime in `im_api.internal.task.create`. No Worker is created or bound to it.
