# Native Apple apps

The Xcode project contains iPhone/iPad, Watch and Live Activity targets.
Use Xcode 16 or later, Swift 6, and XcodeGen 2.44.1 or later.

Generate the project from the repository root:

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
Changes remain local until the normal repository release flow deploys their backend.

Compile all targets without signing:

```sh
xcodebuild -project clients/apps/apple/Comma.xcodeproj -scheme Comma \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Run CommaTests from the Comma scheme on an iPhone simulator.
The tests use memory credentials and a controlled transport.
Run shared transport and state tests separately:

```sh
swift test --package-path clients/packages/apple-core
```

[Client contracts](../../../docs/clients.md#native-apple-clients) define chat, Watch pairing, notification budgets, and verification limits.

## iPhone account and Task management

These screens use the same routes as the desktop client:

- Task search returns at most 20 results. The query is sent after 300 ms without typing.
- Rename, pin, share, and archive are in the Task row menu and the open Task header menu.
  Archive and restore send the listed `updated_at` as `expected_updated_at`. The server refuses a stale copy.
- Archived Tasks load 50 per page from the archive button in the sidebar.
- Settings > Task labels manages labels, agent proposals, and the approval policy.
- The Worker in Task details opens its history. Pages are 50 records. Older pages and refresh are explicit.
  History opens no event stream, so the open Task keeps the limit of two foreground streams.
- Routines show above Tasks in the sidebar as a Smart Stack: one medium card in a glass well.
  Swipe up or down for the next card; the stack loops and shrinks while it is dragged.
  The Routines header opens every card in the large layout. Cards use widget sizes: small, medium and large.
  Routines read the briefing when they appear. Refresh is an explicit request.
  While a run is in progress, a visible Routines view reads again every 2 seconds.
  It stops after 45 failed reads in a row.
  A prompt goes into the Home composer. The member sends it.
  Provider marks come from the desktop brand artwork, as vector assets in `Resources/Assets.xcassets/ProviderLogos`.
- Settings > Profile edits the name (64 characters maximum) and the photo (a square JPEG of 2 MB maximum).
- Settings > Signed-in devices lists sessions 50 per page. It signs out one other device or all other devices.
  Use Sign out for this device.
