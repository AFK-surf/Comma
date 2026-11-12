# Native Apple apps

The Xcode project contains iPhone/iPad, Watch, Watch widget, and Live Activity targets.
Use Xcode 27.1, Swift 6, and XcodeGen 2.44.1 for the current project.

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

Google login uses the existing client-core Google attempt, completion, account linking, and credential custody.
Set `comma.google_auth.ios_client_id` in the backend configuration to a Google iOS OAuth client for `surf.comma.ios`.
Use the matching bundle ID for another signed flavor. Web and desktop OAuth clients cannot replace the iOS client.
The server returns this public client ID with each nonce-bound attempt. The app needs no Google client secret.
AppAuth 2.0 handles the authorization code flow, PKCE, and token exchange through `ASWebAuthenticationSession`.
The callback uses the reversed client ID and `/oauthredirect`. The system session intercepts it for the initiating operation.
The app does not register a global Google callback handler or use an external-browser fallback.
Google Sign-In's public API has no operation cancellation method. AppAuth lets the core cancel a retired attempt's browser session.
Only one authorization runs per core login attempt. The adapter keeps no Google access or refresh tokens after completion.
The server validates Google's signature, issuer, iOS audience, nonce, and token lifetime before it issues a Comma session.
A cancelled attempt cannot install credentials. Existing accounts use the same Google identity and mailbox-verification rules as other clients.

Compile all targets without signing:

```sh
xcodebuild -project clients/apps/apple/Comma.xcodeproj -scheme Comma \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Run CommaTests from the Comma scheme on an iPhone simulator.
The sign-in and launch tests run the client core the app carries against a fake API in the test process.
They cover restoring the saved iOS account through a service outage and ending it after an explicit server rejection.
iOS follows [native session recovery](../../../docs/identity-security.md#saved-native-sessions). Startup does not require an online Session check before it shows cached data.
The Watch keeps its own client in `clients/packages/apple-core`. Run its transport and state tests separately:

```sh
swift test --package-path clients/packages/apple-core
```

[Client contracts](../../../docs/clients.md#native-apple-clients) define chat, Watch pairing, notification budgets, and verification limits.

In a wide window, main Chat uses the same trailing content column as Home. The existing Routines sidebar stays visible and interactive on the left.
Opening and closing Chat keeps that sidebar's scroll position. Narrow windows use the full Chat width.
Opening Chat from a Settings detail shows Routines beside Chat; closing it restores the Settings columns.

## Chat media

Chat shows available message images, video covers, and uploaded workspace media inline. A tap opens the viewer through the native zoom transition.
Attachments in one message share horizontal rows and wrap when the available width is full.
The native Close button uses Glass on iOS 26 and later. Duo places it in the right system column in either orientation.
The viewer pages through images and videos in loaded messages. A downward drag shrinks the viewer with the finger and returns to the current thumbnail.
Reduce Motion uses a crossfade. Pinch and double-tap zoom images. Failed reads permit retry.
Account or conversation changes discard the viewer.
Failed previews show the file name and a Play or file icon inside the original tile, without an extra file row.
A video opens from its Play tile even when its cover is unavailable.
The tile menu provides Retry and Open file actions. Open file downloads the message attachment and presents Quick Look.
Preview reads stop after 30 seconds and release their read slots, so a stalled request does not block later previews.

Video covers show a Play icon. The current video page plays with native AVPlayer controls. Paging away or closing releases the player; entering the background pauses it.
Videos use authenticated Core range reads, with at most 1 MiB per request and three concurrent requests per chat.
Sent images and videos with an attachment index use the message attachment source, which supports byte ranges.
Sources without range support retain Core's 10 MB whole-file limit.

Image and cover reads start for visible tiles and adjacent viewer pages only. Each chat permits three concurrent reads or decodes, separate from the video range limit.
Thumbnail and viewer decodes use at most 640 and 2,048 pixels per side. Their memory caches permit 24 MiB and 48 MiB.
Images use the existing 10 MB whole-file read limit.
These paths add no polling or history reads.
Descriptive attachments without a readable source keep their file labels.

Run `ChatImagePreviewTests` for source selection and bounded decoding.
Run `ChatVideoPlaybackTests` for native cover decoding, playback, range bounds, and account changes.
Run `ChatImageUITests` in the gesture fixture for native media identity, mixed paging, playback cleanup, dismissal and return.

## Mini Apps

The Apps tab lists the current Workspace's own, shared, and installed apps. Search reads this list without per-app requests.
The list follows its Core topic only while Apps is selected. A Workspace change loads that Workspace's list.
A second press on Apps returns to the list and clears its search. Home's search button opens Task search.
Chat Mini App cards show the name, summary, and deployed Version. A press opens that Version in the restricted container.
Cards do not start a WebView or make per-card requests while the transcript renders.
Router run links also open apps in the current Workspace.
The link uses the deployment's web origin and `/#/apps/<workspace>/<app>/run?version=<number>`.
Without a version, the server selects the running version.

Public `/a/<token>` links open a native Shared app page in the matching staging or production app.
A cold link waits for sign-in and stays open while the default Workspace loads.
Viewing and running a shared app do not require a Workspace or create an Install.
The member selects a Workspace before installation, then chooses live updates or the resolved Version.
An existing Install keeps its pinned Version when the member opens the link again.
The page observes only the selected Workspace's Install through one `miniApp` topic. It does not scan all Workspaces.
The shared run uses the Link access path. Open workspace app uses the Install and its server-selected Version.
Both paths use the same restricted iOS container and cloud approval.
Revoked, expired, disabled, and unavailable links show an error. The client does not retry installation automatically.
The link token stays in the host and Core. The frame does not receive it.

Installed app details and the Shared app page offer Uninstall with confirmation.
Uninstall removes only the selected Workspace's Install and grants. It preserves the app and its cloud data.
Account changes discard pending links and prevent old pages from sending commands.

The phone entitlements associate `app.comma.surf` and `app-staging.comma.surf`.
The web Worker serves JSON at `/.well-known/apple-app-site-association` on both domains, without redirects or authentication.
Its `applinks` entry names `D9AAN3VJK8.surf.comma.ios` and claims only `/a/*`.
This association selects the app for navigation. Server access checks still authorize every resolve, install, and run.
The native parser rejects a link from the other environment.
Hash-based Router links remain in-app routes, outside the Universal Links association.

Before release, deploy the merged web Worker through the normal mainline release flow.
Enable Associated Domains for the phone App ID and regenerate its development and distribution provisioning profiles.
Replace the phone profile in the existing TestFlight signing package before a signed release build.
Confirm that the signed application identifier matches the AASA entry, including the App ID prefix.
For a custom bundle ID or prefix, update the AASA entry before release.
Verify cold and warm link opens, sign-in continuation, revoked links, and the web fallback on a physical device.
AASA response tests and unsigned simulator builds do not prove deployed association, profile support, or physical-device handoff.

An app's detail page shows its Versions, build commits, and notes.
Owners can change visibility, create a share link, enable or disable the app, and make a ready Version live.
Preview and publish opens the selected ready Version. After it starts, the container offers Publish while its build review still matches.
The confirmation names the Version and visibility. The existing server path accepts the review and merges the previewed commit before publication.
A changed review requires a new preview. A server conflict stays visible. The client does not retry publication automatically.
The Version page can open the build Task over the main tabs.

A list follows one `miniApps` topic. Details follow one `miniApp` topic and at most one selected build through `chatView`.
The publishing container shares those topics for the same app and build. It adds no per-Version scans, timers, or polling.
Only the selected Version's build is observed. Management calls name the Workspace captured when the page opened.
An account or Workspace change dismisses the page and prevents its old model from sending more commands.

Mini Apps require iOS 18.4. That version adds the public WebKit delegate used to refuse HTML file pickers.
Older systems retain the other Comma features.
The host uses a nonpersistent WKWebView and the shared Mini App runtime in a sandboxed iframe with an opaque origin.
The runtime script hash admits the bundled runtime. It is a CSP source restriction, not an artifact signature.
CSP blocks direct network requests, form submissions, and nested frames.
The host blocks navigation and popups. It denies file pickers, media capture, and motion permission requests.

The WebKit bridge exists only in the main frame's named content world.
Only that frame can call it. It passes app operations to the Core session opened by the host.
App messages cannot select a session, Core method, grant, or confirmation.
The frame receives no credentials or native objects. Approved identity access returns only the service's pairwise viewer id, name, and avatar.
The iOS capability set also supports draft text, clipboard writes, HTTPS links, Task proposals, app-folder Drive access, and notifications.
Identity, app-folder Drive access, and notifications need separate approval unless an existing grant covers them.
Each external link and Task proposal needs a native confirmation. Draft text never sends a Message.
Device storage and Mac Calendar remain unavailable. Photo selection keeps its existing per-request confirmation.

The member approves cloud access before the host reads or runs the app bundle.
The prompt describes backend data, cloud storage, AI, search, and Workspace credit use.
This run approval does not claim to satisfy all App Store data-consent requirements.
This implementation is not a complete App Store submission.

One foreground container runs at a time. Startup waits at most 10 seconds for the frame handshake.
The shared runtime also bounds app script startup to 10 seconds.
The bridge admits at most eight concurrent calls and transfers bundle files in 48 KiB chunks.
The shared runtime bounds bundles to 2,000 files and 25 MiB. The Core retains its existing invocation rate and cache limits.
Back and background suspension cancel pending photo and host confirmations. Continue reuses the retained execution.
Complete close, account or Workspace changes, and WebKit termination release the session. The host does not replay calls after closure.

Run `MiniAppRuntimeTests` on an iOS simulator to exercise WebKit, Hermes, and an in-process fake API.
Run `MiniAppsManagementTests` for list subscriptions, card parsing, publication arguments, stale-review rejection, and native screen renders.
Run `MiniAppLinkTests` for deployment routing, sign-in continuation, installation selection, existing pins, and revoked links.
The runtime suite also runs shared-link resolution, installation, and removal through Hermes against the fake API.
These tests cover cloud calls, binary transfer, consent, isolation, unsupported operations, and session closure.
They do not prove physical-device behavior or App Store approval.

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
The source defaults to `main`. The backend defaults to `production`. Select `staging` to use the staging backend.
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
Both workflows select Xcode 27.1 through `DEVELOPER_DIR`.
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

## App Store listing

`AppStore/metadata` holds the listing text for each locale in the `asc metadata` layout.
`app-info/<locale>.json` has the name and subtitle. `version/<version>/<locale>.json` has the keywords, promotional text, and description.
Name the version directory after the App Store version that carries the change.
Apple accepts a new name, subtitle, keywords, or description only with a new version. Promotional text can change at any time.

The `es-MX` keywords include English terms because the United States storefront also searches that locale.
A listing locale does not add an app language. The app interface has English and Simplified Chinese.

Check the files, then preview the change. The preview does not write to App Store Connect:

```sh
asc metadata validate --dir clients/apps/apple/AppStore/metadata
asc metadata push --app 6817786267 --version 1.0.3 --dir clients/apps/apple/AppStore/metadata --dry-run
```

## iPhone account and Task management

These screens use the same client core calls and topics as the desktop client. Limits and timings are in the core and the Swift models.

Settings uses the desktop groups: Preferences, Work, System, Archived, Shared, and Advanced.
Comma holds Drive and System Files and Plugins, which have primary navigation entries on desktop.
Profile, Workspace, and account actions keep their separate sections. Archived Tasks also remains in the Home task menu.
In a wide window, opening a Settings page replaces Routines with the Settings list and shows the selected page beside it.
The same Settings list slides left as the detail pushes in from the right and Routines slides out. Returning reverses this motion.
The page keeps stable column insets during navigation. Reduce Motion removes the column travel.
The wide Settings detail uses the Back button to close both columns. Edge and content swipe-back gestures are disabled only at this boundary.
Narrow windows and nested detail pages keep native swipe-back gestures.
The columns follow Duo's hinge space. Returning to Settings or selecting another tab restores Routines.
Rotation keeps the open navigation stack, including nested pages and unsaved forms.
Plugins lists the catalog and opens browser authorization. Details manage connected accounts, account confirmation, and tool groups.
The list follows one catalog topic. Only the open detail follows its accounts and tools.
Plugin notices name their operation's Workspace. The phone ignores another Workspace's notices, including authorization links for the same plugin.
Authorization uses the core's existing two-minute budget. The phone adds no authorization timer.
Models manages accounts and selects independent Router and default Task models, thinking effort, and the account to use.
API keys stay in forms until submission or dismissal. Subscription login uses the existing device-code or pasted-code flow.
Router settings changes the name, reply style, and custom instructions.
Its read uses only the Router's Agent settings. A failed model catalog or profile service does not block these controls.
A conflicting instruction save keeps the local edit and shows the latest saved text before another explicit save.
One Router identity topic updates the current Workspace's chat label. It adds no polling.

Task details opens Files. Each explicit read loads at most 200 indexed attachments, with a manual next page.
Preview and Save or share download through the existing attachment owner and native file path.
Add to context stages the canonical attachment by reference and preserves the text draft. It does not send a message.
Account and Workspace changes retire these pages. Late results cannot open files, continue authorization, or update another Workspace.

Settings > Routines controls briefing sources, delivery time, automatic source enablement, and the owner's proactive messages.
Each save changes only the selected setting. Settings reads the existing recommendation topic once, with at most 12 sources.
Home keeps the existing generation polling. Settings > Usage shows credits, subscription status, cycle usage, and grant balances from the core's billing projection.
It refreshes on entry, foreground return, and pull to refresh. It adds no timer or purchase action.
Both pages use the existing Duo Settings columns. Resizing keeps the current page, and closing Chat restores those columns.
Both Settings columns use native navigation bars and the same title presentation as narrow windows.
The system places their titles and the Back action.

A settled chat turn offers at most four suggested replies. The first prompt also appears as the empty composer's placeholder.
A suggestion sends only its prompt and preserves draft text, files, and Routine tiles. Hardware Tab accepts it into an empty draft without sending.
Suggestions are read only while their chat is visible. They hide during a new turn or background suspension.
The existing core caches at most 32 turns and reads once per turn and locale.

The Task panel's plus button opens New task. Settings has no Task creation entry.
The form offers Comma cloud, coding, available sandboxes, and Workspace computers. Offline computers cannot start Tasks.
A glass capsule shows the selected environment between Close and the circular glass creation action in the sheet header.
The capsule opens a native menu with the available environments and Workspace computers.
The repository capsule opens a separate sheet with Close and Confirm actions. Selection stays local until Confirm.
The sheet lists the connected GitHub account and its organizations. Organization names filter as the member types.
An organization opens its repositories. Name searches run on the server after 300 ms without input and stay within that owner.
Each page has at most 100 rows. The list loads its next page at the bottom, without per-row requests or polling.
Branch and model capsules open native menus. The upper-right creation action uses an icon. It stays disabled until the Task can start.
Each environment shows its model choices. Coding requires a repository and supports branch selection.
Task details > Code review shows the repository, branch, diffs, commit comparison, execution history, and pull request controls.
Merge confirmation names the reviewed pull request number and head commit. The service rejects a changed head.
Each form keeps its creation key across retries. Repository and history pages load only when requested.

Settings > Drive and System Files lists the existing Core projection. System Files includes Router memory, instructions, and read-only skills.
The composer plus menu opens the same files for the current conversation. Preview uses Quick Look. Save and share use the native share sheet.
Drive selects one space and shows its immediate folders and files, with folders first.
The native navigation bar groups the space filter and new memory file action. Duo places this group in its side bar.
New memory files require the System Files space. The Drive availability note appears only for an empty, unfiltered directory.
The breadcrumb returns to any parent. Switching spaces returns to that space's root.
Search keeps matching files under their folders within the selected space.
The search field stays in the file list, above the breadcrumb.
The phone indexes each catalog update once. Folder navigation uses that index and adds no requests or polling.
Search filters the selected space's bounded, loaded Core catalog.
Each directory renders at most 100 rows per page. Files load no extra metadata until opened.
Memory and instruction saves name the version returned by their read. A conflict retains the unsaved text.
iOS has no local Drive node. Computer folder sync stays with the computer that owns that node.

Settings > Task requests manages incoming and sent requests, invitations, grants, approval modes, and linked chat accounts.
One scrolling page follows the desktop order: waiting requests, senders, request targets, sent requests, and linked chat accounts.
Section headers offer invite creation and acceptance. Each sender's more menu changes approval mode or revokes access.
An unused invite's menu copies its link or revokes it. Linked chat accounts retain their own automatic-accept switch.
Accept can use edited words and create a Task or send to the Router. Revoking access declines waiting requests.
Settings > Shared tasks lists active public links and opens their update, replacement, and revocation controls.
Voice settings offers voice preview, custom voices, caller verification, PINs, and API keys. Router API keys has separate controls.
One scrolling page follows the desktop order: Phone numbers, Calls, Voice agent API keys, and Status.
Number and key rows use more menus. Verification, custom voice creation, and key creation open native forms.
The voice picker opens a sheet with names, preset language and gender, custom descriptions, and separate preview buttons.
Preview does not change the selected voice. Closing the sheet stops playback and cancels the pending sample request.
Preview uses the native media audio session, so the Silent switch does not mute it. An active call disables preview.
The inline key list shares the page's voice subscription. Status reports server readiness without blocking the other sections.
Full key values stay in the creation page only. Explicit copies expire from the local pasteboard after two minutes.
Channels offers Telegram, WeChat, Signal, iMessage, and Linear connection flows. The Core owns their existing connection tracking.

Task actions > Remote browser opens that Task's agent browser. Task details offers the same action.
Portrait uses a sheet. Wide landscape places the browser beside the Task conversation and extends the panel across the remaining width.
The conversation keeps its column width. Fold spacing and safe areas keep controls clear of the hinge and system bars.
Closing the viewer restores the original Task panel width. Rotation keeps the browser viewer. Selecting another Task closes that viewer.
Router chat also offers its own browser control in its toolbar. Each entry reads only its conversation's browser.
The browser supports tabs, control handoff, taps, text, and navigation keys.
The existing Core bounds its input queue to 32 events. The page adds no polling.
My devices > View screen, and Simulators and devices, view a computer's screen and its devices over the mesh
(`iOS/Remote/PhoneMeshScreen.swift`): the Core opens the view, VideoToolbox decodes its frames, and each frame shown is
acknowledged. The station authorizes capture and control. Closing or backgrounding ends the view.
Compute resources offers only actions allowed by the server projection. Retry and deletion name the selected resource's generation.

A chat widget opens one isolated Dynamic UI runtime after a tap. It uses the shared card and Worker runtime.
The named WebKit content world owns the bridge. Generated content has an opaque iframe origin and receives only a bound MessagePort.
State saves retain the existing account-scoped 32 KiB limit. A proposal needs an explicit Add to draft action and a later send.
No generated widget can select a Core method or native capability.

The feature tests cover Swift models through Hermes and native credential custody against an in-process API.
Screenshot tests render the production pages with synthetic accounts and files, including dark mode and large text.
They do not verify real provider authorization, physical-device file sharing, or a remote computer's live screen.
Run PhoneMigrationTests, PhoneDesktopFeatureCoreTests, MiniAppRuntimeTests, and PhoneMigrationScreenshotTests for these paths.

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
- The iPhone app requests an App Store rating when the member accepts a third result: Mark as done, or a Task ended as Done.
  The request follows two seconds later, in the foreground only, and the next request waits 120 days.
  The count stays on the iPhone and applies to every account. Apple decides if the sheet shows, and TestFlight builds never show it.
  Run `ReviewPromptTests` for the count and the interval.
