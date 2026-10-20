---
name: gree-ac
description: "Read and control Gree air conditioners on the user's local network through a gateway (格力空调, and other brands with a Gree Wi-Fi module): power, mode, target temperature, fan speed, swing, quiet, turbo and sleep. Use with the home-gateway skill when the user asks about an air conditioner or AC (空调), or says a room is too hot or too cold."
activation: per-message
---

# Gree Air Conditioners

These units speak the Gree protocol: encrypted UDP on port 7000, not HTTP.
Send every request with `device.gree_request` through a gateway whose
`capabilities.lan_gateway.methods` include `udp_request`. Follow the
`/.runtime/skills/home-gateway/SKILL.md` instructions to find the gateway.
If no gateway advertises `udp_request`, tell the user the gateway needs a
firmware or connector update and stop. Do not fall back to a script on the
user's computer.

The platform binds to the unit by itself. Do not ask the user for a key, a
password or the Gree+ app.

## Identify the Unit

- Call `device.lan_discover` with the gateway. A Gree unit is a host whose
  `device.protocol` is `gree`. Its `device.name` is the name the user gave it
  in the Gree+ app. Use the host's `ip` as `host`.
- If the result has no `probed` list, the gateway cannot ask hosts for their
  protocol yet, and a Gree unit shows only an ARP entry. Ask the user for the
  unit's IP address then.
- When several units match and the user did not say which room, ask.

## Read State

`status` with the columns to read, for example
`["Pow", "Mod", "SetTem", "TemUn", "TemRec", "WdSpd", "TemSen"]`. `values`
has one entry for each column:

- `Pow`: `0` off, `1` on;
- `Mod`: `0` auto, `1` cool, `2` dry, `3` fan, `4` heat;
- `SetTem`: target temperature in whole degrees Celsius, 16 to 30. It is
  Celsius also when the unit shows Fahrenheit;
- `TemUn`: the unit that the display shows, `0` Celsius, `1` Fahrenheit;
- `TemRec`: `0` or `1`, the extra Fahrenheit step. It has a meaning only
  when `TemUn` is `1`;
- `WdSpd`: fan speed, `0` auto, `1` (low) to `5` (high);
- `TemSen`: room temperature in degrees Celsius. Many units report it plus
  40: when the value is 40 or more, subtract 40. A unit without the sensor
  reports `0`; do not report that as a temperature;
- `SwUpDn`: vertical swing, `0` off, `1` full swing, `2` to `6` fixed from
  top to bottom;
- `SwingLfRig`: horizontal swing, `0` off, `1` full swing, `2` to `6` fixed
  from left to right;
- `Quiet`: `0` off, `1` on;
- `Tur`: turbo, `0` off, `1` on;
- `SwhSlp`: sleep mode, `0` off, `1` on;
- `Lig`: the display light, `0` off, `1` on.

## Change State

`set` with the columns to change and their values:

- On or off: `{"Pow": 1}` or `{"Pow": 0}`.
- Temperature: `{"SetTem": 26}` when `TemUn` is `0`. For Fahrenheit, see
  below.
- Mode: `{"Mod": 1}`. To turn the unit on in a mode, send both:
  `{"Pow": 1, "Mod": 1, "SetTem": 26}`.
- Fan speed: `{"WdSpd": 3}`. `Quiet` and `Tur` exclude each other: set the
  other one to `0` in the same call.

Do not set `TemUn` unless the user asks to change the unit that the display
shows.

Change only the columns the user asked for. "Too hot" or "too cold" without
a number is a change of one or two degrees from the current `SetTem`, not a
new mode.

## Fahrenheit

Read `TemUn` before you report or set a temperature. When it is `1`, speak
to the user in Fahrenheit, but `SetTem` stays Celsius:

- To read: Fahrenheit = `SetTem` × 1.8 + 32, rounded down, plus `TemRec`.
  `SetTem` 24 with `TemRec` 1 is 76 °F.
- To set F degrees: C = (F − 32) ÷ 1.8. `SetTem` is C rounded to the nearest
  whole number. `TemRec` is `1` when C is greater than `SetTem`, and `0`
  otherwise. Send both: 77 °F is `{"SetTem": 25, "TemRec": 0}`, and 76 °F is
  `{"SetTem": 24, "TemRec": 1}`.
- Never send a Fahrenheit number in `SetTem`.

## Verify

After every change, call `status` again and report what the unit returns,
not what you requested.

## Errors

- `device_not_answering`: nothing answered on UDP 7000. Check the address
  with `device.lan_discover` and that the unit has power.
- `device_reply_malformed`: the host is not a Gree unit.
- `device_bind_failed`: the unit does not hand out a key on this network.
  Tell the user that this unit cannot be controlled locally.
- `device_error`: the unit refused the request, often a value out of range.
  Fix the value.
- `device_no_reply` or `gateway_timeout`: the change may have happened. Read
  the state before you retry.
- Gateway errors (`gateway_offline`, `operations_not_allowed`): see the
  home-gateway skill.

## Sources

- [greeclimate](https://github.com/cmroche/greeclimate)
- [gree-remote protocol notes](https://github.com/tomikaa87/gree-remote)
