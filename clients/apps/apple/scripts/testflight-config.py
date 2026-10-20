#!/usr/bin/env python3
"""Pack one GitHub secret and expose only the credentials needed by a child."""
import argparse
import base64
import gzip
import io
import json
import os
from pathlib import Path
import sys


SECRET_NAME = "IOS_TESTFLIGHT_CONFIG"
MAX_PACKED_BYTES = 48 * 1024
MAX_JSON_BYTES = 256 * 1024
PUBLIC_DEFAULTS = {
    "ASC_APP_ID": "6817786267",
    "ASC_KEY_ID": "3WNBU47WU9",
    "APPLE_TEAM_ID": "D9AAN3VJK8",
    "IOS_TESTFLIGHT_GROUP": "Internal Testers",
}
PUBLIC_KEYS = (*PUBLIC_DEFAULTS, "ASC_ISSUER_ID")
# Existing packages remain valid. The workflow selects the Xcode toolchain.
LEGACY_KEYS = ("IOS_XCODE_PATH",)
API_KEYS = ("ASC_PRIVATE_KEY_B64",)
SIGNING_KEYS = ("IOS_DISTRIBUTION_P12_B64", "IOS_DISTRIBUTION_P12_PASSWORD",
                "IOS_APP_PROFILE_B64", "IOS_ACTIVITY_PROFILE_B64", "IOS_WATCH_PROFILE_B64", "IOS_WATCH_WIDGETS_PROFILE_B64")
SECRET_KEYS = (*API_KEYS, *SIGNING_KEYS)
AMBIENT_KEYS = (*SECRET_KEYS, SECRET_NAME, "ASC_PRIVATE_KEY", "ASC_PRIVATE_KEY_PATH")


class ConfigError(Exception):
    pass


def validate(config):
    if not isinstance(config, dict) or set(config) - set((*PUBLIC_KEYS, *SECRET_KEYS, *LEGACY_KEYS)):
        raise ConfigError("TestFlight configuration contains unexpected fields")
    if any(not isinstance(value, str) or not value or "\0" in value for value in config.values()):
        raise ConfigError("TestFlight configuration fields must be nonempty strings")
    public = {**PUBLIC_DEFAULTS, **{key: config[key] for key in PUBLIC_KEYS if key in config}}
    if "ASC_ISSUER_ID" not in public:
        raise ConfigError("TestFlight configuration requires ASC_ISSUER_ID")
    if any("\r" in value or "\n" in value for value in public.values()):
        raise ConfigError("TestFlight public configuration fields must use a single line")
    for key in SECRET_KEYS:
        if key in config and key.endswith("_B64"):
            try:
                base64.b64decode(config[key], validate=True)
            except (ValueError, UnicodeError):
                raise ConfigError(f"TestFlight configuration has invalid encoding for {key}")
    return public


def unpack(value):
    try:
        encoded = value.encode("ascii")
        if not encoded or len(encoded) > MAX_PACKED_BYTES:
            raise ValueError()
        encoded = encoded.strip()
        compressed = base64.b64decode(encoded, validate=True)
        with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
            payload = stream.read(MAX_JSON_BYTES + 1)
        if len(payload) > MAX_JSON_BYTES:
            raise ValueError()
        config = json.loads(payload)
    except (ValueError, UnicodeError, OSError, EOFError, RecursionError):
        raise ConfigError(f"{SECRET_NAME} must contain Base64-encoded gzip JSON within the size limits")
    validate(config)
    return config


def mask(config, packed):
    # GitHub's official toolkit is JavaScript; use its documented workflow
    # command escaping here without adding a separate Node dependency.
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    values = [packed, *(config[key] for key in SECRET_KEYS if key in config)]
    if config.get("ASC_PRIVATE_KEY_B64"):
        try:
            pem = base64.b64decode(config["ASC_PRIVATE_KEY_B64"], validate=True).decode("utf-8")
        except (ValueError, UnicodeError):
            raise ConfigError("TestFlight API private key must contain encoded UTF-8 PEM")
        values.extend([pem, *pem.splitlines()])
    for value in dict.fromkeys(values):
        if value:
            escaped = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
            print(f"::add-mask::{escaped}", flush=True)


def pack(arguments):
    parser = argparse.ArgumentParser(description="Create one protected TestFlight configuration secret")
    parser.add_argument("--signing-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--app-id", default=PUBLIC_DEFAULTS["ASC_APP_ID"])
    parser.add_argument("--key-id", default=PUBLIC_DEFAULTS["ASC_KEY_ID"])
    parser.add_argument("--team-id", default=PUBLIC_DEFAULTS["APPLE_TEAM_ID"])
    parser.add_argument("--group", default=PUBLIC_DEFAULTS["IOS_TESTFLIGHT_GROUP"])
    options = parser.parse_args(arguments)
    config = {"ASC_APP_ID": options.app_id, "ASC_KEY_ID": options.key_id,
              "ASC_ISSUER_ID": options.issuer_id, "APPLE_TEAM_ID": options.team_id,
              "IOS_TESTFLIGHT_GROUP": options.group}
    files = {"ASC_PRIVATE_KEY_B64": "api.p8", "IOS_DISTRIBUTION_P12_B64": "distribution.p12",
             "IOS_APP_PROFILE_B64": "app.mobileprovision",
             "IOS_ACTIVITY_PROFILE_B64": "activity.mobileprovision",
             "IOS_WATCH_PROFILE_B64": "watch.mobileprovision",
             "IOS_WATCH_WIDGETS_PROFILE_B64": "watch-widgets.mobileprovision"}
    for key, filename in files.items():
        with (options.signing_dir / filename).open("rb") as source:
            contents = source.read(MAX_JSON_BYTES + 1)
        if len(contents) > MAX_JSON_BYTES:
            raise ConfigError("A TestFlight signing input exceeds the configuration size limit")
        config[key] = base64.b64encode(contents).decode("ascii")
    with (options.signing_dir / "p12-password").open() as source:
        config["IOS_DISTRIBUTION_P12_PASSWORD"] = source.read(MAX_JSON_BYTES + 1).rstrip("\r\n")
    validate(config)
    payload = json.dumps(config, separators=(",", ":")).encode("utf-8")
    if len(payload) > MAX_JSON_BYTES:
        raise ConfigError("TestFlight configuration exceeds the unpacked size limit")
    packed = base64.b64encode(gzip.compress(payload, mtime=0))
    if len(packed) > MAX_PACKED_BYTES:
        raise ConfigError("Packed TestFlight configuration exceeds GitHub's 48 KiB secret limit")
    descriptor = os.open(options.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(packed)
    print(f"Packed TestFlight configuration: {options.output} ({len(packed)} bytes)")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "pack":
        pack(sys.argv[2:])
        return
    if len(sys.argv) < 2 or sys.argv[1] not in ("env", "api", "signing"):
        raise ConfigError("Use pack, env, api <command>, or signing <command>")
    mode = sys.argv[1]
    if (mode == "env" and len(sys.argv) != 2) or (mode != "env" and len(sys.argv) < 3):
        raise ConfigError("Use env without a command, or api/signing with a child command")
    packed = os.environ.get(SECRET_NAME, "")
    config = unpack(packed)
    public = validate(config)
    keys = API_KEYS if mode == "api" else SIGNING_KEYS if mode == "signing" else ()
    if any(key not in config for key in keys):
        raise ConfigError(f"TestFlight configuration is missing credentials for {mode}")
    mask(config, packed)
    if mode == "env":
        target = os.environ.get("GITHUB_ENV")
        if not target:
            raise ConfigError("GITHUB_ENV is required to export public TestFlight settings")
        with open(target, "a") as output:
            for key, value in public.items():
                output.write(f"{key}={value}\n")
        return
    child_env = {key: value for key, value in os.environ.items() if key not in AMBIENT_KEYS}
    child_env.update(public)
    child_env.update({key: config[key] for key in keys})
    os.execvpe(sys.argv[2], sys.argv[2:], child_env)


if __name__ == "__main__":
    try:
        main()
    except (ConfigError, OSError) as error:
        print(f"TestFlight configuration failed: {error}", file=sys.stderr)
        sys.exit(1)
