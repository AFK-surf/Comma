#!/bin/bash
# Build a signed TestFlight IPA. Upload and distribution belong to the workflow.
set +x
set -euo pipefail
umask 077

required() {
  if [[ -z "${!1:-}" ]]; then
    printf 'Missing required environment variable: %s\n' "$1" >&2
    exit 1
  fi
}

required IOS_RELEASE_DIR
if [[ "$IOS_RELEASE_DIR" != /* ]]; then
  printf 'IOS_RELEASE_DIR must be an absolute path.\n' >&2
  exit 1
fi
signing_state="$IOS_RELEASE_DIR/.signing-cleanup.json"

cleanup() {
  python3 - "$signing_state" <<'PY'
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

state_path = Path(sys.argv[1])
if not state_path.exists():
    raise SystemExit(0)
state = json.loads(state_path.read_text())
keychain = state["keychain"]
errors = []
try:
    listed = subprocess.check_output(["security", "list-keychains", "-d", "user"], text=True)
    current = shlex.split(listed)
    if keychain in current:
        subprocess.run(["security", "list-keychains", "-d", "user", "-s",
                        *[entry for entry in current if entry != keychain]], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if Path(keychain).exists():
        subprocess.run(["security", "delete-keychain", keychain], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
except (OSError, subprocess.CalledProcessError) as error:
    errors.append(f"temporary keychain: {error}")
for profile in state["profiles"]:
    try:
        Path(profile).unlink(missing_ok=True)
    except OSError as error:
        errors.append(f"temporary provisioning profile: {error}")
try:
    shutil.rmtree(state["work_dir"])
except FileNotFoundError:
    pass
except OSError as error:
    errors.append(f"temporary build directory: {error}")
if errors:
    print("TestFlight signing cleanup failed: " + "; ".join(errors), file=sys.stderr)
    raise SystemExit(1)
state_path.unlink()
PY
}

if [[ "${1:-}" == --cleanup ]]; then
  cleanup
  exit
elif [[ $# != 0 ]]; then
  printf 'Usage: build-testflight.sh [--cleanup]\n' >&2
  exit 1
fi

for name in APPLE_SOURCE_DIR MARKETING_VERSION BUILD_NUMBER COMMA_API_BASE_URL \
  IOS_DISTRIBUTION_P12_B64 IOS_DISTRIBUTION_P12_PASSWORD \
  IOS_APP_PROFILE_B64 IOS_ACTIVITY_PROFILE_B64 IOS_WATCH_PROFILE_B64 IOS_WATCH_WIDGETS_PROFILE_B64; do
  required "$name"
done
if [[ "$APPLE_SOURCE_DIR" != /* ]]; then
  printf 'APPLE_SOURCE_DIR must be an absolute path.\n' >&2
  exit 1
fi
for command_name in python3 node security xcodegen xcodebuild xcrun asc ditto openssl; do
  command -v "$command_name" >/dev/null || {
    printf 'Required command is unavailable: %s\n' "$command_name" >&2
    exit 1
  }
done
export APPLE_TEAM_ID="${APPLE_TEAM_ID:-D9AAN3VJK8}"
xcodebuild -version
xcodegen --version
xcrun --sdk iphoneos --show-sdk-path >/dev/null
xcrun --sdk watchos --show-sdk-path >/dev/null

mkdir -p "$IOS_RELEASE_DIR"
if [[ -e "$signing_state" || -e "$IOS_RELEASE_DIR/Comma.xcarchive" || -e "$IOS_RELEASE_DIR/Comma.ipa" ]]; then
  printf 'Release directory already contains signing state or a build. Use a fresh release directory.\n' >&2
  exit 1
fi
work_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/comma-tf-build.XXXXXX")
keychain="$work_dir/signing.keychain-db"
keychain_password=$(openssl rand -hex 32)
phase=prepare

finish() {
  result=$?
  trap - EXIT INT TERM
  if ! cleanup; then
    printf '::warning::Run build-testflight.sh --cleanup to retry signing cleanup.\n' >&2
    if [[ $result -eq 0 ]]; then result=1; fi
  fi
  if [[ $result -ne 0 ]]; then
    printf 'TestFlight build failed during %s. See the release logs.\n' "$phase" >&2
  fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 - "$work_dir" "$signing_state" <<'PY'
import base64
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlparse

work = Path(sys.argv[1])
Path(sys.argv[2]).write_text(json.dumps({"work_dir": str(work),
    "keychain": str(work / "signing.keychain-db"), "profiles": []}))
source = Path(os.environ["APPLE_SOURCE_DIR"])
if not (source / "clients/apps/apple/project.yml").is_file():
    raise SystemExit("Selected source does not contain clients/apps/apple/project.yml")
if not re.fullmatch(r"\d+\.\d+\.\d+", os.environ["MARKETING_VERSION"]):
    raise SystemExit("MARKETING_VERSION must use major.minor.patch")
if not re.fullmatch(r"[1-9]\d*", os.environ["BUILD_NUMBER"]):
    raise SystemExit("BUILD_NUMBER must be a positive integer")
backend = urlparse(os.environ["COMMA_API_BASE_URL"])
if backend.scheme != "https" or not backend.netloc:
    raise SystemExit("COMMA_API_BASE_URL must be an HTTPS URL")
for variable, filename in [("IOS_DISTRIBUTION_P12_B64", "distribution.p12"),
                           ("IOS_APP_PROFILE_B64", "app.mobileprovision"),
                           ("IOS_ACTIVITY_PROFILE_B64", "activity.mobileprovision"),
                           ("IOS_WATCH_PROFILE_B64", "watch.mobileprovision"),
                           ("IOS_WATCH_WIDGETS_PROFILE_B64", "watch-widgets.mobileprovision")]:
    try:
        decoded = base64.b64decode("".join(os.environ[variable].split()), validate=True)
    except ValueError:
        raise SystemExit(f"{variable} is not valid base64")
    (work / filename).write_bytes(decoded)
PY
unset IOS_DISTRIBUTION_P12_B64 IOS_APP_PROFILE_B64 IOS_ACTIVITY_PROFILE_B64 IOS_WATCH_PROFILE_B64 IOS_WATCH_WIDGETS_PROFILE_B64

phase=signing
security create-keychain -p "$keychain_password" "$keychain" >/dev/null
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work_dir/distribution.p12" -k "$keychain" \
  -P "$IOS_DISTRIBUTION_P12_PASSWORD" -T /usr/bin/codesign \
  >"$work_dir/keychain-import.log" 2>&1
unset IOS_DISTRIBUTION_P12_PASSWORD
# Build scripts from the selected source run later; leave them no exportable key.
rm -f "$work_dir/distribution.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$keychain_password" "$keychain" >"$work_dir/keychain-partitions.log" 2>&1
unset keychain_password

python3 - "$keychain" "$work_dir/identity.txt" <<'PY'
from pathlib import Path
import re
import shlex
import subprocess
import sys

keychain = sys.argv[1]
output = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning", keychain], text=True)
identities = [(fingerprint, name) for fingerprint, name in
              re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"]+)"', output, re.MULTILINE)
              if name.startswith(("Apple Distribution:", "iPhone Distribution:"))]
if len(identities) != 1:
    raise SystemExit("The supplied P12 must contain one valid Apple Distribution signing identity")
Path(sys.argv[2]).write_text(identities[0][0])
current = shlex.split(subprocess.check_output(["security", "list-keychains", "-d", "user"], text=True))
if keychain not in current:
    subprocess.run(["security", "list-keychains", "-d", "user", "-s", keychain, *current], check=True)
PY
for profile_name in app activity watch watch-widgets; do
  security cms -D -i "$work_dir/$profile_name.mobileprovision" \
    >"$work_dir/$profile_name.plist" 2>"$work_dir/$profile_name-decode.log"
done

python3 - "$work_dir" "$signing_state" "$IOS_RELEASE_DIR" <<'PY'
import json
import os
from pathlib import Path
import plistlib
import sys
from uuid import UUID

work, state_path, release = map(Path, sys.argv[1:])
source = Path(os.environ["APPLE_SOURCE_DIR"]) / "clients/apps/apple"
team = os.environ["APPLE_TEAM_ID"]
identity = (work / "identity.txt").read_text()
profile_dirs = [Path.home() / "Library/MobileDevice/Provisioning Profiles",
                Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"]
state = json.loads(state_path.read_text())
def save_state():
    pending = state_path.with_suffix(".pending")
    pending.write_text(json.dumps(state))
    pending.replace(state_path)
profiles = {}
targets = {}
for target, profile_name, bundle in [("Comma", "app", "surf.comma.ios"),
                                    ("CommaLiveActivity", "activity", "surf.comma.ios.activity"),
                                    ("CommaWatch", "watch", "surf.comma.ios.watch"),
                                    ("CommaWatchWidgets", "watch-widgets", "surf.comma.ios.watch.widgets")]:
    with (work / f"{profile_name}.plist").open("rb") as file:
        profile = plistlib.load(file)
    raw_uuid = profile.get("UUID")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    application_id = profile.get("Entitlements", {}).get("application-identifier")
    try:
        uuid = str(UUID(raw_uuid))
    except (AttributeError, TypeError, ValueError):
        raise SystemExit(f"The {profile_name} profile has an invalid UUID")
    if raw_uuid.lower() != uuid:
        raise SystemExit(f"The {profile_name} profile UUID must use the canonical UUID format")
    if team not in profile.get("TeamIdentifier", []):
        raise SystemExit(f"The {profile_name} profile belongs to a different Apple team")
    if application_id not in [f"{prefix}.{bundle}" for prefix in prefixes]:
        raise SystemExit(f"The {profile_name} profile does not match {bundle}")
    profiles[bundle] = uuid
    original = (work / f"{profile_name}.mobileprovision").read_bytes()
    for directory in profile_dirs:
        directory.mkdir(parents=True, exist_ok=True)
        # Xcode looks up profiles by their canonical UUID filename.
        installed = directory / f"{uuid}.mobileprovision"
        try:
            descriptor = os.open(installed, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            if installed.read_bytes() != original:
                raise SystemExit(f"An installed profile for {uuid} differs from the supplied {profile_name} profile")
            # An identical runner profile is reused and is never owned by this run.
            continue
        with os.fdopen(descriptor, "wb") as destination:
            state["profiles"].append(str(installed))
            save_state()
            destination.write(original)
    targets[target] = {
        "settings": {"configs": {"Release": {
            "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": identity,
            "PROVISIONING_PROFILE_SPECIFIER": uuid}}},
        "info": {"path": str(work / f"{target}-Info.plist")}}
targets["Comma"]["entitlements"] = {"path": str(work / "Comma.entitlements")}
spec = {
    "include": [{"path": str(source / "project.yml"), "relativePaths": True}],
    # The generated project is outside the source: Hermes is fetched into the source, and the build finds it there.
    "options": {"preGenCommand": f'bash "{source / "scripts/fetch-hermes.sh"}"'},
    "settings": {"base": {
        "COMMA_APPLE_DIR": str(source),
        "MARKETING_VERSION": os.environ["MARKETING_VERSION"],
        "CURRENT_PROJECT_VERSION": os.environ["BUILD_NUMBER"],
        "DEVELOPMENT_TEAM": team,
        "COMMA_PHONE_BUNDLE_ID": "surf.comma.ios",
        "COMMA_API_BASE_URL": os.environ["COMMA_API_BASE_URL"],
        "OTHER_CODE_SIGN_FLAGS": f'--keychain "{work / "signing.keychain-db"}"'},
        "configs": {"Release": {"COMMA_PUSH_ENVIRONMENT": "production"}}},
    "targets": targets}
(work / "release-project.json").write_text(json.dumps(spec))
options = {"method": "app-store-connect", "destination": "export", "teamID": team,
           "signingStyle": "manual", "signingCertificate": identity,
           "provisioningProfiles": profiles, "manageAppVersionAndBuildNumber": False,
           "uploadSymbols": True}
with (release / "ExportOptions.plist").open("wb") as file:
    plistlib.dump(options, file)
PY

phase=generate
mkdir -p "$work_dir/project"
# XcodeGen leaves a framework dependency's path relative to the generated project: Hermes (Vendor) is found through it.
ln -s "$APPLE_SOURCE_DIR/clients/apps/apple/Vendor" "$work_dir/project/Vendor"
xcodegen generate --spec "$work_dir/release-project.json" --project "$work_dir/project" \
  --project-root "$APPLE_SOURCE_DIR/clients/apps/apple" \
  2>&1 | tee "$IOS_RELEASE_DIR/xcodegen.log"
package_lock="$APPLE_SOURCE_DIR/clients/apps/apple/Comma.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [[ -f "$package_lock" ]]; then
  mkdir -p "$work_dir/project/Comma.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
  cp "$package_lock" "$work_dir/project/Comma.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
fi

phase=archive
archive() {
  asc xcode archive --project "$work_dir/project/Comma.xcodeproj" --scheme Comma \
    --configuration Release --archive-path "$IOS_RELEASE_DIR/Comma.xcarchive" \
    --xcodebuild-flag=-destination --xcodebuild-flag=generic/platform=iOS \
    --xcodebuild-flag=-derivedDataPath --xcodebuild-flag="$work_dir/DerivedData" \
    --xcodebuild-flag=-resultBundlePath --xcodebuild-flag="$1" \
    --xcodebuild-flag=-disableAutomaticPackageResolution --output json
}
if archive "$IOS_RELEASE_DIR/archive-attempt-1.xcresult" 2>&1 \
  | tee "$IOS_RELEASE_DIR/archive-attempt-1.log" "$IOS_RELEASE_DIR/archive.log"; then
  :
else
  archive_status=$?
  if python3 "$(dirname "${BASH_SOURCE[0]}")/archive-retry.py" "$IOS_RELEASE_DIR"
  then
    printf 'Native provisioning lookup failed before product build tasks; retrying archive once.\n'
  else
    exit "$archive_status"
  fi
  archive "$IOS_RELEASE_DIR/archive-attempt-2.xcresult" 2>&1 \
    | tee "$IOS_RELEASE_DIR/archive-attempt-2.log" \
    | tee -a "$IOS_RELEASE_DIR/archive.log"
fi
if [[ -d "$IOS_RELEASE_DIR/Comma.xcarchive/dSYMs" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$IOS_RELEASE_DIR/Comma.xcarchive/dSYMs" \
    "$IOS_RELEASE_DIR/dSYMs.zip"
fi

phase=export
asc xcode export --archive-path "$IOS_RELEASE_DIR/Comma.xcarchive" \
  --export-options "$IOS_RELEASE_DIR/ExportOptions.plist" --ipa-path "$IOS_RELEASE_DIR/Comma.ipa" \
  --timeout 20m --output json 2>&1 | tee "$IOS_RELEASE_DIR/export.log"
printf 'Signed TestFlight IPA: %s/Comma.ipa\n' "$IOS_RELEASE_DIR"
