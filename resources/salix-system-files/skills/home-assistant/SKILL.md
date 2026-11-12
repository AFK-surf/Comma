---
name: home-assistant
description: "Read and control the devices in the user's local Home Assistant through a gateway: lights, switches, climate, media players and TVs, locks, covers, 3D printers and anything else Home Assistant has an integration for. Use with the home-gateway skill when the user has Home Assistant, or asks about a device that Home Assistant controls (Xiaomi Home, Apple TV, Bambu Lab, Wake on LAN)."
activation: per-message
---

# Home Assistant

Run `/.runtime/skills/home-assistant/ha.js` with `device.lan_script` through a
gateway whose `capabilities.lan_gateway.methods` include `lan_script`. Follow
`/.runtime/skills/home-gateway/SKILL.md` to find the gateway. Home Assistant
stays on the user's network; never ask the user to expose it to the internet.

## On a Computer Gateway

When the gateway is a computer (`device.get` lists a command environment)
with `python3`, use the `ha` command on it through `env.exec` instead of
`ha.js`: its answers are not bound by the gateway's `max_result_bytes`, so it
reads the whole entity list.

1. Install it once: `env.copy` `/.runtime/skills/home-assistant/ha.py` from
   `vfs` to `~/.local/bin/ha` on the computer, then `chmod +x ~/.local/bin/ha`.
   Run `ha check`.
2. `ha` reads `~/.config/comma-ha/connection.json`
   (`{"url": "http://<host>:8123", "token_file": "<path>"}`) on the computer.
   When it says it cannot read the connection, ask the computer's owner to put
   a long-lived token in a file there and write that file; never write the
   token yourself and never ask for it in chat for this path.
3. Use it:
   - `ha catalog`: every live entity by area, with its services and
     capabilities. Use it to find the entity the user means.
   - `ha entities <text> [--domain light] [--all]`, `ha state <entity_id>`,
     `ha services <domain>`.
   - `ha call <domain>.<service> <entity_id> [key=value …]`, for example
     `ha call light.turn_on light.office brightness_pct=40`. `accepted` only
     means Home Assistant took the call. It reads each entity back after the
     call; report that state and its attributes. When `differs` lists an
     asked value, the device has not reached it: tell the user what it shows
     now.
   A service existing does not mean the entity supports it: check
   `supported_features` and `supported_color_modes` in `ha state` first.

## Find Home Assistant

Call `device.lan_discover`. Home Assistant is a host whose `device.protocol` is
`home_assistant` (mDNS `_home-assistant._tcp`). Use its `ip` as `host`. Its
port is 8123 unless the user says otherwise.

## Token

Home Assistant needs a long-lived access token (Profile › Security › Long-lived
access tokens in Home Assistant). It is a saved device secret of kind
`api_token`:

1. Call `device.secret_list`. An `api_token` whose name or host matches is the
   token: give it as `secrets: {"token": "<name>"}`.
2. If none matches, ask the user once to create a token and give it. Save it
   with `device.secret_save` (`kind: "api_token"`, a short `name` such as
   `home-assistant`, and `host`).
3. Never repeat, quote or summarize the token or any part of it.

## Read

- All entities: `args: {"path": "/api/states"}`. The answer can be long: read
  one entity with `/api/states/<entity_id>` once you know it.
- Services a domain has: `/api/services`.

## Change

`args: {"path": "/api/services/<domain>/<service>", "body": {"entity_id": …}}`,
for example `light/turn_on` with `brightness_pct`, `climate/set_temperature`
with `temperature`, `media_player/turn_off`, `wake_on_lan/send_magic_packet`
with `mac`. Read the entity again afterwards and report what it says.

Ask the user before you unlock a lock, open a garage door or cover, turn off an
alarm, or start a 3D print or change its temperature. Stopping or pausing a
print needs no confirmation.

## Errors

The failure code, or for `script_failed` the start of its message:

- `bad_token`: the token is missing or refused. Ask for a new one and save it
  again under the same name.
- `ha_error`: Home Assistant refused the call (often a wrong entity or service
  name). Read `/api/states` or `/api/services` and fix it.
- Gateway errors: see the home-gateway skill.
