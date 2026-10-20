---
name: tasmota
description: "Read and switch Tasmota smart plugs, relays and lights on the user's local network through a gateway, and read their power sensors. Use with the home-gateway skill when the user asks about a Tasmota device."
activation: per-message
---

# Tasmota Devices

Send every request with `device.lan_request` through a gateway. Follow the
`/.runtime/skills/home-gateway/SKILL.md` instructions to find the gateway and
the device's address.

Tasmota runs commands over HTTP GET:
`http://<host>/cm?cmnd=<command>`. URL-encode spaces as `%20`. A GET to this
path can change state, so treat every command as a write.

## Identify the Device

- Read `GET http://<host>/cm?cmnd=Status%200`. A Tasmota device returns JSON
  with `Status` (`DeviceName`, `FriendlyName`, `Module`), `StatusFWR`
  (`Version`) and `StatusNET` (`Hostname`, `Mac`).
- Match the device by `DeviceName`, `FriendlyName` or `Mac`, not by IP address
  alone.
- If the response is HTTP 401, the device has a web password. Tell the user
  and stop. Do not ask for the password in chat.

## Read State

- Relays: `cmnd=Power` returns `{"POWER": "ON"}`. With several relays, use
  `Power1`, `Power2` and so on, or read `StatusSTS` from `Status%2011`.
- Sensors and energy: `cmnd=Status%2010` returns `StatusSNS`. Energy
  monitoring plugs report `ENERGY` with `Power` (W), `Voltage` (V),
  `Current` (A) and `Today` (kWh).
- Lights: `cmnd=Dimmer` (0 to 100) and `cmnd=Color`.

## Change State

1. Find out what is connected to the plug before you switch it. Ask before you
   switch a heater, a network device or a medical device.
2. Read the current state.
3. Send an explicit state: `cmnd=Power%20On` or `cmnd=Power1%20Off`.
   For lights: `cmnd=Dimmer%2050` or `cmnd=Color%20FF8800`.
4. Read the state again and report it.

Prefer `On` and `Off` to `Toggle`. A toggle is not safe to retry after a
timeout.

## Limits

- Do not send `Reset`, `Restart`, `Upgrade`, `OtaUrl`, `WifiConfig`,
  `SSId`, `Password`, `Module`, `Template`, `Rule`, `Timer` or `Backlog`
  commands unless the user asks for that exact change.
- Relay on with 0 W can mean that the load is off or not connected. It does
  not mean the command failed.

## Sources

- [Tasmota commands](https://tasmota.github.io/docs/Commands/)
- [Tasmota HTTP requests](https://tasmota.github.io/docs/Commands/#with-web-requests)
