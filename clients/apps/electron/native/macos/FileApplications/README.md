# macOS file applications

This in-process Node-API adapter uses the AppKit `NSWorkspace` association lookup
and open APIs. Electron `shell.openPath` cannot list associated applications or
select a particular installation. The adapter does not search Applications
directories, run a shell command, change default associations, or use a separate
helper.

`listApplicationsForFileName` resolves the filename extension through `UTType`
and returns applications in system order, with a default marker and optional PNG
icons. Queries run off the JavaScript thread. An unknown type can return an empty
list. An unavailable adapter returns `null`.

These adapter values stay in Main. `DownloadsService` exposes opaque,
process-local application IDs. Each ID selects the exact installation URL that
the OS returned. It is not a publisher or code-signing identity. Before it opens
a file, the service resolves its saved-download handle and checks that
installation against the OS handlers for the actual saved file. A missing or
evicted selection, a changed association, or a failed OS launch returns
unavailable. The service never opens a different app.

Menu lookup does not fetch content. Opening does not add server authentication
or provenance claims. The normal native build includes this addon. A focused
build is available with:

```sh
pnpm --dir clients --filter @comma/electron exec node --import tsx scripts/build-native.ts --file-applications-only
```

On macOS, after the build, an opt-in test checks the actual SDK association
results and PNG output without launching an application. It needs access to the
Launch Services of the login session. An isolated sandbox can return an empty
registry.

```sh
COMMA_NATIVE_FILE_APPLICATIONS_SMOKE=1 pnpm --dir clients exec vitest run apps/electron/test/native-file-applications.test.ts
```

## Copy a saved file

`copyFileToClipboard` uses AppKit `NSPasteboard.writeObjects` with an `NSURL` file URL.
It does not encode private clipboard formats.

The generated `files.copyDownload` leaf accepts an existing saved-download handle.
Main resolves it through the download owner. Renderer paths and MIME format keys do not enter the adapter.
Missing files, expired handles, and failed pasteboard writes return unavailable.

Video Copy first saves the original bytes in Downloads, then copies that file.
The file keeps the Downloads lifetime, so it stays available after Comma exits.
Copy Current Frame copies a PNG of the decoded picture at the time the menu opens.
Web and other desktop platforms disable complete-file Copy.
