# macOS file applications

This in-process Node-API adapter uses AppKit's `NSWorkspace` association lookup
and open APIs. Electron's public `shell.openPath` supports the default app but
does not enumerate associated applications or select a particular installation.
The adapter requires macOS 13, matching Comma's existing native addons. It does
not search Applications directories, invoke a shell command, change default
associations, or run a separate helper transport.

`listApplicationsForFileName` resolves the filename extension through `UTType`
and returns at most 32 applications in system order, with a default marker and
optional 32-by-32 PNG icons. Queries run off the JavaScript thread. An unknown
type can return an empty list; an unavailable adapter returns `null`.

These adapter values stay in Main. `DownloadsService` exposes opaque,
process-local application IDs, with at most 256 retained entries. Each ID
selects the exact installation URL returned by the OS, including when two
installations share a bundle identifier. It is not a publisher or code-signing
identity. Before opening, the service resolves its existing saved-download
handle and checks that installation against the OS handlers for the actual
saved file. A missing or evicted selection, changed association, or failed OS
launch returns unavailable, without opening a different app. Reopening the
menu obtains current choices. Saved files keep the existing Downloads lifetime.

The generated renderer leaves remain local-only: menu lookup does not fetch
content, and opening does not add server authentication or provenance claims.
The normal native build includes this addon and Forge packages `dist/native`.
A focused build is available with:

```sh
pnpm --dir clients --filter @comma/electron exec node --import tsx scripts/build-native.ts --file-applications-only
```

The default tests exercise the generated bridge, saved-file owner, and injected
OS boundary. On macOS, after building, the opt-in test checks the actual SDK
association results and PNG output without launching an application:

```sh
COMMA_NATIVE_FILE_APPLICATIONS_SMOKE=1 pnpm --dir clients exec vitest run apps/electron/test/native-file-applications.test.ts
```

That test needs access to the login session's Launch Services; an isolated
command sandbox may return an empty registry. It does not establish successful
document rendering by every third-party application.

## Copy a saved file

`copyFileToClipboard` uses AppKit `NSPasteboard.writeObjects` with an `NSURL` file URL.
Electron 42 has no typed file-copy API. This adapter uses the existing AppKit addon and does not encode private clipboard formats.

The generated `files.copyDownload` leaf accepts an existing saved-download handle.
Main resolves it through the existing download owner. Renderer paths and MIME format keys do not enter the adapter.
Missing files, expired handles, and failed pasteboard writes return unavailable.

Video Copy first saves the original bytes in Downloads, then copies that file.
The Toast states both results. The file keeps the existing Downloads lifetime, so it remains available after Comma exits.
Copy Current Frame instead captures the decoded picture when the menu opens and copies a PNG.
Web and other desktop platforms disable complete-file Copy. Other video actions remain available.
Complete-file Copy and Save retain the existing 10,000,000-byte download limit.
Add to Context uses the existing attachment upload path.
