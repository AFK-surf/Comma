"""Exercise the native archive retry decision without signing credentials or Xcode."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("archive-retry.py")
TEAM = "D9AAN3VJK8"
PROFILE = "20bbc3ff-108d-43aa-ba2b-ec7dd741acbe"
NO_PROFILE = (f"/tmp/Comma.xcodeproj: error: No profile for team '{TEAM}' matching '{PROFILE}' "
              "found: Xcode couldn't find any provisioning profiles matching the selected target. "
              "(in target 'Comma' from project 'Comma')\n")


class ArchiveRetryDecision(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="comma-archive-retry-test-")
        self.addCleanup(self.temporary.cleanup)
        self.release = Path(self.temporary.name)
        (self.release / "ExportOptions.plist").write_bytes(plistlib.dumps({
            "teamID": TEAM, "provisioningProfiles": {"surf.comma.ios": PROFILE}}))

    def decision(self, log):
        (self.release / "archive-attempt-1.log").write_text(log)
        return subprocess.run([sys.executable, str(SCRIPT), str(self.release)],
                              capture_output=True, text=True).returncode

    def test_selected_native_profile_failure_permits_retry(self):
        self.assertEqual(self.decision("GatherProvisioningInputs\n" + NO_PROFILE + "** ARCHIVE FAILED **\n"), 0)

    def test_mixed_and_non_profile_errors_stop(self):
        other = "/tmp/Comma.xcodeproj: error: Signing certificate is unavailable.\n"
        self.assertEqual(self.decision(other), 1)
        self.assertEqual(self.decision(NO_PROFILE + other), 1)
        self.assertEqual(self.decision("Error: xcode archive failed\n"), 1)

    def test_failure_outside_supplied_profile_scope_stops(self):
        self.assertEqual(self.decision(NO_PROFILE.replace(TEAM, "OTHERTEAM")), 1)
        self.assertEqual(self.decision(NO_PROFILE.replace(PROFILE, "other-profile")), 1)

    def test_executed_product_tasks_stop(self):
        task = "SwiftCompile normal arm64 /tmp/App.swift (in target 'Comma' from project 'Comma')\n"
        self.assertEqual(self.decision(task + NO_PROFILE), 1)

    def test_completed_archive_stops(self):
        self.assertEqual(self.decision(NO_PROFILE + "** ARCHIVE SUCCEEDED **\n"), 1)
        archive = self.release / "Comma.xcarchive"
        archive.mkdir()
        (archive / "Info.plist").write_bytes(plistlib.dumps({"ApplicationProperties": {}}))
        self.assertEqual(self.decision(NO_PROFILE), 1)


if __name__ == "__main__":
    unittest.main()
