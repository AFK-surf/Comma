# Messaging and voice

[IM rules](tools-integrations.md#im-providers).

## Comma iMessage

Comma uses one shared iMessage account through the Willow Mac relay and official BlueBubbles. Comma owns the Workspace binding. Salix owns the provider connection and Router delivery.
It takes private text and images, not groups, SMS, typing or other destinations. The Settings entry stays hidden, and starts no polling, until shared-account readiness is resolved.
The retained API creates a ten-minute claim command that binds its sender and chat to the user's default Workspace. Authenticated operations cancel attempts and disconnect bindings.

Server configuration: `COMMA_IMESSAGE_ENABLED`, `COMMA_IMESSAGE_RELAY_ID`, `COMMA_IMESSAGE_RELAY_BASE_URL`, `COMMA_IMESSAGE_RELAY_BEARER_TOKEN`, `COMMA_IMESSAGE_SHARED_HANDLE`, and `COMMA_IMESSAGE_SHARED_IDENTITY` (display name).
Only the configured origin gets the bearer, without redirects. Sends require the binding's exact sender and chat.

One PostgreSQL advisory lock serializes receiver passes, every five seconds. A new relay ID starts at the tail. Admission or explicit rejection precedes cursor advancement. Replay after a lost checkpoint uses the Session input identity and deduplication.
Malformed values and group messages get no private-chat authority.
Limits: 1 MiB per event, ten images of 20 MiB per message, 1,000 expired claims pruned per pass, a 120-second database checkout per pass and bounded HTTP waits.
A process pauses after three failed owning passes without a successful one. Waiting for another owner does not reset the count. Restore the dependency and restart the receiver to resume from the saved cursor. Lock contention prevents a fixed total elapsed-time bound.

A text or image send makes one HTTP attempt. A timeout, error or missing acknowledgement returns `imessage_delivery_unknown`, `retryable=false`: the Agent stops the turn and asks for verification in Messages. A relay message ID is acknowledgement, not Apple delivery. There is no cross-call deduplication.

Before real acceptance, confirm the shared Apple identity, stop any previous relay consumer, and test locally with a separate relay origin and database. Preserve the previous configuration and data.
Verify binding, inbound chat, text and image replies, disconnect and rebind with the test contact. Fixtures do not prove real delivery. A rollback disables the receiver and keeps binding tables.

## Comma WeChat ClawBot

Owners create five-minute QR attempts with new IDs and optional pairing codes. Channels polls sequentially every 3s, with 15s timeouts.
Refresh retries activation; cancel/reconnect invalidate attempts. Retirement preserves previously active records only.
Comma owns references; Salix owns credentials/peers/cursors/lifecycle. Setup locks the Workspace; HTTP holds no DB checkout.
Activation rechecks authorization/references. Enablement requires persisted references and bot reservation. Disconnect retires current/pending connections.
CAS fences stale releases. Non-atomic S3 deletion requires reusable identity tombstones. Workspace migration preserves data.

Tencent's SDK needs OpenClaw's Node runtime; Elixir uses Req/OTP AES. QR URLs require approved WeChat HTTPS origins, without redirects.
Browser responses omit tokens and forbid caching. Only the scanned account's private messages enter its Workspace, never groups.

Before staging, IM Connect stores one batch, limited to 100 messages/1 MiB. Oversized batches cannot advance the cursor.
Polling drains pending heads before fetching. Revision CAS advances after Router admission or a product-command reply; the final head commits the cursor.
Completed receipts skip downloads; legacy receipts replay through Router source-ID deduplication. Exit cannot complete unfinished receipts.
A 30s lease reduces concurrency, not delivery authority. Stale workers may replay, but cannot advance newer state/context.
After exit, polling resumes after lease expiry. Passes repeat 5s after completion; outages delay recovery.
Pending inputs survive restart/deployment. Older binaries cannot drain them; use forward repair.

Current text/transcripts supply authority, never quotes. Text/image/file/voice/video quotes parse once, without recursion.
ID-only quotes resolve observed inputs/replies within one connect/peer: 10 direct items, 4 exact reads, no scans.
Quotes have a 64 KiB limit and seven-day logical expiry, not physical deletion. Missing originals stay explicit, without summary substitution.
Quotes grant no Message/delivery authority or unobserved-history access.

Direct/quoted media share staging/Blob/VFS: four attachments, 10 MiB plaintext each. Unsupported items/failures stay explicit.
Downloads share a 15s soft budget, checked before requests/at chunks. Receive waits use remaining time; Blob/VFS time is excluded.
CDN connections time out after 5s, without credentials/redirects. One transient HTTP/transport retry shares the budget; total wall time is unbounded.
CDN URLs/keys stay private; path hashes confer no authority.
Peer authorization precedes staging and Session admission. Raw voice/video need tools; receipts prove neither transcription nor understanding. Outbound quote bubbles remain unverified.

Inline image syntax is removed; use `reply_image` for visible images. Native media uses `reply_image`/`reply_file`/`reply_video`.
Video uses VFS/AES/CDN with mp4/mov/webm/mkv/avi paths, without transcoding or playback guarantees.
Captions are separate; media failure can follow a successful caption.

No drafts or status text leave.
Each peer actor keeps tickets/32 source IDs, refreshes at most every 4s, and stops after 30min or 60s idle.
Ticks check connection/Router ownership without cancelling started HTTP. Connect/response timeouts are 2s, without retries. Presentation failure cannot reject input.
Fixtures/deployment prove neither live delivery nor model understanding.

## Telegram OIDC transport

OIDCC owns the OIDC flow. Discovery and JWKS reads retry once on a transport failure. Token exchanges never retry: codes are single-use.
Exhausted requests emit `telegram_oidc_transport_failed` without URLs, credentials, bodies or raw exception messages. Events prove neither alert coverage nor recovery.

## Telegram questions and replies

`question.request` sends a native question in the current authorized Telegram chat: inline buttons for choices, else a text reply.
Delivery ends the activation. The answer becomes a new input without polling. A chosen card shows the answer without buttons. Repeated callbacks enqueue nothing.

Untargeted replies and questions quote the source message. Explicit targets stay unchanged. Answers quote the card or typed answer.
References use Telegram IDs, never Salix or guessed IDs. Automatic references allow delivery without the original in the same request. Comma never retries ambiguous sends without their reference.

## Telegram location requests

Comma Telegram neither discloses nor executes `location.request`: it returns `location_request_unavailable` before database lookup or button dispatch, also for old disclosures. Ask for a city in text instead.
User-sent locations, answers to earlier requests and internal host location are unchanged. The native button has not passed client acceptance.

## Voice calls

Twilio and `comma.voice.v1` calls enter `salix_voice`. GPT-Live delegates to the Group's Router, the only agent brain.

- **CallActor.** `SalixVoice.CallActor` owns the call’s profile, model, carrier, transcript, delegations, deadline and charge on its media node. State is not durable. When model and carrier are ready, it greets and sends the Router `voice.call_started`, so the Router can speak first. `voice.call_ended` gives the reason and open delegations.
- **Media.** Mu-law 8 kHz or PCM16 24 kHz (WebSocket only) passes without transcoding. Until GPT-Live starts, the actor keeps the newest 2 s of caller audio. Barge-in drops queued playback.
- **Delegation bridge.** 300 ms after `session.delegation.created`, the Router gets the caller transcript to its offset and the agent's last sentence: `provider=voice`, `chat_id` the call ID, `message_id` the delegation ID, source ID `im_provider:voice:<connect>:<call>:<delegation>`. Writes go through `ConversationServer -> ConversationActor`.
- **Router tools.** `im_api.voice.say` speaks (`session.commentary.append`) and answers any delegation. `voice.note` adds quiet context (`session.thinking.append`). `voice.hang_up` speaks an optional farewell and ends the call within 10 s. Text is at most 16,000 bytes, in 1,800-character sentence chunks. IDs default to the voice source. The call must match the tool's Group and connect. An ended call returns public `voice_call_ended`: do not retry.
- **Reply deadline.** An unanswered delegation gets one quiet note at 20 s and one spoken apology at 90 s. These timers, not Lean kernel reply obligations, cover voice.
- **Authority.** A call is private to its caller; `voice.say` reaches only that call. A phone caller is a provider user of the voice connect; a WebSocket caller acts as its key's principal (the creator's authority).

### Limits, drain and billing

- One active call per Group in the cluster, else `busy`. If two calls race, the later `{started_at_ms, call_id}` ends with `busy`.
- `max_calls_per_node` calls per node, else `node_full`. `max_call_seconds` ends a call after a spoken notice.
- The carrier attaches within 20 s (Twilio) or 5 s (WebSocket); GPT-Live starts within 15 s after the [profile](#voice-profile). Otherwise the call ends. A stream closed before `start`, failed attach or final Twilio status ends it.
- Pod pre-stop runs `SalixVoice.Drain.drain/0` after readiness is withdrawn. New calls get `draining`. Live calls hear a notice and end within 5 s; at 8 s, drain ends the rest.

`BillingCore.VoiceMetering` authorizes at admission and before model start. Financial refusals start no model. End-of-call charges use the Group billing owner, `resource_kind: "voice"`, key `voice:<carrier>:<carrier call ID>`, and model/carrier seconds. Transport loss bills at least elapsed model time.
No voice prices are seeded; charges stay pending until backfilled. A Group without a billing owner gets no charge. The charge omits the key ID.
The `salix.voice.*` metrics use only `transport`, `reason` and `outcome` labels.

## Twilio admission

Public Twilio paths allow 600 requests a minute per peer address, 6,000 in total. Then:

1. `POST /v1/voice/twilio/{incoming,pin,status}` check `X-Twilio-Signature` over the public URL and exact POST parameters: 403 and no TwiML on failure, 413 over 16 KB.
2. `To` must be a platform line, and `From` a number bound on that line.
3. Full STIR/SHAKEN attestation (`TN-Validation-Passed-A`) passes. Other callers enter the number's PIN at `POST /v1/voice/twilio/pin`. Salix refuses a number without a PIN.
4. `SalixVoice.admit/1` checks drain, enablement, the OpenAI key, capacity and the Group's call.
5. Salix answers `<Connect><Stream>` to `/v1/voice/twilio/stream/<token>`.

After the signature check, Salix speaks each refusal, then hangs up.
A PIN has 4 to 8 digits, stored as a salted PBKDF2-SHA256 hash. `pin_max_failures` failures lock the number for `pin_lockout_seconds`. Success, or a new PIN, clears the count.

The stream token is an HMAC-SHA256 over call, connect, Group, `CallSid` and a 60 s expiry, keyed from the deployment credential root. An invalid token gets 404 before the upgrade.
At Twilio's `start` frame, the actor refuses a wrong or missing `callSid` and a second socket. At the end, Salix sends a best-effort Calls API hangup.

| Check | Threat | Authority | Verifier | Failure |
| --- | --- | --- | --- | --- |
| Twilio signature | Forged webhook starts paid calls or skips caller checks | Twilio auth token | `TwilioWebhook` | 403 |
| Stream token | Stream URL holder takes over or hears a call | Signed webhook, which alone mints tokens | `StreamToken`, `CallActor` | 404 or no attach |
| Voice key kind | Leaked inbound key opens billable sessions | Group API key store | `SalixWeb.Auth` | 401 |

Twilio and GPT-Live lack official Elixir SDKs; `Carrier.Twilio`, `TwilioClient` and `Model.GptLive` isolate the adapters.

## Caller numbers

Each voice Group has one `voice` IM Connect, elected by the `ProviderIdentity` reservation `voice:group:<group_id>`. It lists at most 20 verified numbers and delivers every call, WebSocket calls included.

A number is bound only after Twilio Verify approves an SMS code (10 codes per Group and 5 per number each hour).
Each binding reserves `voice:<carrier>:<line>:<e164>`, so a number on a line routes to one connect. A number held by another Group gets 409 `voice_number_in_use`.
Writers reserve before listing and release after removal. Removal ends the number's live call (`revoked`). Routing rereads the connect. A holder that no longer lists the number routes nothing, and another Group may take it after 60 s.

Salix routes: `/v1/runtime/agent-groups/:group_id/im-connects/voice` (`GET`, `POST numbers/verify-start` and `verify-check`, `DELETE numbers/:e164`, `PUT pin`).
Comma mirrors them at `/v1/comma/workspaces/:workspace_id/integrations/voice` for the default Group, without the connect or PIN hash.

## WebSocket voice API

`GET /v1/agent-groups/{group_id}/voice` returns readiness, `busy`, formats, limits and `sessions_url`. `GET .../voice/sessions` upgrades to one session with subprotocol `comma.voice.v1`.
Both need `Authorization: Bearer salix_vk_...` of the path Group, never a URL key. Before the upgrade: 401 for a bad key, 400 without the subprotocol, 503 while draining.
Text frames are JSON objects of at most 16 KB that name the message in `type`. Both sides ignore unknown fields and types. Breaking changes ship as `comma.voice.v2`.

| From | Message |
| --- | --- |
| Client | `session.start {audio_format, client, display_name?}`, first, within 10 s. Format `pcmu_8k` or `pcm16_24k` (little-endian mono). `client` is `name/version` |
| Salix | `session.started {call_id, audio_format, max_duration_s}` |
| Both | Binary audio, at most 16 KB per frame |
| Salix | `output.clear`: drop queued playback |
| Salix | `output.mark {name}`. The client answers `output.played {name}` at playback |
| Salix | `transcript {role, text, final}`, role `caller` or `agent` |
| Client | `session.end` |
| Salix | `session.ended {reason, duration_s}`, then the close |
| Salix | `error {code, message}`, `code` the integer close code |

| Close | Cause |
| --- | --- |
| 1000 | Normal end, deadline, or another reason named in `session.ended` |
| 4400 | Bad frame or order, or caller audio over 1.25x real time for 5 s |
| 4401 | Key disabled, deleted or expired, or its Group deleted |
| 4408 | No `session.start` in 10 s, no audio for 60 s, or no pong for 45 s |
| 4409 | The Group has an active call |
| 4410 | Client playback more than 2 s behind |
| 4503 | Draining, disabled, not configured, node full, or GPT-Live unavailable |

Salix writes agent audio at most 500 ms ahead of playback. Clients send paced silence while muted. v1 excludes browsers: they cannot set the header.
[`comma-voice`](../systems/voice/comma-voice/README.md) is the reference client and E2E driver.

## Voice agent API keys

A voice agent key is the `voice` kind of the Agent Group API Key record (`Salix.Control.GroupApiKeys`). It keeps hash-only storage, one-time plaintext, status, expiry, creator and principal rules.

| Property | Inbound key | Voice agent key |
| --- | --- | --- |
| Prefix | `salix_gk_` | `salix_vk_` |
| Opens | Router post-message, Loop events | Voice readiness and sessions only |
| Minted by | Comma, Salix dashboard, tenant API, Router `inbound_api` tools | Comma, Salix dashboard, tenant API |
| Cap per Group | 20 | 20, counted separately |

The prefix selects the kind before the hash lookup, and the stored kind must match. Routers cannot mint voice keys, so prompt injection cannot get a billable credential.
Rows default to `inbound`. Routes: Salix `/v1/runtime/agent-groups/:group_id/voice/api-keys`, Comma `/v1/comma/workspaces/:workspace_id/voice-api-keys`.
Disable, delete and Group deletion reach live calls via `:pg`: a spoken notice, then close 4401. A timer (reset on change) ends calls at key expiry. Sessions recheck it at start; no polling. Session start updates `last_used_at`.

## Voice settings

Platform settings are one JSON object at `ctl/system/voice.json`, managed at `/dash/voice` or admin `GET`/`PUT /v1/admin/voice/settings`, not env vars or `config.json`.
Writes use compare-and-swap. `openai_api_key` and `twilio_auth_token` are write-only: reads show `<field>_configured`, blank keeps, `clear_secrets` removes.
Defaults: `enabled` false, `gpt_live_model` `gpt-live-1`, `max_call_seconds` 1800, `max_calls_per_node` 50, `pin_max_failures` 5, `pin_lockout_seconds` 900. Other fields: GPT-Live URL (`wss`, or `ws` for loopback only) and voice, Twilio SIDs, `twilio_numbers` (platform lines), `public_base_url` (signed and published URLs).

## Voice profile

Before GPT-Live starts, `SalixVoice.Profile` asks Jev (`decide`) one `choice` question per template field: `language`, `reply_length`, `formality`, `small_talk`, `expertise`, `units` and `clock`. Each has `unknown`.
An answer counts at its field threshold, a 70% to 80% winning probability. The thresholds are not calibrated. Fixed sentences for counted answers extend the instructions and set the greeting language. No user or Jev text reaches GPT-Live. Nothing is stored.

`SalixAgent.RouterDecision` sends the newest 12 user and assistant texts of the Router session, 1,500 bytes each, within 12 KiB. `decide` is public egress. By owner decision, message IFC labels and the Group IFC policy do not filter this text. Without text, it sends nothing.
The profile runs when `decide` is configured and meters as `voice_profile`. After 2.5 s or a failure, the model starts with the base instructions.

## Voice verification

Fake GPT-Live and Twilio servers test the bridge, timers, races, revocation, drain, webhooks, PINs, media, close codes, key kinds and the profile deadline. A Jev fixture tests profile evidence. Comma Playwright mocks the API. Tag `comma_voice_cli` runs the Go CLI.
Live `gpt-live-1` runs (PCM16, mu-law) proved events, delegation, billed seconds and barge-in mid-run. Twilio, live call-start speech, multi-node calls and pricing are untested. The call cap, one-call rule, drain and Twilio rate limits need the independent availability-gate review. No TLA+ model covers calls.

## Signal

Register at `/dash/signal/register`. Keys persist before startup. Failures stay `registering`. A verified session resumes `registering` accounts for that number and service. Active numbers are refused.
Shared tenant number: `/dash/signal`, `PUT /v1/admin/signal/settings`. A tenant's active account overrides it for new claims.
A `signal` IM Connect binds up to 50 ACI or `group:<id>` peers. `signal:peer:<account>:<peer>` routes each peer to one Group.
Bind with `comma connect XXXX-XXXX`. Codes appear once, expire in 10 minutes, and work once. Store only SHA-256 digests (`signal:claim:<account>:<digest>`). Only a code holder binds. Unbound senders get no reply.
Bound messages, files, voice notes, reactions, edits and deletes enter the Router at least once as `im_provider:signal:<connect>:<sender>:<timestamp>`. Permanent refusals drop just that one.
Accounts accept ACI/PNI invitations. Joining initializes missing profiles and preserves named profiles. Membership does not bind chats.
`signal.*` tools reach only bound chats; replies and failure notices use `signal.send_message`. Bound peers' calls are Voice Calls. Unbinding ends them.
Routes: `/v1/runtime/agent-groups/:group_id/im-connects/signal`, `/v1/runtime/signal/number`, Comma `/v1/comma/workspaces/:workspace_id/integrations/signal`.

Calls require one TURN-over-TLS relay, with no UDP or direct ICE paths. TLS failure stops startup.
