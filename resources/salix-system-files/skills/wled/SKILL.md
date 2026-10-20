---
name: wled
description: "Read and control WLED LED light controllers on the user's local network through a gateway (on/off, brightness, color, effects, presets). Use with the home-gateway skill when the user asks about WLED lights or LED strips."
activation: per-message
---

# WLED Light Controllers

Send every request with `device.lan_request` through a gateway. Follow the
`/.runtime/skills/home-gateway/SKILL.md` instructions to find the gateway and
the controller's address.

## Identify the Device

- mDNS service `_wled._tcp`, or a hostname such as `wled-<name>.local`.
- Read `GET http://<host>/json/info`. A WLED controller returns `"brand": "WLED"`,
  `ver` (firmware version), `name`, `mac` and `leds.count`. A name alone is
  not enough.

## Read State

`GET http://<host>/json/state` returns:

- `on` (true or false) and `bri` (master brightness, 0 to 255);
- `seg`: segments, each with `id`, `on`, `bri`, `col` (up to three RGB
  colors, for example `[[255,160,0],[0,0,0],[0,0,0]]`), `fx` (effect ID) and
  `pal` (palette ID);
- `ps`: the active preset ID, or -1.

Effect and palette names: `GET /json/eff` and `GET /json/pal`. Use the list
index as the ID.

## Change State

Send `POST http://<host>/json/state` with header
`Content-Type: application/json` and only the fields to change. Add
`"v": true` to get the full new state in the response.

- On or off: `{"on": true, "v": true}`
- Brightness 50 %: `{"bri": 128, "v": true}`
- Color of segment 0: `{"seg": [{"id": 0, "col": [[255, 0, 0]]}], "v": true}`
- Effect: `{"seg": [{"id": 0, "fx": <effect id>}], "v": true}`
- Preset: `{"ps": <preset id>, "v": true}`

Convert percentages to 0..255. Prefer explicit `"on": true` or `false`;
`"on": "t"` toggles and is not safe to retry.

## Verify

Check `on`, `bri` and the changed segment in the response, or read
`/json/state` again. If a request timed out, read the state before you retry.

## Limits

- Do not change `/json/cfg`, Wi-Fi, LED hardware settings, or firmware, and
  do not save or delete presets, unless the user asks for that change.
- Do not set very high brightness on large LED counts for a long time without
  the user's request. Power supplies can overheat.

## Sources

- [WLED JSON API](https://kno.wled.ge/interfaces/json-api/)
