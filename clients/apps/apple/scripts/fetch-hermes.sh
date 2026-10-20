#!/bin/bash
# Fetches the Hermes the iOS app runs the client core in (iOS/Core): React Native's prebuilt hermes-ios release
# artifact, of the React Native release whose Hermes the Android app carries (`hermes` in
# clients/apps/android/gradle/libs.versions.toml), checked against its SHA-256 and unpacked into Vendor/hermes
# (hermes.xcframework and the JSI and Hermes headers). XcodeGen runs it before it generates the project; a copy of the
# same release is left as it is.
set -euo pipefail
apple=$(cd "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/^hermes = "\(.*\)"$/\1/p' "$apple/../android/gradle/libs.versions.toml")
case "$version" in
  0.81.4) sha256=0a9ada4198ed5bbd4a8099197cd100397d65cc86cd44c8eba6c162099081e554 ;;
  *) echo "fetch-hermes.sh has no SHA-256 for hermes-ios $version: add the one Maven Central publishes" >&2; exit 1 ;;
esac
vendor="$apple/Vendor/hermes"
if [[ -f "$vendor/VERSION" && "$(cat "$vendor/VERSION")" == "$version" ]]; then exit 0; fi
work=$(mktemp -d "${TMPDIR:-/tmp}/comma-hermes.XXXXXX")
trap 'rm -rf "$work"' EXIT
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 300 \
  --output "$work/hermes-ios.tar.gz" \
  "https://repo1.maven.org/maven2/com/facebook/react/react-native-artifacts/$version/react-native-artifacts-$version-hermes-ios-release.tar.gz"
echo "$sha256  $work/hermes-ios.tar.gz" | shasum -a 256 -c - >/dev/null
tar -xzf "$work/hermes-ios.tar.gz" -C "$work" destroot/Library/Frameworks/universal/hermes.xcframework \
  destroot/include/hermes destroot/include/jsi
rm -rf "$vendor"
mkdir -p "$vendor"
mv "$work/destroot/Library/Frameworks/universal/hermes.xcframework" "$vendor/"
mv "$work/destroot/include" "$vendor/include"
echo "$version" > "$vendor/VERSION"
