---
name: miio-lights
description: "Read and control Xiaomi miIO lights on the user's local network through a gateway (Mi bedside lamp 2 / bslamp2 and Yeelight-family Mi lamps): on/off, brightness, color and color temperature. Use with the home-gateway skill when the user asks about a Mi or Yeelight lamp."
activation: per-message
---

# Xiaomi miIO Lights

These lamps speak miIO: encrypted UDP on port 54321, not HTTP. Send every
command with `device.miio_request` through a gateway whose
`capabilities.lan_gateway.methods` include `udp_request`. Follow the
`/.runtime/skills/home-gateway/SKILL.md` instructions to find the gateway.
If no gateway advertises `udp_request`, tell the user the gateway needs a
firmware or connector update and stop. Do not fall back to a script on the
user's computer.

## Token

Every lamp needs its 32-hex-character miIO token. `device.miio_request`
takes `token_ref`, the name of a saved token, never the token itself.

1. Call `device.secret_list` first. A `miio_token` whose name or host matches
   the lamp is its token: use its name as `token_ref`.
2. If none matches, ask the user once for the token. Save it with
   `device.secret_save` (`kind: "miio_token"`, a short `name` such as
   `bedside-lamp`, and the lamp's `host` and `model`), then use the name.
3. Never repeat, quote or summarize the token or any part of it (not even
   its first characters), in a reply, your reasoning, a file or a memory.
   Refer to it as "the saved lamp token".
4. Do not repeat the token from earlier messages, and never ask the user for
   a token that `device.secret_list` already names.

## Identify the Lamp

- Use the host saved with the token when there is one. `device.miio_request`
  uses it when you omit `host`.
- Otherwise call `device.lan_discover` with the gateway. A miIO lamp shows an
  mDNS service `_miio._udp` (name such as `yeelink-light-bslamp2_miio<id>`)
  or `_hap._tcp` (HomeKit), or only an ARP entry. Confirm the IP address with
  the user when several devices match. If the address changed, save the token
  again with the new `host`.

## Read State

`method: "get_prop"`, `params: ["power", "bright", "rgb", "ct", "color_mode"]`
returns the values in that order:

- `power`: `"on"` or `"off"`;
- `bright`: 1 to 100;
- `rgb`: color as an integer `R*65536 + G*256 + B`;
- `ct`: color temperature in kelvin;
- `color_mode`: `1` RGB, `2` color temperature, `3` HSV.

## Change State

Every change uses a 500 ms smooth transition:

- On or off: `set_power` with `["on", "smooth", 500]` or `["off", "smooth", 500]`
- Brightness: `set_bright` with `[<1..100>, "smooth", 500]`
- Color: `set_rgb` with `[<R*65536 + G*256 + B>, "smooth", 500]`
- White temperature: `set_ct_abx` with `[<kelvin>, "smooth", 500]`; bslamp2
  accepts about 1700 to 6500 K.

A successful change returns `["ok"]`. Prefer explicit `set_power` over
`toggle`, which is not safe to retry.

## Verify

After every change, call `get_prop` again and report what the lamp returns,
not what you requested.

## Errors

- `device_not_answering`: the lamp did not answer on UDP 54321. Check the
  address with `device.lan_discover` and that the lamp has power.
- `saved_token_not_found`: no token is saved under that name. Check
  `device.secret_list`, or ask the user for the token and save it.
- `bad_token`: the saved token is wrong. Ask the user for the correct token
  and save it again under the same name; do not guess.
- `device_error`: the lamp refused the command, often a parameter out of
  range. Fix the parameter, not the method.
- `device_no_reply` or `gateway_timeout`: the change may have happened. Read
  the state before you retry.
- Gateway errors (`gateway_offline`, `operations_not_allowed`): see the
  home-gateway skill.

## Sources

- [python-miio protocol](https://github.com/rytilahti/python-miio/blob/master/miio/protocol.py)
- [python-miio Yeelight integration](https://github.com/rytilahti/python-miio/tree/master/miio/integrations/yeelight)
