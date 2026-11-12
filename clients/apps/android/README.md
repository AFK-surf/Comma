# Comma Android

The native Android client for Comma. It is written in Kotlin with Android Views.
This directory is a standalone Gradle project. Open `clients/apps/android` in Android Studio. It does not use the pnpm workspace.

Read [AGENTS.md](AGENTS.md) before you change code. The most important rule: every scrolling surface uses the `:scroll` module.

## Layout

| Path                 | Contents                                                                                                                                        |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `app/`               | The application. `src/main` is shipped code. `src/debug`, `src/fixtures` and `src/release` hold variant-specific sources.                       |
| `core/`              | The client core: the shared TypeScript core (`clients/packages/core`) in Hermes, and what it needs of the app. See [Client core](#client-core). |
| `scroll/`            | The scrolling module: list, page and strip containers, fling physics and overscroll. See [docs/SCROLL.md](docs/SCROLL.md).                      |
| `macrobenchmark/`    | Start-up and scrolling benchmarks for the `devBenchmark` variant.                                                                               |
| `scripts/`           | Release isolation check, scroll rule probe, internal packaging, asset generators.                                                               |
| `docs/`              | [Visual design](docs/DESIGN.md), [design foundation](docs/design-foundation.md), [scrolling](docs/SCROLL.md), [R8 and isolation](docs/R8.md).   |
| `version.properties` | The only source of `versionCode` and `versionName`.                                                                                             |

## Requirements

- Android 15 (API 35) or later on the device. The app compiles against API 37.
- A JDK to start Gradle. Gradle provisions the daemon JDK 25 from `gradle/gradle-daemon-jvm.properties`. Java bytecode targets 17.
- Android SDK Platform 37 and Build-Tools 37.0.0.
- Python 3 for the scripts.
- Node 24 and pnpm, with `pnpm install` done in the repository root. The `:core` module bundles the client core with them.
- Android NDK 27.2.12479018 and CMake 3.22.1. Gradle installs them when the SDK licenses are accepted.

Set the SDK location with `ANDROID_HOME` or with `sdk.dir` in `local.properties`. `local.properties` is not tracked. No other local setting is necessary for development builds, tests and lint.

## Client core

The app's session, main chat, tasks and account settings (profile, signed-in devices, Comma devices and their credentials, voice keys) come from the client core, the TypeScript core that the desktop and web clients use (`clients/packages/core`).
The `:core` module runs it in Hermes on a thread of its own (`clients/packages/core/native/engine.cpp`, shared with the iOS app, through `core/src/main/cpp/jni.cpp`).
The core asks the app for what only the app has (`CoreHost.kt`):

- requests to the Comma API. The app adds the bearer. The core never sees it (`SessionCustody.kt`).
- the databases, as SQLite files in the app's no-backup directory.
- the Google account chooser.

The app talks to the core with named calls and topics (`CommaCore.kt`).
Message drawing and the voice call (`VoiceSession.kt`) stay in Kotlin.
The core downloads media files (`downloads.start`, the `download` topic). The app writes the bytes from the network to the file (`HostDownloads.kt`).

The Gradle task `:core:bundleCore` compiles the core to Hermes bytecode with the Node tools of the repository.
Before the first build, run `pnpm install` in the repository root.
`node clients/packages/core/scripts/mobile-check.ts` starts that bundle in the Hermes release that the app carries.

## Build and test

Run these commands in `clients/apps/android`:

```sh
./gradlew --max-workers=2 test lint
./gradlew --max-workers=2 assembleDevDebug assembleStagingDebug assembleProdRelease assembleDevBenchmark
./gradlew --max-workers=2 :macrobenchmark:assembleBenchmark
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/verify-scroll-usage.py
python3 scripts/verify-release-isolation.py --dexdump "$ANDROID_HOME/build-tools/37.0.0/dexdump"
```

- `test` runs the unit tests of `:app` and `:scroll`.
- Every lint task first runs `:app:checkScrollUsage`. It rejects the system scrolling widgets in app sources and layouts.
- `verify-scroll-usage.py` makes sure that the check rejects forbidden sources.
- `verify-release-isolation.py` reads the built APKs and R8 mappings. It makes sure that release builds contain no fixtures, demo pages or measurement tools. See [docs/R8.md](docs/R8.md).

Use `--max-workers=2` when you compile several variants. With more workers, the Kotlin compiler can run out of memory.

The `Android Checks` job in `.github/workflows/client-checks.yml` runs these checks for changes in this directory. It also builds `stagingInternal` with a throwaway key that it makes for the run. It uses no production key or service credential and publishes no APK.

## Variants

| Flavor  | applicationId                | Backend                           |
| ------- | ---------------------------- | --------------------------------- |
| dev     | `surf.comma.android.dev`     | `http://10.0.2.2:8787` by default |
| staging | `surf.comma.android.staging` | `https://salix-staging.cue.surf`  |
| prod    | `surf.comma.android`         | `https://salix.comma.surf`        |

The app reads the address from `BuildConfig.BACKEND_BASE_URL`. Only dev allows clear-text HTTP. To change the dev address, use one of these settings. The first one that is set applies:

1. The Gradle property `-Pcomma.devBaseUrl=...`.
2. The environment variable `COMMA_DEV_BASE_URL`.
3. `comma.devBaseUrl` in `local.properties`.

Build types:

- `debug` contains the fixtures and demo pages. `devDebug` opens 1000 local messages. Add the boolean extra `login=true` to the start intent to test sign-in. Any debug variant accepts `fixtures=true` to skip sign-in.
- `release` uses R8 full mode with obfuscation and resource shrinking. It contains no fixtures and accepts neither extra.
- `benchmark` exists only for dev. It inherits the release optimization, uses local fixtures and is signed with the debug key.
- `internal` exists only for staging. See [Internal builds](#internal-builds).

## Versions

`version.properties` sets the production version and the base staging version name.
Staging CI sets its own `versionCode`: `1000000 + Client Checks run_number`.
Its version name also includes the source commit. A retry keeps the same commit and code.
The two package names have separate upgrade histories. Staging builds do not consume production version codes.

Before each production release:

1. Increase `versionCode` in `version.properties`. Do not reuse or lower a value.
2. Change `versionName` if the release needs a new name.
3. Commit the change.

### Automated releases

Android input changes on `main` publish a staging pre-release after the Android checks pass.
Shared client core, localization, dependency and Android build-tool changes count as Android inputs.
Documentation-only and unrelated platform changes do not publish a staging build.
Production uses the manual **Android Release** workflow on `main`, with public release notes.
It also submits that commit's internal Play version for production review.
Run it after that commit's mainline Client Checks run succeeds.
Staging publishes APKs only to the private source repository and does not sync public source.
Production publishes APKs to [public releases](https://github.com/AFK-surf/Comma/releases).
Staging tags select the original source commit and do not change Latest.
Production tags select the matching public source snapshot.
Published APKs and tags are never replaced. A failed draft can resume on a rerun.

CI signs each environment with a separate fixed key after compilation.
Each environment has one ZIP containing `signing.jks` and `signing.properties`, including all signing settings and passwords.
Save the ZIP as a 1Password attachment. 1Password encrypts the backup; the ZIP needs no separate password.
Keep these complete signing bundles outside Git. GitHub cannot return the saved secret values.

Local internal packaging below uses the file's version code and its configured local key.
To update a CI-installed staging app, use a newer CI build with the same staging signing key.

## Google Play

Client Checks also builds a production AAB for each mainline staging release.
To upload without Android input changes, run **Client Checks** manually with `main` selected.
Wait for that run to succeed before you run **Android Release** on the same commit.
Android Release signs it with the production upload key and uploads it to Play internal testing.
It uses `surf.comma.android` and the production backend. The staging APK keeps its existing package and backend.
The Play AAB uses `1000000 + Client Checks run_number` as its version code.
`version.properties` still owns the version name and the production APK version code.
Use the same Play version code for internal testing and production review. A production submission promotes the existing internal bundle.

The publisher uses Google's Python SDK and Application Default Credentials.
Install `.github/scripts/android-play-requirements.txt` before use.
`android_play.py upload-internal --artifacts android-artifacts` uploads the production AAB to the internal track.
`android_play.py submit-production --version-code CODE --version-name NAME` submits that internal version for production review.
Set `ANDROID_RELEASE_NOTES` for production submission. Google Play controls review, approval and availability.
Managed publishing, when enabled in Play Console, controls when approved changes become public.
The publisher does not change that setting or save a rejected submission as an unsent draft.

CI publishing requires these account settings:

1. Enable the Google Play Android Developer API in the selected Google Cloud project.
2. Create a dedicated Play publisher service account.
3. Restrict GitHub OIDC to `AFK-surf/Cue`, `refs/heads/main`, and the `android-production` Environment.
4. Grant that account app-scoped access to `surf.comma.android` in Play Console.
5. Grant testing release and production release permissions for that app.
6. Set `PLAY_WORKLOAD_IDENTITY_PROVIDER` and `PLAY_SERVICE_ACCOUNT` in GitHub's `android-production` Environment.

Use the existing production upload signing bundle in that Environment. Do not export a service account private key.
Complete Play's store listing, policy declarations and production access requirements before the first production submission.

## Internal builds

`stagingInternal` is the build for colleagues. It connects to staging and keeps the package name `surf.comma.android.staging`. It inherits the release configuration. It is not debuggable and contains no test data, demo pages, frame telemetry or JankStats.

### Signing key

The internal build signs with a fixed key. The key must be outside this Git repository, not only outside this directory. The default location is `~/.comma-android/internal.keystore`.

To make the key one time, run:

```sh
scripts/create-internal-keystore.sh
```

The script makes an RSA 4096 JKS key that is valid for 25 years. It does not overwrite a key that exists. It shows a random password one time. Save the password in a password manager immediately, and keep a backup of the keystore. All later internal builds must use the same key.

Set these four values in the environment or in `local.properties`. Environment variables have priority:

```properties
# Optional. A custom path must also be outside the Git repository.
COMMA_INTERNAL_KEYSTORE=~/.comma-android/internal.keystore
COMMA_INTERNAL_KEY_ALIAS=comma-internal
COMMA_INTERNAL_STORE_PASSWORD=<from the password manager>
COMMA_INTERNAL_KEY_PASSWORD=<the same password>
```

Make `local.properties` readable only by you (`chmod 600 local.properties`). Do not put passwords in command arguments, logs or version control. Without a complete signing configuration, the internal build stops with an error. It never uses the debug key. Other builds, tests and lint do not need the key.

### Package

```sh
scripts/build-internal.sh
```

The script builds `:app:assembleStagingInternal`, verifies the signature with `apksigner` and runs the release isolation check. Then it writes these files to `dist/`:

- `comma-staging-<versionName>.apk` and its `.sha256` file.
- `comma-staging-<versionName>-mapping.txt`, the R8 mapping for crash stack traces. Keep it with the APK of the same version.
- `CHANGELOG.txt`, the subjects of the commits in this directory since the previous internal build.

The internal `versionName` is the `versionName` from `version.properties`, then the short commit SHA. If this directory has uncommitted or untracked changes, the name also ends with `-dirty`. Changes in other directories do not make a build dirty.

Each successful build records HEAD with the local tag `android-internal/<versionCode>`. The script does not push tags and does not move a tag. It stops if the `versionCode` already tags a different commit, or if an earlier internal tag has a higher `versionCode`.

Send the APK and its SHA-256 file to colleagues. If a device has a staging build with a different signature, uninstall it before the first install. This deletes the local data of that package. The script does not install, upload or push anything.

## Chat

A settled chat turn offers at most four suggested replies as chips after its last row. The first prompt also appears as the empty composer's placeholder.
A chip sends only its prompt (`consumeDraft: false`) and keeps the draft's text and files. A hardware Tab puts the first prompt into an empty composer without sending it.
Suggestions are read only while their chat is on screen and the app is started. A send, a reply in progress or an archived conversation hides them.
The core reads once per turn and language and keeps at most 32 turns (`chatSuggestions`).

Chat shows message images and video covers inline, one fixed-size card per attachment.
A tap on a loaded image or on a video's Play button opens the viewer, which grows out of the card.
A tap on a card that is still loading does nothing, so its read continues.
The viewer pages through the images and videos of the loaded rows, at most 100 on either side of the opened one.
Paging reveals the current page's card in the chat. A downward drag or Close returns the page to that card; when the card is not on screen, the viewer fades.
With animations off, the viewer opens and closes without the zoom.
The current video page reads its whole file through the core's download and plays it with the single player. Paging away, closing or leaving the app releases the player.
A failed image keeps its card size and shows the file name. A tap retries, or opens a message's own attachment in another app.
A long press offers Retry while the card has no picture and Open file for a message's own attachment.

## Mini Apps

The Apps tab lists the current Workspace's own, shared and installed apps. Search reads this list. It makes no request per app.
The list follows its core topic (`miniApps`) only while Apps is shown. Another account or Workspace starts the tab again from its list.
A second press on Apps returns to the list and clears its search.
Chat Mini App cards show the icon, name, summary and deployed Version. A press opens that Version in the restricted container. Cards start no WebView.

Public `/a/<token>` links open the Shared app page in the matching staging or production build. A link that arrives before sign-in waits for it.
Viewing and running a shared app create no Install. The member chooses a Workspace, then live updates or the resolved Version, and installs.
The page follows only the chosen Workspace's Install through one `miniApp` topic. Uninstall removes only that Install and its grants.
A link of the other environment shows an error.
The token stays in the app process and the core. The frame does not receive it.

The manifest claims `/a/` on `app.comma.surf` (prod) and `app-staging.comma.surf` (staging) with `autoVerify`.
Verification needs `/.well-known/assetlinks.json` on those hosts with the release signing certificate's SHA-256 fingerprint.
Until the Worker serves it, Android opens these links in the app only when the member enables them in the app's link settings.

An app's details show its cover, Versions, build commits, notes and screenshots.
Owners change visibility, create a share link, enable or disable the app, and make a ready Version live.
Preview and publish opens a ready Version. While its build review still matches, the run screen's menu offers Publish.
Publication accepts the review and merges the previewed commit through the existing server path. A conflict stays visible. Nothing retries automatically.
Details follow one `miniApp` topic and at most one selected build through `chatView`.

The run screen (`MiniAppActivity`) uses `platform: "android"`. The core gives it the same capability set as iOS:
AI chat and decisions, web search, cloud storage, the app backend, confirmed photos, draft text, clipboard writes,
HTTPS links, Task proposals, app-folder Drive access and notifications. Device storage and Mac Calendar stay unavailable.
Identity, app-folder Drive access and notifications need a separate approval in the host dialog unless a grant covers them.
Each link and Task proposal needs its own confirmation. Draft text goes to the router chat's composer and never sends a message.
Approved identity access gives the frame only the viewer's id, name and avatar.
The member approves cloud access before the host reads or runs the bundle.

The host page and the shared runtime run in a WebView at a private origin. The app runs in a sandboxed frame with an opaque origin.
Android's WebView has no isolated script world. So the app gives the host page one `MessagePort` with `postWebMessage`, aimed at the host origin only.
The frame cannot receive or replace that port. The app does not use `addJavascriptInterface`, which every frame could reach.
The WebView refuses every network request except the host script, which the app serves from its assets (`mini-app-host.js`, built by `:core:bundleCore`).
It refuses navigation, new windows, file choosers, permission requests and JavaScript dialogs. It keeps no DOM storage.

Startup waits at most 10 seconds for the host page. The bridge admits at most eight concurrent calls and sends bundle files in 48 KiB chunks.
`files.pick` opens a confirmation sheet with the system photo picker and the camera. The host re-encodes each photo as JPEG or PNG
at most 2048 pixels on the long side, without metadata. Bounds: six photos, 4 MiB each, 8 MiB total.
Back suspends a run that can continue; Run then shows Continue. Close, account or Workspace changes, uninstall and disable end it.
Memory pressure releases suspended runs. Leaving the app suspends the run and cancels a pending photo or host confirmation. Nothing replays after a close.
A call the server completed while the run was suspended still reports its result. Only the device side effect of a host operation waits for the foreground.

## Dynamic UI

A chat widget shows as a card with its summary. A press opens one isolated runtime in a full-height sheet. Closing the sheet destroys it.
The sheet reads the widget through the `dynamicUi` topic and its saved state through `dynamicUiState`. It uses the shared card and Worker runtime.
The host page (`dynamic-ui-host.js`, built by `:core:bundleCore` from the iOS host's shared code) runs at a private origin.
The widget runs in a sandboxed frame with an opaque origin and the runtime's CSP. It receives only a `MessagePort` bound to that frame.
The app gives the host page its own `MessagePort` with `postWebMessage`, aimed at the host origin, as for Mini Apps. The frame is created after that port arrives.
The page forwards only runtime messages of the iOS types, each at most 40,000 UTF-8 bytes. The app checks them again (`DynamicUiFrame`).
A proposal needs an explicit Add to draft and a later send. A link must be HTTPS without credentials and needs a confirmation.
State saves keep the 32 KiB limit; only the latest value of each kind waits. No widget can select a core method or native capability.
The main frame loads only the fixed page. The WebView refuses navigation, other requests to the private origin and non-HTTPS requests.
A widget may load HTTPS images, styles, fonts and scripts, as on iOS.

## Settings

Settings uses the desktop groups: Comma, Preferences, Work, System, Archived, Shared and Advanced.
Comma holds Drive and System Files and Plugins. Profile, Workspace and account actions keep their own sections.
The Workspace pages use the same client core calls and topics as the desktop and iOS clients.
Each page belongs to the account and Workspace it opened in. After a change, Settings returns to its list.

In a window at least 840 dp wide and 480 dp high, the list stays in a leading column and pages open beside it.
A page opened from the list replaces the page beside it. The first page beside the list leaves with back,
but it does not follow the back gesture. Narrow windows stack the pages.

Drive indexes each catalog update once. Folder navigation makes no requests. A directory shows at most 100 rows per page.
Files that are not text open in another app through a private, read-only link. Memory and instruction saves name the version that was read.
Voice samples play as media and never select a voice. Closing the picker, leaving the app or a call stops a sample.
A new API key's value shows only until its page closes.

My devices > View screen, and Simulators and devices, show a computer's screen and its devices over the mesh: the
core opens the view, MediaCodec decodes its frames onto a surface, and each frame shown is acknowledged.
Leaving the page or the app ends the view.

## Performance

`devBenchmark` is profileable and not debuggable. `:macrobenchmark` measures start-up and scrolling.

```sh
./gradlew --max-workers=2 :app:assembleDevBenchmark :macrobenchmark:assembleBenchmark
./gradlew :macrobenchmark:connectedBenchmarkAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=surf.comma.android.macrobenchmark.ConversationBenchmarks
```

## Credentials and local data

The app encrypts session credentials with a 256-bit AES-GCM key in the Android Keystore. It writes them atomically to the app's no-backup directory. Credentials are not written to logs, exception messages, saved UI state or `BuildConfig`. Each account has its own cache directory. Sign-out and account changes clear the local credentials and caches.

## Licenses

Comma's original code is licensed under AGPL-3.0-only. See the repository [LICENSE](../../../LICENSE).
Third-party code, fonts and icons keep their own licenses:

- [NOTICE](NOTICE) lists the Apache-2.0 code in `:scroll`. The source files keep their original headers.
- `app/src/main/assets/licenses/` holds the license texts that ship in the app, including Inter and the KaTeX fonts (OFL).
- `IconSources` (`app/src/main/java/surf/comma/android/ui/icons/IconSources.kt`) records the source and terms of every licensed icon and brand mark.
