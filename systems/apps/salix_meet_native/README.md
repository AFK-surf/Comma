# salix_meet_native

This app runs a Google Meet bot inside a Salix node. It serves the `native_runtime`
Meeting source. `Salix.Bindings.MeetingNativeRuntime` connects it to the
`SalixMeet.Ports.MeetingDispatch` port.

Entry points:

- `SalixMeetNative.join/2`, `leave/1`, `send_chat/3`, and `local_status/1`
- `SalixMeetNative.Drain.drain/1`, called by `Comma.PodLifecycle.pre_stop/1`

Google Meet has no API that joins a meeting as a participant. This app sends the
Meet join RPCs and speaks the media protocol directly. It is a port of the Go
`meetnative` runtime. Golden tests compare its wire bytes with the Go output.

## Ownership and lifecycle

- One `Runtime` and one `Session` process serve each live Meeting, on the node
  that handled the join.
- One bot serves a Meeting ID, and one bot serves a Meet code. A join for another
  Meeting ID with a Meet code that a bot already serves fails with `:meet_in_use`.
- The binding writes the host node to Meeting state as `native_node`. A status read
  asks that node. An unreachable node gives `:unavailable` until the Meeting
  watchdog ends the Meeting. The binding clears `native_node` after the final
  update.
- A draining node refuses new joins.
- With `master_token_factory.profile` set, the bot joins with that Google account
  when the master token factory reports it `ready`. If the account cannot sign in,
  the bot joins as a guest once. It sends a `guest_fallback` status, and Meeting
  state gets `joined_as: guest`. "Cannot sign in" means the account is missing or
  not `ready`, the factory answers 401 or 404 for its ya29, or Meet rejects the ya29
  before admission. Without `guest_factory`, the join fails with `login_required`.
  A token factory error or timeout fails the join and does not fall back.
- Without a profile, the bot joins as a guest and sends no notice.
- A Meeting that fails after admission still delivers its transcript and recording.
- After admission, a bot leaves and delivers its results when no other participant
  joins within 10 minutes, or 45 seconds after the last participant leaves.
- The pod preStop step tells each local bot to leave and deliver its results.
  A bot that was not yet admitted fails its join attempt. For a calendar Meeting,
  the join retry can then place it on another node.
- A killed node loses unfinished recordings. A later join with the same Google
  account clicks "Switch here" in the token factory and replaces the old device.

## Recording

The `Recorder` writes `audio.ogg`, one `audio-<ssrc>.ogg` file for each track, and
`timeline.json` to a temporary directory for each Meeting. The final update sends
`audio.ogg` as `src_path`. Salix accepts that path only from this runtime and only
inside the Meeting directory. The `Runtime` deletes the directory after delivery.

## Configuration

```json
"meetings": {
  "driver": "connector",
  "runtime_source": "native_runtime",
  "master_token_factory": {
    "base_url": "https://<master-token-factory>",
    "secret": "<secret>",
    "profile": "Default"
  },
  "guest_factory": {
    "url": "https://<guest-factory>/v1/handoff",
    "secret": "<secret>"
  }
}
```

The Workers deploy from `systems/cloudflare/meet-token-factory`. `guest_factory.url`
must end with `/v1/handoff`.

Do not set `meetings.runtime_url`. It overrides `meetings.driver`.

## Tests

Run the app tests from `systems/`:

```sh
mix test apps/salix_meet_native/test
```

The live test joins a real Meeting. It reads `MEET_URL`, `MEET_TOKENFACTORY_URL`,
`MEET_TOKENFACTORY_SECRET`, and optionally `MEET_GOOGLE_PROFILE`:

```sh
mix test apps/salix_meet_native/test --only live_meet
```
