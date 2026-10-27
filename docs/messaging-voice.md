# Messaging and voice

[IM rules](tools-integrations.md#im-providers).

## Comma iMessage

Comma iMessage has two transports for the same binding. The Willow Mac relay with official BlueBubbles uses one shared iMessage account. [Photon shared lines](#photon-shared-lines) give each person a line from a pool.
Comma owns the Workspace binding. Salix owns the provider connection and Router delivery.
It takes private text and images only, not groups, SMS, or other destinations. Only Photon supports typing. The relay has no Settings entry. Settings › Channels shows iMessage only when Photon is configured.
For the relay, the API creates a ten-minute claim command that binds its sender and chat to the user's default Workspace. Authenticated calls cancel attempts and disconnect bindings.

Only the configured origin gets the bearer, without redirects. Sends need the binding's exact sender and chat.

Malformed values and group messages get no private-chat authority.
Limits: 1 MiB per event, ten images of 20 MiB per message, 1,000 expired claims pruned per pass, a 120-second database checkout per pass, and bounded HTTP waits.
A process pauses after three failed owning passes without a success. To resume from the saved cursor, restore the dependency and restart the receiver. Lock contention prevents a fixed total time bound.

A text or image send makes one HTTP attempt. A timeout, error, or no acknowledgement returns `imessage_delivery_unknown`, `retryable=false`. The Agent stops the turn and asks for verification in Messages. A relay message ID acknowledges, not proves Apple delivery. No cross-call deduplication.

Accept with a separate relay origin and database, after confirming the shared Apple identity and stopping any previous consumer. Keep the previous configuration and data. Check binding, inbound chat, text and image replies, disconnect, and rebind with a test contact; fixtures do not prove delivery. A rollback disables the receiver and keeps binding tables.

### Photon shared lines

[PhotonIMessage](../systems/apps/salix_im/lib/salix_im/photon_imessage.ex) calls the Photon REST API. Photon has no Elixir SDK.
Create a project in the [Photon v2 Beta dashboard](https://app.beta.photon.codes). Its project ID starts with `pho_prj_`.
Legacy dashboard credentials cannot configure it.
Free/Pro pooled lines send only to project Users with active assignments who messaged the line first.

1. The owner sends a phone number or Apple Account email as `handle` to the connect API.
2. Comma registers it as a Photon User, assigns a shared line, and opens a ten-minute attempt.
3. The person sends the code, or `bridgebot connect <code>`, from that handle to that line.
4. Only then is the binding active. Earlier messages do not reach the Agent.

Replies go only to the bound Space, from its line.
Settings shows the line, code, prefilled `sms:` link, and time left, read every 3 s until the attempt connects, ends, or expires.
The [receiver](../systems/apps/comma_web/lib/comma_web/imessage_photon_runtime.ex) lists received Messages from the Photon API, oldest first, at most five pages of 100 per pass.
A verified webhook starts a pass at once; a 60-second timer also starts one, which recovers missed webhooks.
Photon lists are eventually consistent, so each pass rereads a two-minute overlap, whose handled IDs the text cursor keeps. A Message visible only after the overlap is not received.

`POST /v1/comma/integrations/imessage/photon/webhook` verifies [Standard Webhooks](https://github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md). It checks `webhook-id`, `webhook-timestamp`, and each `v1,<base64>` value in `webhook-signature`. The MAC is HMAC-SHA256 of `<id>.<timestamp>.<raw body>`, with the base64-decoded `whsec_` secret. The timestamp must be within five minutes.
The Elixir reference library re-encodes a parsed JSON map and reads the wall clock directly. The adapter verifies the original bytes and uses `SystemsClock`, so it implements this narrow check locally.
Without the check, any caller can start passes and use the Photon rate limit. Photon issues the secret; Comma verifies it. A failed check returns 401 and starts no pass.
The body grants nothing: the receiver reads Messages from the API, and the timer still receives them when webhooks fail.

Each send uses a new idempotency key. A 4xx refusal returns `imessage_send_rejected`, `delivery_status=not_sent`, and provider diagnostics.
A timeout, 5xx, or missing Message ID returns `imessage_delivery_unknown`. Photon acceptance is not Apple delivery.
An image needs an upload and a send; its caption follows as separate text. A caption that fails after image acceptance returns unknown delivery.
Agent discovery exposes ordinary text and image sends. Spectrum SDK support does not establish v2 REST support or a plan capability matrix.
Existing callers can name `reply_to_message_id` or call `imessage.react`. Targets must belong to the bound Space.
Only HTTP 409 `SPACE_NOT_SENDABLE` with detail `Replies are not supported for this Space` permits one ordinary text or image send.
That request omits the parent and uses a new key. Success includes `reply_fallback=ordinary_message`, not an inline reply.
For reactions, that refusal returns `imessage_reaction_unsupported` without another send. Other refusals and ambiguous outcomes never trigger this behavior.
A supplied inbound parent ID adds `[Replying to message <id> by …]` with at most 500 characters. A missing original stays explicit.
Without a parent ID, input marks the target unavailable. The Agent must request needed quoted text instead of guessing a recent message.
While the Agent works, the line shows the typing indicator. Comma repeats it every 10 s per chat: ten chats use one of the five requests per second Photon allows.

A bound person's Messages within 2 s of each other, such as an image and its text, form one Router input.
It waits 2 s after the receiver first sees its last Message, at most 10 s. A waiting burst is not checkpointed; a crash replays it.
Its source ID names all its Messages. A Message that appears late makes a new input, never a lost one.

Disconnect releases the line assignment when no other binding or open attempt uses the handle; each timer pass also releases unused assignments older than 15 minutes. So the Photon project must serve one Comma deployment only. Photon has no API to delete a User, so Users stay in the project.
Set `COMMA_PHOTON_ENABLED`, `COMMA_PHOTON_PROJECT_ID`, `COMMA_PHOTON_API_KEY` (a `pho_sk_` project key), and `COMMA_PHOTON_WEBHOOK_SECRET`. Register the webhook destination in Photon by hand.

## Comma WeChat ClawBot

Owners create five-minute QR attempts with new IDs and optional pairing codes. Channels polls every 3 s with 15 s timeouts.
Refresh retries activation. Cancel and reconnect invalidate attempts. Retirement keeps only previously active records.
Comma owns references. Salix owns credentials, peers, cursors, and lifecycle. Setup locks the Workspace. HTTP holds no database checkout.
Activation rechecks authorization and references. Disconnect retires current and pending connections. CAS fences stale releases.
Tencent's SDK needs the OpenClaw Node runtime, so Elixir uses Req and OTP AES. QR URLs need approved WeChat HTTPS origins, without redirects.
Browser responses omit tokens and forbid caching. Only the scanned account's private messages enter its Workspace, never groups.

IM Connect stores one batch of at most 100 messages or 1 MiB before staging. Oversized batches cannot advance the cursor.
Revision CAS advances after Router admission or a product-command reply. The final head commits the cursor.
A 30 s lease reduces concurrency, but grants no delivery authority. Stale workers may replay, but cannot advance newer state.
Passes repeat 5 s after completion. Pending inputs survive restart and deployment. Older binaries cannot drain them, so use forward repair.

Current text and transcripts supply authority, never quotes. Quotes parse once, without recursion.
ID-only quotes resolve observed inputs and replies within one connect and peer: 10 direct items, 4 exact reads, no scans.
Quotes have a 64 KiB limit and seven-day logical expiry. Missing originals stay explicit, without a summary in their place.
Quotes grant no delivery authority or access to unobserved history.

Downloads share a 15 s soft budget. CDN connections time out after 5 s, without credentials or redirects. One transient retry shares the budget. Total wall time is unbounded.
CDN URLs and keys stay private. Peer authorization precedes staging and Session admission.
Raw voice and video need tools. Receipts prove neither transcription nor understanding.

Video accepts mp4, mov, webm, mkv, and avi paths, without transcoding or playback guarantees.
Captions are separate. Media can fail after a caption succeeds.
No drafts or status text leave. Presentation failure cannot reject input.
Each peer actor keeps typing tickets and 32 source IDs, refreshes at most every 4 s, and stops after 30 min or 60 s idle. Its requests time out after 2 s, without retries.

## Telegram questions and replies

`question.request` sends a native question in the current authorized Telegram chat. Choices use inline buttons. Otherwise the user replies in text.
Delivery ends the activation. The answer becomes a new input. A chosen card shows the answer without buttons. Repeated callbacks enqueue nothing.

Untargeted replies and questions quote the source message. Explicit targets stay unchanged.
References use Telegram IDs, never Salix or guessed IDs. Comma never retries an ambiguous send without its reference.

## Voice calls

Twilio and `comma.voice.v1` calls enter `salix_voice`. GPT-Live delegates to the Group's Router, the only agent brain.

- **CallActor.** `SalixVoice.CallActor` owns the call's profile, model, carrier, transcript, delegations, deadline, and charge, not durably. When model and carrier are ready, it greets and sends the Router `voice.call_started`; `voice.call_ended` gives the reason and open delegations.
- **Router tools.** `im_api.voice.say` speaks and answers any delegation. `voice.note` adds quiet context. `voice.hang_up` says an optional farewell, ending the call within 10 s. Text is at most 16,000 bytes, for a call of the tool's Group and connect. An ended call returns `voice_call_ended`. Do not retry.
- **Authority.** A call is private to its caller; `voice.say` reaches only that call. A phone caller is a provider user of the voice connect; a WebSocket caller acts as its key's principal.

### Limits, drain and billing

- `max_calls_per_node` calls per node, else `node_full`. `max_call_seconds` ends a call after a spoken notice.
- The carrier attaches within 20 s (Twilio) or 5 s (WebSocket), and GPT-Live starts within 15 s after the [profile](#voice-profile), or the call ends.
- Pod pre-stop runs `SalixVoice.Drain.drain/0` once readiness is withdrawn. New calls get `draining`. Live calls hear a notice, ending within 5 s; at 8 s drain ends all.

`BillingCore.VoiceMetering` authorizes at admission and before model start; a financial refusal starts no model. End-of-call charges use the Group billing owner, `resource_kind: "voice"`, key `voice:<carrier>:<carrier call ID>`, and model and carrier seconds. Transport loss bills at least elapsed model time.
No voice prices are seeded: charges stay pending until backfilled. A Group without a billing owner pays nothing.
`salix.voice.*` metrics use only `transport`, `reason`, and `outcome` labels.

## Twilio admission

1. `POST /v1/voice/twilio/{incoming,pin,status}` checks `X-Twilio-Signature` over the public URL and exact POST parameters. Failure returns 403 and no TwiML. Bodies over 16 KB return 413.
2. `To` must be a platform line, and `From` a number bound on it.
3. Full STIR/SHAKEN attestation (`TN-Validation-Passed-A`) passes. Other callers enter the number's PIN at `POST /v1/voice/twilio/pin`; a number without a PIN is refused.
4. `SalixVoice.admit/1` checks drain, enablement, the OpenAI key, capacity, and the Group's call.
5. Salix answers `<Connect><Stream>` to `/v1/voice/twilio/stream/<token>`.

After the signature check, Salix speaks each refusal, then hangs up.
A PIN has 4 to 8 digits, kept as a salted PBKDF2-SHA256 hash. `pin_max_failures` failures lock the number for `pin_lockout_seconds`. Success or a new PIN clears the count.

The stream token is an HMAC-SHA256 over call, connect, Group, `CallSid` and a 60 s expiry, keyed from the deployment credential root; an invalid one gets 404 before the upgrade.
At Twilio's `start` frame, the actor refuses a wrong or missing `callSid` and a second socket. The end sends a best-effort Calls API hangup.

| Check | Threat | Authority | Verifier | Failure |
| --- | --- | --- | --- | --- |
| Twilio signature | Forged webhook starts paid calls, skips caller checks | Twilio auth token | `TwilioWebhook` | 403 |
| Stream token | Stream URL holder takes over or hears a call | Signed webhook, the sole minter | `StreamToken`, `CallActor` | 404 or no attach |
| Voice key kind | Leaked inbound key opens paid sessions | Group API key store | `SalixWeb.Auth` | 401 |

Twilio and OpenAI have no official Elixir SDK: `Carrier.Twilio`, `TwilioClient`, `Model.GptLive`, `OpenAIVoices` isolate them.

## Caller numbers

Each voice Group has one `voice` IM Connect, elected by the `ProviderIdentity` reservation `voice:group:<group_id>`. It lists at most 20 verified numbers and delivers every call, WebSocket ones too.

A number binds only after Twilio Verify approves an SMS code (10 codes per Group and 5 per number each hour).
Each binding reserves `voice:<carrier>:<line>:<e164>`, so a number on a line routes to one connect. A number held by another Group gets 409 `voice_number_in_use`.
Removal ends its live call (`revoked`). A holder no longer listing the number routes nothing; another Group may take it after 60 s.
Comma exposes `/v1/comma/workspaces/:workspace_id/integrations/voice` for the default Group, without the connect, PIN hash or custom voice ID.

## WebSocket voice API

`GET /v1/agent-groups/{group_id}/voice` returns readiness, `busy`, formats, limits, and `sessions_url`. `GET .../voice/sessions` upgrades to one session with subprotocol `comma.voice.v1`.
Both need `Authorization: Bearer salix_vk_...` for the path Group, never a URL key. Before the upgrade: 401 for a bad key, 400 without the subprotocol, 503 when draining.
Text frames are JSON objects of at most 16 KB, named by `type`. Both sides ignore unknown fields and types. Breaking changes ship as `comma.voice.v2`.

| From | Message |
| --- | --- |
| Client | `session.start {audio_format, client, display_name?}`, first, within 10 s. Format `pcmu_8k` or `pcm16_24k` (little-endian mono). `client` is `name/version` |
| Salix | `session.started {call_id, audio_format, max_duration_s}` |
| Both | Binary audio, at most 16 KB per frame |
| Salix | `output.clear`: drop queued playback |
| Salix | `output.mark {name}`; the client answers `output.played {name}` at playback |
| Salix | `transcript {role, text, final}`, role `caller` or `agent` |
| Client | `session.end` |
| Salix | `session.ended {reason, duration_s}`, then the close |
| Salix | `error {code, message}`, `code` the integer close code |

| Close | Cause |
| --- | --- |
| 1000 | Normal end or the reason in `session.ended` |
| 4400 | Bad frame or order, or caller audio over 1.25x real time past a 5 s burst |
| 4401 | Key disabled, deleted or expired, or Group deleted |
| 4408 | No `session.start` in 10 s, no audio for 60 s, or no pong for 45 s |
| 4409 | The Group has an active call |
| 4410 | Client playback more than 8 s behind |
| 4503 | Draining, disabled, unconfigured, node full, or GPT-Live down |

[`comma-voice`](../systems/voice/comma-voice/README.md) is the reference client and E2E driver. HTTPS uses the same session and CallActor ([routes and bounds](../clients/apps/apple/README.md#https-voice-transport)).

## Voice agent API keys

A voice agent key is the `voice` kind of the Agent Group API Key record (`Salix.Control.GroupApiKeys`), with its hash-only storage, one-time plaintext, status, expiry, creator, and principal rules.

| Property | Inbound key | Voice agent key |
| --- | --- | --- |
| Prefix | `salix_gk_` | `salix_vk_` |
| Opens | Router post-message, Loop events | Voice readiness and sessions only |
| Minted by | Comma, Salix dashboard, tenant API, Router `inbound_api` tools | Comma, Salix dashboard, tenant API |
| Cap per Group | 20 | 20, counted separately |

The prefix selects the kind before the hash lookup; the stored kind must match. Routers cannot mint voice keys, so prompt injection gets no billable credential.
Rows default to `inbound`. Routes: Salix `/v1/runtime/agent-groups/:group_id/voice/api-keys`, Comma `/v1/comma/workspaces/:workspace_id/voice-api-keys`.
Disable, delete, and Group deletion reach live calls through `:pg`: a spoken notice, then close 4401. Key expiry ends calls. Session start updates `last_used_at`.

## Voice settings

Platform settings are one JSON object at `ctl/system/voice.json`, managed at `/dash/voice` or admin `GET`/`PUT /v1/admin/voice/settings` with compare-and-swap. `openai_api_key` and `twilio_auth_token` are write-only: reads show `<field>_configured`, blank keeps the value, `clear_secrets` removes it.

## Voice profile

An answer counts at its uncalibrated field threshold (70% to 80% winning probability); its fixed sentence extends the instructions and sets the greeting language. No user or Jev text reaches GPT-Live. Nothing is stored.

`SalixAgent.RouterDecision` sends the newest 12 user and assistant texts of the Router session, 1,500 bytes each, within 12 KiB. `decide` is public egress. By owner decision, message IFC labels and the Group IFC policy do not filter this text. Without text, it sends nothing.
It runs when `decide` is configured, metered as `voice_profile`; after 2.5 s or a failure, the base instructions apply.

## Call preferences

The voice connect's `voice_preferences` (`PUT .../voice/preferences`) hold `voice` (preset, `custom`, or null), `custom_voice`, and `router_calls`. `POST .../voice/custom-voice` makes a voice from a description, 5 per Group a day, and deletes the one it replaces: OpenAI keeps 100.
With `router_calls`, a one-to-one call (not a Signal group) speaks as the Router: its name, own instructions, user notes and newest texts (`RouterPersona`). With IFC on, they pass the `voice.say` check for the caller; unlabelled ones are dropped. `voice.call_ended` adds the transcript.

## Signal

Register at `/dash/signal/register`. Keys persist before startup. Failures stay `registering`. A verified session resumes `registering` accounts for that number and service. Active numbers are refused.
Shared tenant number: `/dash/signal`, `PUT /v1/admin/signal/settings`; a tenant's active account overrides it for new claims.
A `signal` IM Connect binds up to 50 ACI or `group:<id>` peers. `signal:peer:<account>:<peer>` routes each peer to one Group.
Bind with `comma connect XXXX-XXXX`. Codes show once, expire in 10 minutes, work once. Store only SHA-256 digests (`signal:claim:<account>:<digest>`). Unbound senders get no reply.
Bound messages, files, voice notes, reactions, edits, and deletes enter the Router at least once as `im_provider:signal:<connect>:<sender>:<timestamp>`. Permanent refusals drop only that one.
Accounts accept ACI and PNI invitations. Joining initializes missing profiles and keeps named profiles. Membership does not bind chats.
`signal.*` tools reach only bound chats. Replies and failure notices use `signal.send_message`. Bound peers' calls are Voice Calls. Unbinding ends them.
Routes: `/v1/runtime/agent-groups/:group_id/im-connects/signal`, `/v1/runtime/signal/number`, Comma `/v1/comma/workspaces/:workspace_id/integrations/signal`.
Calls need one TURN-over-TLS relay, no UDP or direct ICE paths. TLS failure stops startup.
