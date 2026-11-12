# macOS build on Linux

This directory builds the macOS desktop app on Linux, in Docker. It makes the Velopack release package and the `.dmg`.
The build does not use Xcode. It uses the Swift toolchain for Linux, LLVM `lld`, and the macOS SDK from Apple's Command Line Tools.

## Requirements

- Docker.
- `OPENDROPKIT_RELEASE_TOKEN`, a GitHub token that can read the OpenDropKit releases.

## Procedure

1. Build the image:

   ```sh
   docker build -t comma-macos-cross clients/apps/electron/cross/macos
   ```

2. Build the release from the repository root:

   ```sh
   docker run --rm \
     -v "$PWD:/src" \
     -v comma-macos-cache:/cache \
     -e OPENDROPKIT_RELEASE_TOKEN \
     comma-macos-cross
   ```

The release is in `clients/apps/electron/Releases/<channel>/`: the Velopack package (`.nupkg`), the portable `.zip`, the feed files, and the DMG.
If this directory already contains the previous release of the channel, Velopack also makes a delta package.

The `/cache` volume keeps the downloads and the build caches between builds. This includes the Swift module cache: the SDK modules that all Swift builds share. Without the volume, each build compiles the SDK modules again.

If the checkout is a Git worktree, also mount the main repository's `.git` directory at the same path. The station build reads Git metadata.

## macOS SDK

`prepare-sdk.sh` downloads the SDK package of the Command Line Tools from Apple's software update server (`swcdn.apple.com`).
It makes sure that the SHA-256 of the package is correct, and keeps the package in `/cache`.
Then it extracts the SDK with `bsdtar` and a pbzx decoder.

To change the SDK:

1. Get the software update catalog of the current macOS release, for example `https://swscan.apple.com/content/catalogs/others/index-27-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz`.
2. Find the product "Command Line Tools for Xcode" with the necessary version.
3. Copy the URL of its `CLTools_macOSNMOS_SDK.pkg`.
4. On a Mac, download the package and run `pkgutil --check-signature` on it. The signer must be Apple.
5. Set `sdk_name`, `pkg_url`, and `pkg_sha256` in `prepare-sdk.sh`.
6. Set `SWIFT_VERSION` in the `Dockerfile` to the `swift-compiler-version` in the SDK's `.swiftinterface` files.

## Configuration

Environment of the container:

| Variable                                                | Default                     | Use                                                                                                                                                            |
| ------------------------------------------------------- | --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `COMMA_TARGET_ARCH`                                     | `arm64`                     | Target architecture (`arm64` or `x64`).                                                                                                                        |
| `COMMA_BUILD_FLAVOR`                                    | `staging`                   | Release configuration.                                                                                                                                         |
| `COMMA_PACK_VERSION`                                    | `version` in `package.json` | Release version.                                                                                                                                               |
| `COMMA_MACOS_P12_FILE`, `COMMA_MACOS_P12_PASSWORD_FILE` | not set                     | Developer ID Application certificate (`.p12`) and its password. Without them, the build signs ad hoc.                                                          |
| `COMMA_MACOS_NOTARY_KEY_FILE`                           | not set                     | App Store Connect API key, as JSON from `rcodesign encode-app-store-connect-api-key`. With a certificate, the build notarizes and staples the app and the DMG. |

Build arguments of the image:

| Argument        | Default                   | Use                                                                                                             |
| --------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `UBUNTU_MIRROR` | not set                   | HTTPS apt mirror for the image's architecture, for example `https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports`. |
| `NODE_DIST`     | `https://nodejs.org/dist` | Node.js download mirror with the same layout.                                                                   |

To open a shell with the same environment, run the image with the argument `shell`.

## Limits

- With a certificate, `sign.sh` signs every executable with the hardened runtime, a time stamp, and `build/entitlements.mac.entitlements`, as `scripts/sign-macos-app.ts` does on a Mac.
- `rcodesign` reads only `.p12` files with legacy encryption (`openssl pkcs12 -export -legacy`, or `security export`).
- `vpk` packs macOS releases only on macOS. `velopack/` runs the macOS packaging of the `vpk` libraries on Linux. It signs with `sign.sh` in place of `codesign` and `notarytool`, and makes the portable package with `zip` in place of `ditto`.
- `sign.sh` gives Velopack's `UpdateMac` the Velopack entitlements, as `vpk` does.
- The DMG uses bzip2 compression (UDBZ). The Mac release build uses LZMA (ULMO).
- `bin/` replaces the macOS tools that the build scripts call (`xcrun`, `codesign`, `sips`, `iconutil`, `PlistBuddy`, and `swift build`). These replacements support only the options that the build scripts use.
- Xcode's SwiftUI macro plugins are macOS binaries. `macros/` replaces them for Linux:
  - `@State` expands as SwiftUI expands a `@State` property that is not private.
  - `#Preview` and `@Previewable` expand to nothing.
  - Other SwiftUI macros (for example `@Entry` and `@Animatable`) are not available.
- The build compiles `__isPlatformVersionAtLeast` from LLVM compiler-rt (`os_version_check.c`) into `libclang_rt.osx.a`.
- The Swift back-deployment libraries (`libswiftCompatibility*.a`) are empty. Most of them change behavior only on macOS earlier than 12.3, and the native parts need macOS 13 or later.
  `libswiftCompatibilityPacks.a` adds parameter pack metadata on macOS 13. The native parts do not use parameter packs.
