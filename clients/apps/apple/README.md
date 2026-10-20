# Native Apple apps

The Xcode project contains iPhone/iPad, Watch, Watch widget, and Live Activity targets.
Use Xcode 27.0, Swift 6, and XcodeGen 2.44.1 for the current project.

The iPhone app runs the shared client core (`clients/packages/core`) in Hermes, as the Android app does.
Its build compiles the core to Hermes bytecode with the repository's Node tools. Install them first:

```sh
pnpm install --filter '@comma/core...'
pnpm --filter @comma/i18n compile
```

Generate the project from the repository root. Generation fetches React Native's prebuilt Hermes for iOS into
`Vendor/hermes` (`scripts/fetch-hermes.sh`), at the version the Android app uses:

```sh
xcodegen generate --spec clients/apps/apple/project.yml
```

Open `Comma.xcodeproj` in Xcode. Select the Comma or CommaWatch scheme.
Select your development team before a device build.
Debug and Release use `surf.comma.ios` with the staging backend by default.
Development signing uses the APNs sandbox. TestFlight and App Store distribution use APNs production.
One bundle ID does not combine the two APNs environments.
The staging and production backends can share an APNs production key for `surf.comma.ios`.
Xcode development installs still need APNs sandbox credentials.
Debug and distribution installs replace each other because they share the same bundle ID.
Override `COMMA_PHONE_BUNDLE_ID`, `COMMA_API_BASE_URL`, `COMMA_APP_NAME`, and `COMMA_PUSH_ENVIRONMENT` for another signed flavor.
Use `production` for a distribution push entitlement.
Apple login and APNs require the matching server configuration in [Identity and security](../../../docs/identity-security.md#native-apple-credentials).

Compile all targets without signing:

```sh
xcodebuild -project clients/apps/apple/Comma.xcodeproj -scheme Comma \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Run CommaTests from the Comma scheme on an iPhone simulator.
The sign-in and launch tests run the client core the app carries against a fake API in the test process.
The Watch keeps its own client in `clients/packages/apple-core`. Run its transport and state tests separately:

```sh
swift test --package-path clients/packages/apple-core
```

[Client contracts](../../../docs/clients.md#native-apple-clients) define chat, Watch pairing, notification budgets, and verification limits.

## Watch voice calls

Home's Voice call button and the Comma complication open the same real-time call.
The complication uses `comma://call` and holds no credentials.
Cold launches wait for foreground authentication and Workspace restoration.
The Apple apps must support mainland China App Store distribution and must not use CallKit.
The Watch uses VoiceSession and CallAudio after microphone permission.
Long-call stability and wrist-down behavior remain unverified on a physical Watch.
Watch uses HTTPS in Debug and Release. iOS keeps its WebSocket transport.
Do not treat simulator networking or successful builds as proof of physical Watch VoIP support.
The `surf.comma.watch` voice-call logs report audio and protocol failures without credentials or transcripts.
Repeated entry opens the current call. Account or Workspace changes stop the call.

Run WatchCallTests with the CommaWatch scheme on a Watch simulator.
Verify duplex audio, wrist-down continuity, and complication launch on a physical Watch.
Simulator tests do not verify these hardware behaviors.

### HTTPS voice transport

Watch uses the authenticated voice endpoint's origin and Group path in Debug and Release.
Staging accounts call staging. Production accounts call production. No Mac, tunnel, CallKit or iPhone relay is required.
Deploy the merged server release before installing the new Watch client.
The routes run in `salix_web` on its normal listener and ship in the standard server image.
The Salix GKE backend timeout covers the configured four-hour maximum call duration plus termination time.
No separate proxy deployment or new secret is required.

`POST /v1/agent-groups/:group_id/voice/http` opens a streaming response.
The content type is `application/x-comma-voice`. Each frame has a one-byte type and a four-byte big-endian length.
Payloads are at most 16 KiB. Types 1/2 carry the existing JSON/audio protocol.
Type 3 contains `{handle, node}`. Type 4 contains `{code, reason}`. Type 5 is a heartbeat every 15 seconds.
The handle is a temporary transport locator. The node is an opaque routing hint, not authority. It does not show the node name.

`POST .../voice/http/:handle` accepts at most 32 KiB of complete type 1/2 frames.
Every request includes the original voice key, `X-Voice-Node`, and a zero-based `X-Voice-Sequence`.
The first request validates the voice key and its tenant/Group. Continuations must match that original key hash, Group and next sequence.
Wrong scope returns 404. Duplicate, out-of-order or concurrent uploads return 409. An unavailable owner returns 503.
The route forwards to only the named connected cluster node. It never creates a replacement call.
A draining pod still forwards uploads and `DELETE`, because any pod can receive them while endpoints propagate.
These checks prevent another key from injecting audio or ending a call, and prevent duplicate media execution.
The authenticated key store record supplies the expected SHA-256 key hash. The stream owner compares it in constant time.
This reuses the existing credential hash. Continuations perform no database read. CallActor still ends calls on revocation, expiry or Group deletion.

One stream process owns the VoiceSocket session state and attaches to the existing CallActor.
The `websocket` carrier value remains the existing comma.voice.v1 billing identity for both HTTP and WebSocket framing.
Voice close logs show `transport=https` or `transport=websocket`.
The Registry holds only transient routing scope and a one-upload lock, removed when the request process exits.
The owner releases that lock after processing. An RPC timeout never releases it or retries an unknown outcome.
`DELETE` does not wait for the lock, so a hang-up is not refused while a cancelled upload is processed.

The client batches microphone frames for about 100 ms and permits one upload at a time.
Queued plus outstanding data is bounded to 32 KiB, with 4 KiB reserved for controls.
The pacer skips new microphone frames under congestion. Sustained congestion can lose speech.
The client ends after a five-second upload timeout or 45 seconds without downlink data.
Uploads update carrier liveness. Empty uploads cannot extend it. The existing 60-second audio idle limit remains.
`DELETE .../voice/http/:handle` explicitly closes the carrier with the original key and node header.
A broken downlink ends the call when the next write fails. Bandit bounds blocked writes and HTTP/2 flow-control waits.
Calls do not resume after node loss. The user starts a new call.

The call page has no transport diagnostics. Device logs identify open, upload, downlink, idle and decode failures.
No media or voice key enters those logs. Existing HTTP metrics and voice lifecycle metrics cover the new routes and calls.

Run `VoiceSocketTest` for both carriers, and the optional `voice_swift_http` test for Swift-to-Salix transport.
Before a release, test the deployed HTTPS entrypoint on a physical Watch:

1. Confirm duplex audio, playback and interruption while Comma speaks.
2. Keep a call active for more than one minute.
3. Repeat with the iPhone locked, then with the Watch wrist down.
4. Mute, unmute, end and start another call. Confirm the old call releases the Group.

Local protocol tests and builds do not prove hardware background execution or the deployed proxy's streaming behavior.

## TestFlight

Use GitHub Actions > iOS TestFlight > Run workflow. Keep the workflow branch on `main`.
The workflow uses release scripts from `main`. Set `source_ref` to `main` or a tag whose commit is already on `main`.
Other branches, commits, and tags outside `main` are rejected before checkout, because selected-source build code runs while signing credentials are present.
The source defaults to `main`. The backend defaults to `staging`. Select `production` to use the production backend.
This choice changes the app API URL. It does not deploy either backend. Both choices use APNs production.

Select `version_bump`: `none` (default), `patch`, `minor`, or `major`.
The baseline is the highest version among iOS TestFlight versions, recent pending uploads, and the selected project's version.
The workflow compares numeric components and normalizes two-component versions: `1.0` becomes `1.0.0`.
For a `1.0.2` baseline:

- `none` keeps `1.0.2` and increments only the build number.
- `patch` selects `1.0.3`.
- `minor` selects `1.1.0`.
- `major` selects `2.0.0`.

The build number increments separately, including pending uploads. It is shared by the phone, Watch, and Live Activity.
Local builds use `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from `project.yml` and the generated Xcode project.
The local marketing version is `1.0.2`. The local build number remains a development baseline.
TestFlight builds override both values in a temporary project. The workflow does not commit version changes.
After a TestFlight version bump, update `project.yml` and regenerate the Xcode project to keep local marketing versions equal.

The `ios-testflight` GitHub environment requires one secret: `IOS_TESTFLIGHT_CONFIG`.
It contains Base64-encoded gzip JSON with the app identifiers, API key, signing files, and tester group.
Separate GitHub Variables are not required. The configuration helper checks GitHub's 48 KiB secret limit.

Put these files in a private directory:

- `api.p8`: the App Store Connect API private key.
- `distribution.p12`: the Apple Distribution certificate and private key.
- `p12-password`: the P12 export password.
- `app.mobileprovision`, `activity.mobileprovision`, `watch.mobileprovision`, and `watch-widgets.mobileprovision`: the four App Store profiles.
  The Watch widget profile uses `surf.comma.ios.watch.widgets`. Repack `IOS_TESTFLIGHT_CONFIG` when adding this profile.

Create the package. The output file must not already exist:

```sh
python3 clients/apps/apple/scripts/testflight-config.py pack \
  --signing-dir /path/to/private-signing-files \
  --issuer-id YOUR_ISSUER_ID \
  --output /path/to/private-signing-files/testflight-config.b64
```

Store that file's contents in `IOS_TESTFLIGHT_CONFIG`. Keep the package private and outside Git.
Rebuild and replace the secret when the API key, certificate, profiles, or configuration change.
The current App ID is `6817786267`, Team ID is `D9AAN3VJK8`, and API Key ID is `3WNBU47WU9`.
The internal tester group is `Internal Testers`. Its members must have App Store Connect access.
These values are the pack command's defaults. Use `--app-id`, `--key-id`, `--team-id`, or `--group` to override them.
The helper masks constituent credentials and gives each child process only its API or signing credentials.

The unsigned CI build and TestFlight release use self-hosted Tartelet runners in the default group.
Both workflows select Xcode 27.0 through `DEVELOPER_DIR`.
The workflow installs XcodeGen 2.44.1 and ASC 2.6.0.
CI controls the toolchain. The configuration package supplies App Store Connect and signing settings.

The workflow runs the selected source's Apple core tests, then archives and exports the Release app.
If the first archive fails before product build tasks, it can retry once.
All errors must report missing profiles for the supplied team and profile IDs.
The retry uses the same signing inputs.
Other archive errors and a failed second attempt stop the release. Both attempt logs are retained.
The P12 file is deleted right after import, and only `codesign` may use the imported key without a prompt.
Temporary signing files and the temporary keychain are removed after the build.
The release summary records the version, build number, and Apple build ID.
New releases also record the requested source commit and backend.
Artifacts retain the IPA, dSYMs, and logs for 14 days. The frozen release context and upload marker remain for 90 days.

Use Re-run jobs after a failure. The retry keeps the resolved version, build number, and source commit.
Before saving the upload marker, the workflow checks Apple for an existing build or pending upload with the same version and build number.
A number conflict stops the run before the marker. Start a new manual run or select the existing build with `resume_build_id`.
Before upload, the workflow saves an immutable upload marker. The first attempt uploads this run's IPA.
A retry after that marker reconciles Apple's matching build. Its source and backend are unverified.
The frozen source and backend remain request metadata for that retry.
It never assumes that a timeout means Apple rejected the upload. Processing and discovery waits have a 20-minute budget each.
If Apple has not exposed the build, the retry reports an unresolved outcome. Retry later to reconcile the same build.
If the earlier attempt stopped after the marker but before its upload began, Apple never receives a build. Start a new release.
Set `resume_build_id` to distribute an existing iOS build without another archive or upload.
Keep `version_bump` at `none` when resuming. The existing build retains its version and build number.
The summary labels that build's source and backend as unverified.
Publication only adds builds to the internal group. It does not submit an App Store version.
Only one release runs for this App ID at a time. GitHub may replace an older pending run after another manual dispatch.

## iPhone account and Task management

These screens use the same client core calls and topics as the desktop client. Limits and timings are in the core and the Swift models.

- Archive and restore send the listed `updated_at` as `expected_updated_at`. The server refuses a stale copy.
- The status in Task details offers Done or Cancelled for an in-progress or in-review Task. The Watch shows the same two actions.
  Both send the open Task's `updated_at` as `expected_updated_at`.
- Worker history opens no event stream, so the open Task keeps the limit of two foreground streams.
- Routines show on Home as platform cards, one per connected app. Tapping a pre-task stages its prompt as a tile in the
  router composer. Holding the tile offers "Show in Text Field". The member sends it, and the tile goes as an attached text
  (`chatView.send` `attachedTexts`). A new briefing is an explicit request from a card's menu.
  Provider marks are vector assets in `Resources/Assets.xcassets/ProviderLogos`.
- An @ mention reads `@Title` in the field and is sent and saved as the desktop's `[Title](comma:task/<id>)`.
  A skill inserts `/<skill_id>`, and the send carries `skills: [{location}]`, at most 10.
  `per-message` miniskills are not listed. A command reads `/command` in the field and is sent and saved as
  `<salix-command>command</salix-command>`. Sent bubbles show it as `/command` again.
- Settings > Signed-in devices signs out one other device or all other devices. Use Sign out for this device.
