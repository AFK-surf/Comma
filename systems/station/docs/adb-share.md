# A phone's adb, shared with a station's agents

A person can lend their Android phone to the agents of one station. The station
reaches the phone's own adbd (Wireless debugging, Android 11 and later) at
`127.0.0.1:<port>`, so an agent there runs `adb -s 127.0.0.1:<port> …`. The bytes
go only over the phone's mesh link to the station. adb's own TLS runs end to end.

```
agent ─ adb ─ 127.0.0.1:<port> on the station ─ stream on the phone's link ─ the phone's core ─ 127.0.0.1:<adbd>
```

## On the phone

- **Wireless debugging** has to be on. The person turns it on the first time
  (Developer options, needs Wi-Fi). When the station's adb holds the phone, the
  person can ask it to grant the app `WRITE_SECURE_SETTINGS` (`adb.grant`). Then
  the app turns Wireless debugging on itself (`Settings.Global adb_wifi_enabled`).
- **Its ports** are random. The app finds them by DNS-SD on the device
  (`_adb-tls-connect._tcp`, `_adb-tls-pairing._tcp`) and gives them to the core
  (`adb.share`).
- **Pairing**, once per station. The person opens 使用配对码配对设备 and types
  the six digits into the heads-up notification (channel `adb-pair`). The station
  runs `adb pair` through the pairing port (`adb.pair`).
- **While it is shared**, a foreground service keeps the app up and shows a
  notification with 停止. Sharing ends after an hour, when it is stopped, or when
  the app goes. Nothing is kept for a next run.

The core (`client/core-ts/src/adb.ts`) holds the offer: the `adbShare` topic and the
calls `adb.share`, `adb.stop`, `adb.pair`, `adb.grant`. Only native cores carry
tunnels. The web has no sockets.

## On the wire

Over the member link (ALPN `stillfail/admin/1`; station/src/mesh/serve.ts):

1. **The offer**, a stream the phone opens: the head line
   `{"method":"POST","path":"/admin/api/adb","headers":{},"adb":{"op":"share","phone":"<its device key, hex>","device":"Pixel 8","android":"14","package":"fail.still.android","adbd":true,"pair":false}}`,
   its send side finished at once. The station answers
   `{"status":200,"headers":{"content-type":"application/x-ndjson"}}`, then a
   line each time how its adb holds the phone changes:
   `{"serial":"127.0.0.1:37123","adb":"connecting|connected|unpaired|unauthorized|off|missing|failed","message":"…"}`
   (`off`: the phone said Wireless debugging is off, `"adbd":false`).
   The offer lasts while the stream does. To stop sharing, the phone stops
   reading it (STOP_SENDING). It also ends with the connection. A newer offer
   from the same device replaces it. A phone is identified by its person (the
   credential) and its device key. A link on one of its other keys (one per
   relay) is the same phone. An older station answers 404.
2. **Asks**, one stream each, with `"adb":{"op":"pair","code":"123456","phone":…}` or
   `"adb":{"op":"grant","phone":…}`: answered with a status and `{"message":"…"}`. Only the
   device that made the offer can ask.
3. **Tunnels**, streams the station opens on the offer's connection, one per TCP
   connection to its port: the head line `{"tunnel":"connect"}` (or `"pair"`, for
   `adb pair`); the phone answers `{"ok":true}` once it reached adbd (or
   `{"error":"…"}`), then bytes both ways until either side finishes.

## On the station

`station/src/mesh/adb.ts` opens a listener on `127.0.0.1` for each phone offered.
It runs `adb connect` to it when the offer comes and `adb disconnect` when it goes.
adb is the station machine's (`PATH`, `$ANDROID_HOME`). Without it the offer says
`missing`. Agents see the phones shared with them with the `adb_devices` tool
(`station/src/tools/adb.ts`). It also gives the link to ask a person for theirs:
`<cloud>/w/<workspace>/s/<station>/adb` opens the station's 共享调试 in the
Android app (an App Link). Sharing starts only when the person taps 开始共享 there.

Every agent on the station can use a phone shared with it. The person agrees to
this when they share it.
