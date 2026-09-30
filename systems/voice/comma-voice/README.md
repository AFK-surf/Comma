# comma-voice

`comma-voice` is the reference client for the `comma.voice.v1` WebSocket voice API.
It opens one voice session with the Router of an Agent Group.
It is also the E2E driver for the voice call core without Twilio.
The protocol contract is in `docs/messaging-voice.md`.

## Configuration

| Setting | Flag | Environment variable |
| --- | --- | --- |
| Salix base URL (`http`, `https`, `ws`, or `wss`) | `--server` | `COMMA_VOICE_SERVER` |
| Agent Group id | `--group` | `COMMA_VOICE_GROUP` |
| Voice agent API key (`salix_vk_...`) | `--key-file PATH` | `COMMA_VOICE_API_KEY` |

The key has no flag value. This keeps the key out of process lists and shell history.
If you give `--key-file`, the CLI uses the file and ignores `COMMA_VOICE_API_KEY`.
The CLI sends the key only in the `Authorization` header, never in the URL.

## Commands

```sh
export COMMA_VOICE_SERVER=https://salix.example.com COMMA_VOICE_GROUP=grp_123
export COMMA_VOICE_API_KEY=salix_vk_...

comma-voice check                      # readiness, formats, and limits
comma-voice devices                    # audio input and output devices
comma-voice call                       # microphone and speaker
comma-voice call --input in.wav --output out.wav --tail 15s
arecord -f S16_LE -r 24000 -c 1 -t raw | comma-voice call --input - --output - | aplay -f S16_LE -r 24000 -c 1
```

`check` exits with a non-zero code when authentication fails or when the response has `"ready": false`.

`call` flags:

- `--format pcm16_24k|pcmu_8k` selects the session audio format. The default is `pcm16_24k`.
- `--display-name NAME` sends a caller name to the agent.
- `--json` writes each text frame from the server to stdout as one JSON line.
- `--echo-gate` sends silence while agent audio plays and for 200 ms after it. This stops echo from the speaker, but the caller cannot interrupt the agent.
- `--capture-device N` and `--playback-device N` select devices by the index that `devices` shows.

Device mode prints final transcript lines on stderr.
Ctrl-C sends `session.end` and waits up to 2 seconds for `session.ended`.
A second Ctrl-C stops the process immediately.
miniaudio has no echo cancellation, so use headphones or `--echo-gate`.

## File mode

`--input` takes a mono 16-bit PCM WAV file. Use 8 kHz or 24 kHz audio.
The CLI resamples the input to the session rate and encodes it to the session format.
`--input -` reads raw little-endian mono PCM16 from stdin. `--input-rate` gives its rate.
The default rate is the session rate.

The CLI sends 20 ms frames, paced to real time.
After the input ends, it continues to send silence, so the model can find the end of the caller turn.
The CLI hangs up when no agent audio arrives for `--tail` (default 10s), or when the server ends the session.

`--output` writes the agent audio as a mono 16-bit WAV at the session rate.
`--output -` writes raw PCM16 to stdout. You cannot use `--output -` together with `--json`.
The output holds only agent audio. It does not hold the silence between agent turns.

## Playback, marks, and clear

The CLI keeps agent audio in a playback queue.
The speaker, or the output writer in file mode, takes audio from this queue in real time.
When playback passes an `output.mark`, the CLI sends `output.played` with the same name.
`output.clear` drops the queued audio.
Marks behind the dropped audio count as played, and the CLI answers them immediately.
Before the CLI hangs up in file mode, it writes the remaining queue and answers its marks.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Normal end: `session.ended` or close 1000 |
| 2 | Usage error, a bad input file, or no device support in this build |
| 3 | Authentication: HTTP 401 or 403, or close 4401 |
| 4 | Group busy: close 4409 or HTTP 409 |
| 5 | Any other close code, connection error, or readiness failure |

## Build and test

The default build includes device support. It needs cgo and a C compiler.
On Linux, miniaudio loads ALSA, PulseAudio, or JACK at run time.
The build links only `libdl`, `libpthread`, and `libm`, so it needs no audio development packages.

```sh
go build -o comma-voice .
CGO_ENABLED=0 go build -tags nodevice -o comma-voice .   # check and file mode only
go test ./...
CGO_ENABLED=0 go test -tags nodevice ./...
```

A build without cgo also excludes device support.
In that build, `devices` and device-mode `call` exit with code 2.
Set the version with `-ldflags "-X main.version=..."`.

## Licenses

| Dependency | License |
| --- | --- |
| `github.com/gorilla/websocket` v1.5.3 | BSD-2-Clause |
| `github.com/gen2brain/malgo` v0.11.26 | Unlicense (public domain) |
| miniaudio 0.11.25, bundled in malgo | Public domain (Unlicense) or MIT No Attribution, at your choice |

The `nodevice` build does not contain malgo or miniaudio.
