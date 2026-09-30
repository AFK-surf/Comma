#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
connector_dir="$(cd "$script_dir/.." && pwd)"

package_dir="$connector_dir/native/macos/ComputerUseHost"
configuration="debug"
product="CommaComputerUseDaemon"
display_name="Comma Computer Use"
app_path=""
archive_path=""
archive_root=""
bundle_id="surf.comma.salix-connect.computer-use"
resource_bundles=(
  "ComputerUseHost_CommaComputerUseDaemon.bundle"
  "ComputerUseHost_CUShared.bundle"
  "ComputerUseHost_CUForeground.bundle"
  "PermissionFlow_PermissionFlow.bundle"
)
sign_identity="${COMMA_MACOS_DEV_SIGN_IDENTITY:--}"
keychain=""
entitlements=""
hardened_runtime="0"
timestamp="0"
sign_only="0"
stop_running="0"
arch_args=()

usage() {
  cat >&2 <<'USAGE'
Usage: package-computer-use-helper.sh --app-path PATH [options]

Options:
  --package-path PATH      SwiftPM package path.
  --configuration NAME     Swift build configuration: debug or release.
  --arch ARCH              Swift build architecture. May be repeated.
  --bundle-id ID           CFBundleIdentifier for Comma Computer Use.app.
  --display-name NAME      Application name shown in authorization UI.
  --sign-identity ID       codesign identity. Defaults to ad-hoc signing.
  --keychain PATH          codesign keychain for distribution signing.
  --entitlements PATH      entitlements file for distribution signing.
  --hardened-runtime       Sign with hardened runtime.
  --timestamp              Include a signing timestamp.
  --archive-path PATH      Write a comma-computer-use.tar.gz archive.
  --archive-root PATH      Root used for the archive entry.
  --stop-running           Stop an existing helper before replacing the app.
  --sign-only              Sign an existing app without rebuilding it.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --package-path)
      package_dir="$2"
      shift 2
      ;;
    --configuration)
      configuration="$2"
      shift 2
      ;;
    --arch)
      arch_args+=(--arch "$2")
      shift 2
      ;;
    --app-path)
      app_path="$2"
      shift 2
      ;;
    --bundle-id)
      bundle_id="$2"
      shift 2
      ;;
    --display-name)
      display_name="$2"
      shift 2
      ;;
    --sign-identity)
      sign_identity="$2"
      shift 2
      ;;
    --keychain)
      keychain="$2"
      shift 2
      ;;
    --entitlements)
      entitlements="$2"
      shift 2
      ;;
    --hardened-runtime)
      hardened_runtime="1"
      shift
      ;;
    --timestamp)
      timestamp="1"
      shift
      ;;
    --archive-path)
      archive_path="$2"
      shift 2
      ;;
    --archive-root)
      archive_root="$2"
      shift 2
      ;;
    --stop-running)
      stop_running="1"
      shift
      ;;
    --sign-only)
      sign_only="1"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "CommaComputerUse packaging requires macOS." >&2
  exit 1
fi

if [ -z "$app_path" ]; then
  echo "--app-path is required." >&2
  usage
  exit 1
fi

stop_running_helper() {
  executable_path="$app_path/Contents/MacOS/$product"
  # Match the exact executable path with optional standalone-mode arguments.
  executable_pattern="$(printf '%s' "$executable_path" | sed 's/[][\.^$*+?(){}|]/\\&/g')"
  pids="$(
    pgrep -f "^$executable_pattern( |$)" 2>/dev/null || true
  )"
  [ -n "$pids" ] || return 0

  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done

  deadline=$((SECONDS + 5))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! pgrep -f "^$executable_pattern( |$)" >/dev/null 2>&1; then
      echo "Stopped running $product before rebuilding."
      return 0
    fi
    sleep 0.1
  done

  echo "$product is still running; quit it before rebuilding." >&2
  exit 1
}

write_info_plist() {
  contents_dir="$app_path/Contents"
  cat > "$contents_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$product</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$display_name</string>
  <key>CFBundleDisplayName</key>
  <string>$display_name</string>
  <key>CFBundleIconFile</key>
  <string>CommaComputerUse</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST
}

sign_app() {
  signing_flags=(--force)
  executable_flags=(--force --strict)

  if [ "$hardened_runtime" = "1" ]; then
    signing_flags+=(--deep --strict --options runtime)
    executable_flags+=(--options runtime)
  else
    signing_flags+=(--deep)
  fi
  if [ "$timestamp" = "1" ]; then
    signing_flags+=(--timestamp)
    executable_flags+=(--timestamp)
  fi
  if [ -n "$keychain" ]; then
    signing_flags+=(--keychain "$keychain")
    executable_flags+=(--keychain "$keychain")
  fi
  if [ -n "$entitlements" ]; then
    signing_flags+=(--entitlements "$entitlements")
    executable_flags+=(--entitlements "$entitlements")
  fi

  executable_path="$app_path/Contents/MacOS/$product"
  if [ -x "$executable_path" ] && [ "$hardened_runtime" = "1" ]; then
    codesign "${executable_flags[@]}" --sign "$sign_identity" "$executable_path"
  fi

  codesign "${signing_flags[@]}" --sign "$sign_identity" "$app_path"
  codesign --verify --deep --strict --verbose=2 "$app_path"
}

build_app() {
  build_args=(
    --package-path "$package_dir"
    -c "$configuration"
    --product "$product"
  )
  if [ "${#arch_args[@]}" -gt 0 ]; then
    build_args+=("${arch_args[@]}")
  fi

  swift package --package-path "$package_dir" resolve
  local permission_flow="$package_dir/.build/checkouts/PermissionFlow"
  local header_patch="$connector_dir/native/macos/patches/permission-flow-stable-header.patch"
  # Keep the pinned dependency's header width stable across Settings focus changes.
  if ! git -C "$permission_flow" apply --reverse --check "$header_patch" 2>/dev/null; then
    git -C "$permission_flow" apply "$header_patch"
  fi
  local resources_patch="$connector_dir/native/macos/patches/permission-flow-resource-bundle.patch"
  if ! git -C "$permission_flow" apply --reverse --check "$resources_patch" 2>/dev/null; then
    git -C "$permission_flow" apply "$resources_patch"
  fi
  local drag_card_patch="$connector_dir/native/macos/patches/permission-flow-drag-card-resource.patch"
  if ! git -C "$permission_flow" apply --reverse --check "$drag_card_patch" 2>/dev/null; then
    git -C "$permission_flow" apply "$drag_card_patch"
  fi
  local display_name_patch="$connector_dir/native/macos/patches/permission-flow-display-name.patch"
  if ! git -C "$permission_flow" apply --reverse --check "$display_name_patch" 2>/dev/null; then
    git -C "$permission_flow" apply "$display_name_patch"
  fi
  swift build "${build_args[@]}"
  bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
  binary_path="$bin_dir/$product"

  contents_dir="$app_path/Contents"
  macos_dir="$contents_dir/MacOS"
  resources_dir="$contents_dir/Resources"

  [ "$stop_running" = "1" ] && stop_running_helper

  rm -rf "$app_path"
  mkdir -p "$macos_dir" "$resources_dir"
  cp "$binary_path" "$macos_dir/$product"
  chmod +x "$macos_dir/$product"
  icon_source="$package_dir/Sources/CommaComputerUseDaemon/Resources/panel-logo.png"
  iconset="$resources_dir/CommaComputerUse.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$resources_dir/CommaComputerUse.icns"
  rm -rf "$iconset"
  write_info_plist
  printf 'APPL????' > "$contents_dir/PkgInfo"
  for bundle in "${resource_bundles[@]}"; do
    if [ ! -d "$bin_dir/$bundle" ]; then
      echo "Missing required computer-use resource bundle: $bundle" >&2
      exit 1
    fi
    cp -R "$bin_dir/$bundle" "$resources_dir/"
  done
}

if [ "$sign_only" = "0" ]; then
  build_app
fi

sign_app

if [ -n "$archive_path" ]; then
  if [ -z "$archive_root" ]; then
    archive_root="$(cd "$(dirname "$app_path")/../.." && pwd)"
  fi
  mkdir -p "$(dirname "$archive_path")"
  tar -C "$archive_root" -czf "$archive_path" "native/macos/$(basename "$app_path")"
fi
