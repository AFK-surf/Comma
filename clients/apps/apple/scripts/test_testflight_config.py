"""Exercise packed TestFlight configuration boundaries using synthetic credentials."""
import base64
import gzip
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("testflight-config.py")
PACKED_KEY = "IOS_TESTFLIGHT_CONFIG"
PUBLIC = {
    "ASC_APP_ID": "6817786267",
    "ASC_KEY_ID": "3WNBU47WU9",
    "ASC_ISSUER_ID": "fixture-issuer-id",
    "APPLE_TEAM_ID": "D9AAN3VJK8",
    "IOS_TESTFLIGHT_GROUP": "Internal Testers",
}
PEM = "-----BEGIN PRIVATE KEY-----\nfixture%key\n-----END PRIVATE KEY-----\n"
SECRETS = {
    "ASC_PRIVATE_KEY_B64": base64.b64encode(PEM.encode()).decode(),
    "IOS_DISTRIBUTION_P12_B64": base64.b64encode(b"fixture p12 bytes").decode(),
    "IOS_DISTRIBUTION_P12_PASSWORD": "fixture%password\r\nsecond line",
    "IOS_APP_PROFILE_B64": base64.b64encode(b"fixture app profile").decode(),
    "IOS_ACTIVITY_PROFILE_B64": base64.b64encode(b"fixture activity profile").decode(),
    "IOS_WATCH_PROFILE_B64": base64.b64encode(b"fixture watch profile").decode(),
    "IOS_WATCH_WIDGETS_PROFILE_B64": base64.b64encode(b"fixture watch widgets profile").decode(),
}
OBSERVED_KEYS = (*PUBLIC, *SECRETS, PACKED_KEY, "ASC_PRIVATE_KEY", "ASC_PRIVATE_KEY_PATH",
                 "FIXTURE_RELEASE_DIRECTORY", "DEVELOPER_DIR", "XCODE_PATH", "IOS_XCODE_PATH")
CHILD = "import json,os; print(json.dumps({key:os.environ.get(key) for key in " + repr(OBSERVED_KEYS) + "}))"


def encoded(config):
    return base64.b64encode(gzip.compress(json.dumps(config).encode(), mtime=0)).decode()


class TestFlightConfiguration(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="comma-tf-config-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment_file = self.root / "github-env"
        self.environment = dict(os.environ, GITHUB_ACTIONS="false", GITHUB_ENV=str(self.environment_file))
        self.config = {"ASC_ISSUER_ID": PUBLIC["ASC_ISSUER_ID"], **SECRETS}
        for key in (*SECRETS, PACKED_KEY, "ASC_PRIVATE_KEY", "ASC_PRIVATE_KEY_PATH",
                    "XCODE_PATH", "IOS_XCODE_PATH", "DEVELOPER_DIR"):
            self.environment.pop(key, None)

    def run_config(self, *arguments, config=None, packed=None, success=True, extra_environment=None):
        environment = dict(self.environment)
        if arguments[0] != "pack":
            environment[PACKED_KEY] = packed if packed is not None else encoded(
                self.config if config is None else config)
        environment.update(extra_environment or {})
        result = subprocess.run([sys.executable, str(SCRIPT), *arguments], env=environment,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stderr)
        if not success:
            self.assertTrue(result.stderr.startswith("TestFlight configuration failed:"), result.stderr)
            for value in SECRETS.values():
                self.assertNotIn(value, result.stderr)
        return result

    def test_default_public_metadata_exports_without_credentials(self):
        result = self.run_config("env")
        exported = dict(line.split("=", 1) for line in self.environment_file.read_text().splitlines())
        self.assertEqual(exported, PUBLIC)
        self.assertEqual(result.stdout, "")

    def test_child_credentials_are_scoped_and_ambient_credentials_removed(self):
        ambient = {key: "ambient fixture credential" for key in (*SECRETS, "ASC_PRIVATE_KEY", "ASC_PRIVATE_KEY_PATH")}
        ambient.update(FIXTURE_RELEASE_DIRECTORY=str(self.root), ASC_APP_ID="ambient-app")
        for scope, allowed in (("api", {"ASC_PRIVATE_KEY_B64"}), ("signing", set(SECRETS) - {"ASC_PRIVATE_KEY_B64"})):
            with self.subTest(scope=scope):
                result = self.run_config(scope, sys.executable, "-c", CHILD, extra_environment=ambient)
                child = json.loads(result.stdout)
                self.assertEqual({key: child[key] for key in PUBLIC}, PUBLIC)
                self.assertEqual({key: child[key] for key in SECRETS if key in allowed},
                                 {key: SECRETS[key] for key in allowed})
                self.assertTrue(all(child[key] is None for key in (*SECRETS, PACKED_KEY, "ASC_PRIVATE_KEY", "ASC_PRIVATE_KEY_PATH") if key not in allowed))
                self.assertEqual(child["FIXTURE_RELEASE_DIRECTORY"], str(self.root))

    def test_legacy_xcode_path_cannot_override_runner_toolchain(self):
        config = dict(self.config, IOS_XCODE_PATH="/Applications/Missing-Xcode.app")
        developer_dir = "/Applications/Runner-Xcode.app/Contents/Developer"
        ambient = {"DEVELOPER_DIR": developer_dir}
        for scope in ("env", "api", "signing"):
            with self.subTest(scope=scope):
                if scope == "env":
                    self.run_config(scope, config=config, extra_environment=ambient)
                    exported = dict(line.split("=", 1) for line in self.environment_file.read_text().splitlines())
                    self.assertEqual(exported, PUBLIC)
                    next_step_environment = {**ambient, **exported}
                    self.assertEqual(next_step_environment["DEVELOPER_DIR"], developer_dir)
                    self.assertNotIn("XCODE_PATH", next_step_environment)
                    self.assertNotIn("IOS_XCODE_PATH", next_step_environment)
                    continue
                result = self.run_config(scope, sys.executable, "-c", CHILD,
                                         config=config, extra_environment=ambient)
                child = json.loads(result.stdout)
                self.assertEqual(child["DEVELOPER_DIR"], developer_dir)
                self.assertIsNone(child["XCODE_PATH"])
                self.assertIsNone(child["IOS_XCODE_PATH"])

    def test_actions_masks_encoded_credentials_and_escaped_pem(self):
        packed = encoded(self.config)
        result = self.run_config("env", packed=packed, extra_environment={"GITHUB_ACTIONS": "true"})
        def escaped(value):
            return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        masks = set(result.stdout.splitlines())
        for value in (packed, *SECRETS.values(), PEM, *PEM.splitlines()):
            self.assertIn("::add-mask::" + escaped(value), masks)
        self.assertTrue(all(line.startswith("::add-mask::") for line in masks))

    def test_malformed_and_oversized_containers_fail_before_child(self):
        marker = self.root / "child-started"
        child = "from pathlib import Path; Path(" + repr(str(marker)) + ").touch()"
        oversized = dict(self.config, IOS_DISTRIBUTION_P12_PASSWORD="x" * (256 * 1024))
        fixtures = {
            "invalid base64": "%%%",
            "invalid gzip": base64.b64encode(b"not gzip").decode(),
            "wrong JSON shape": encoded(["fixture"]),
            "unknown field": encoded(dict(self.config, EXTRA_FIELD="fixture")),
            "oversized packed input": "A" * (48 * 1024 + 1),
            "oversized raw whitespace": " " * (48 * 1024 + 1) + encoded(self.config),
            "oversized decompressed JSON": encoded(oversized),
        }
        for label, packed in fixtures.items():
            with self.subTest(case=label):
                self.run_config("api", sys.executable, "-c", child, packed=packed, success=False)
                self.assertFalse(marker.exists())

    def test_public_newlines_cannot_inject_github_environment_fields(self):
        config = dict(self.config, IOS_TESTFLIGHT_GROUP="Internal Testers\nINJECTED=value")
        self.run_config("env", config=config, success=False)
        self.assertFalse(self.environment_file.exists())

    def test_pack_roundtrip_and_output_ownership(self):
        directory = self.root / "inputs"
        directory.mkdir()
        files = {"api.p8": PEM.encode(), "distribution.p12": b"fixture p12 bytes",
                 "app.mobileprovision": b"fixture app profile", "activity.mobileprovision": b"fixture activity profile",
                 "watch.mobileprovision": b"fixture watch profile",
                 "watch-widgets.mobileprovision": b"fixture watch widgets profile", "p12-password": b"fixture password\n"}
        for filename, contents in files.items():
            (directory / filename).write_bytes(contents)
        output = self.root / "packed-config"
        arguments = ("pack", "--signing-dir", str(directory), "--issuer-id", PUBLIC["ASC_ISSUER_ID"],
                     "--output", str(output))
        result = self.run_config(*arguments)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        packed = output.read_text()
        unpacked = json.loads(gzip.decompress(base64.b64decode(packed)))
        expected = {**self.config, "IOS_DISTRIBUTION_P12_PASSWORD": "fixture password",
                    **PUBLIC}
        self.assertEqual(unpacked, expected)
        for value in SECRETS.values():
            self.assertNotIn(value, result.stdout + result.stderr)
        self.run_config("api", sys.executable, "-c", CHILD, packed=packed)
        self.run_config(*arguments, success=False)
        self.assertEqual(output.read_text(), packed)


if __name__ == "__main__":
    unittest.main()
