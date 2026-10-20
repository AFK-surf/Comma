"""Exercise release commands with a local ASC process and no Apple credentials."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("testflight-release.py")
APP = "6817786267"
SHA = "a" * 40
GROUP = {"id": "internal-group", "attributes": {"name": "Internal Testers", "isInternalGroup": True}}
BUILD = {"id": "apple-build", "attributes": {"version": "42", "processingState": "VALID"}}


FAKE_ASC = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with open(os.environ["FAKE_ASC_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
scenario = json.loads(Path(os.environ["FAKE_ASC_SCENARIO"]).read_text())
state_path = Path(os.environ["FAKE_ASC_STATE"])
state = json.loads(state_path.read_text()) if state_path.exists() else {}
for number, route in enumerate(scenario):
    if args[:len(route["prefix"])] != route["prefix"]:
        continue
    key = str(number)
    index = state.get(key, 0)
    state[key] = index + 1
    state_path.write_text(json.dumps(state))
    reply = route["replies"][min(index, len(route["replies"]) - 1)]
    if "error" in reply:
        print(reply["error"], file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps(reply))
    raise SystemExit(0)
print("Unexpected ASC request: " + json.dumps(args), file=sys.stderr)
raise SystemExit(2)
'''


class FakeGitHub(BaseHTTPRequestHandler):
    routes = {}
    requests = []

    def do_GET(self):
        self.requests.append(self.path)
        body = self.routes.get(self.path)
        self.send_response(404 if body is None else 200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body or {"message": "Not Found"}).encode())

    def log_message(self, *args):
        pass


class TestFlightCommands(unittest.TestCase):
    def setUp(self):
        FakeGitHub.routes = {"/repos/AFK-surf/Cue/commits/heads/main": {"sha": SHA},
                             f"/repos/AFK-surf/Cue/compare/{SHA}...{SHA}": {"status": "identical"}}
        FakeGitHub.requests = []
        self.github = ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
        threading.Thread(target=self.github.serve_forever, daemon=True).start()
        self.addCleanup(self.github.server_close)
        self.addCleanup(self.github.shutdown)
        self.temporary = tempfile.TemporaryDirectory(prefix="comma-tf-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "asc").write_text(FAKE_ASC)
        (self.bin / "asc").chmod(0o700)
        (self.bin / "git").write_text(
            "#!/usr/bin/env python3\nimport os\nprint(os.environ['FAKE_SOURCE_SHA'])\n")
        (self.bin / "git").chmod(0o700)
        self.source = self.root / "source"
        apple = self.source / "clients/apps/apple"
        apple.mkdir(parents=True)
        (apple / "project.yml").write_text(
            'settings:\n  base:\n    MARKETING_VERSION: "1.0"\n    CURRENT_PROJECT_VERSION: "7"\n')
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        self.context_file = self.artifacts / "release-context.json"
        self.log_file = self.root / "requests.jsonl"
        self.scenario_file = self.root / "scenario.json"
        self.state_file = self.root / "state.json"
        self.outputs_file = self.root / "outputs.txt"
        self.summary_file = self.root / "summary.md"
        self.environment = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            FAKE_SOURCE_SHA=SHA, FAKE_ASC_LOG=str(self.log_file),
            FAKE_ASC_SCENARIO=str(self.scenario_file), FAKE_ASC_STATE=str(self.state_file),
            ASC_APP_ID=APP, APPLE_SOURCE_DIR=str(self.source),
            IOS_RELEASE_DIR=str(self.artifacts), IOS_RELEASE_CONTEXT=str(self.context_file),
            IOS_SOURCE_REF="main", IOS_VERSION_BUMP="none", IOS_BACKEND="staging",
            IOS_RESUME_BUILD_ID="", IOS_TEST_NOTES="", GITHUB_RUN_ATTEMPT="1",
            IOS_DISCOVERY_TIMEOUT_SECONDS="0", GITHUB_OUTPUT=str(self.outputs_file),
            GITHUB_STEP_SUMMARY=str(self.summary_file), GITHUB_REPOSITORY="AFK-surf/Cue",
            GITHUB_API_URL=f"http://127.0.0.1:{self.github.server_port}", GITHUB_TOKEN="test-token")
        for name in ("ASC_PRIVATE_KEY", "ASC_PRIVATE_KEY_B64", "ASC_PRIVATE_KEY_PATH", "IOS_TESTFLIGHT_GROUP"):
            self.environment.pop(name, None)

    def scenario(self, *routes):
        self.scenario_file.write_text(json.dumps(routes))
        self.state_file.unlink(missing_ok=True)

    def route(self, prefix, *replies):
        return {"prefix": prefix.split(), "replies": list(replies)}

    def run_command(self, command, success=True):
        result = subprocess.run([sys.executable, str(SCRIPT), command], env=self.environment,
                                capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def context(self):
        return json.loads(self.context_file.read_text())

    def requests(self):
        return [json.loads(line) for line in self.log_file.read_text().splitlines()] if self.log_file.exists() else []

    def resolved_context(self, **changes):
        context = {"app_id": APP, "group_id": GROUP["id"], "source_ref": "main", "source_sha": SHA,
            "backend": "staging", "api_base_url": "https://salix-staging.comma.surf",
            "version": "1.10.3", "build_number": "42", "test_notes": "", "upload_started": False,
            "resume_build_id": "", "status": "prepared"}
        context.update(changes)
        self.context_file.write_text(json.dumps(context))
        return context

    def test_default_keeps_numeric_latest_version_and_increments_build(self):
        self.environment.pop("IOS_VERSION_BUMP")
        self.scenario(
            self.route("testflight groups list", {"data": [GROUP]}),
            self.route("testflight pre-release list", {"data": [
                {"attributes": {"version": "1.9.0"}}, {"attributes": {"version": "1.10.0"}}]}),
            self.route("builds uploads list", {"data": [{"attributes": {"cfBundleShortVersionString": "1.10.2"}}]}),
            self.route("builds next-build-number", {"nextBuildNumber": "42"}))
        self.run_command("resolve")
        self.assertEqual((self.context()["version"], self.context()["build_number"]), ("1.10.2", "42"))
        self.assertIn("needs_build=true", self.outputs_file.read_text())

    def test_selected_bump_resets_lower_components_and_is_frozen_on_retry(self):
        for bump, expected in (("patch", "1.10.3"), ("minor", "1.11.0"), ("major", "2.0.0")):
            with self.subTest(bump=bump):
                self.context_file.unlink(missing_ok=True)
                self.environment.update(IOS_VERSION_BUMP=bump, IOS_BACKEND="production")
                self.scenario(self.route("testflight groups list", {"data": [GROUP]}),
                    self.route("testflight pre-release list", {"data": [{"attributes": {"version": "1.10.2"}}]}),
                    self.route("builds uploads list", {"data": []}),
                    self.route("builds next-build-number", {"nextBuildNumber": "43"}))
                self.run_command("resolve")
                context = self.context()
                self.assertEqual((context["version"], context["build_number"]), (expected, "43"))
                self.assertEqual(context["api_base_url"], "https://salix.comma.surf")
                self.assertEqual(context["source_sha"], SHA)
                self.environment.update(IOS_VERSION_BUMP="major", IOS_BACKEND="staging")
                self.scenario(self.route("testflight groups list", {"data": [GROUP]}))
                self.run_command("resolve")
                self.assertEqual(self.context(), context)

    def test_invalid_bump_stops_before_resolving_a_release(self):
        self.environment["IOS_VERSION_BUMP"] = "1.2.3"
        self.scenario(self.route("testflight groups list", {"data": [GROUP]}))
        self.assertIn("Version bump must be none, patch, minor, or major",
                      self.run_command("resolve", success=False).stderr)
        self.assertFalse(self.context_file.exists())

    def test_empty_testflight_uses_selected_project_version(self):
        self.scenario(self.route("testflight groups list", {"data": [GROUP]}),
            self.route("testflight pre-release list", {"data": []}),
            self.route("builds uploads list", {"data": []}),
            self.route("builds next-build-number", {"nextBuildNumber": "8"}))
        self.run_command("resolve")
        self.assertEqual(self.context()["version"], "1.0.0")
        self.assertIn("--initial-build-number", self.requests()[-1])
        self.assertEqual(self.requests()[-1][self.requests()[-1].index("--initial-build-number") + 1], "8")

    def test_project_version_bump_raises_the_automatic_baseline(self):
        (self.source / "clients/apps/apple/project.yml").write_text(
            'settings:\n  base:\n    MARKETING_VERSION: "1.1.0"\n    CURRENT_PROJECT_VERSION: "7"\n')
        self.scenario(self.route("testflight groups list", {"data": [GROUP]}),
            self.route("testflight pre-release list", {"data": [{"attributes": {"version": "1.0.4"}}]}),
            self.route("builds uploads list", {"data": []}),
            self.route("builds next-build-number", {"nextBuildNumber": "8"}))
        self.run_command("resolve")
        self.assertEqual(self.context()["version"], "1.1.0")

    def test_source_accepts_main_and_tags_on_main_only(self):
        tag_sha, side_sha = "c" * 40, "d" * 40
        FakeGitHub.routes.update({
            "/repos/AFK-surf/Cue/git/ref/tags/v1.2": {"object": {"type": "tag", "sha": "e" * 40}},
            f"/repos/AFK-surf/Cue/git/tags/{'e' * 40}": {"object": {"type": "commit", "sha": tag_sha}},
            f"/repos/AFK-surf/Cue/compare/{SHA}...{tag_sha}": {"status": "behind"},
            "/repos/AFK-surf/Cue/git/ref/tags/side": {"object": {"type": "commit", "sha": side_sha}},
            f"/repos/AFK-surf/Cue/compare/{SHA}...{side_sha}": {"status": "diverged"}})
        self.run_command("source-ref")
        self.assertIn(f"source_ref={SHA}", self.outputs_file.read_text())
        self.environment["IOS_SOURCE_REF"] = "v1.2"
        self.run_command("source-ref")
        self.assertIn(f"source_ref={tag_sha}", self.outputs_file.read_text())
        for ref, message in (("side", "already be on main"), ("feature/ios", "main or an existing tag"),
                             (SHA, "main or an existing tag"), ("../commits/heads/main", "main or a tag name")):
            self.environment["IOS_SOURCE_REF"] = ref
            self.assertIn(message, self.run_command("source-ref", success=False).stderr)
        self.resolved_context(source_sha=side_sha)
        self.assertIn("already be on main", self.run_command("source-ref", success=False).stderr)

    def test_restored_release_ignores_new_inputs_and_rejects_wrong_source_or_group(self):
        original = self.resolved_context(upload_started=True, upload_attempt=1)
        self.environment.update(IOS_VERSION_BUMP="major", IOS_BACKEND="production", IOS_SOURCE_REF="another-branch")
        self.scenario(self.route("testflight groups list", {"data": [GROUP]}))
        self.run_command("source-ref")
        self.assertIn(f"source_ref={SHA}", self.outputs_file.read_text())
        self.run_command("resolve")
        self.assertEqual(self.context(), original)
        self.assertIn("needs_build=false", self.outputs_file.read_text())
        self.environment["FAKE_SOURCE_SHA"] = "b" * 40
        self.assertIn("frozen source", self.run_command("resolve", success=False).stderr)
        self.environment["FAKE_SOURCE_SHA"] = SHA
        self.scenario(self.route("testflight groups list", {"data": [{**GROUP, "id": "replacement-group"}]}))
        self.assertIn("frozen internal tester group", self.run_command("resolve", success=False).stderr)

    def test_prepare_records_one_upload_intent_and_preserves_it_on_retry(self):
        self.resolved_context()
        self.assertIn("Signed Comma.ipa is unavailable", self.run_command("prepare-publish", success=False).stderr)
        self.assertFalse(self.context()["upload_started"])
        (self.artifacts / "Comma.ipa").write_bytes(b"local test fixture")
        self.scenario(self.route("builds list", {"data": []}),
                      self.route("builds uploads list", {"data": []}))
        self.run_command("prepare-publish")
        original = self.context()
        self.assertTrue(original["upload_started"])
        self.assertEqual(original["upload_attempt"], 1)
        self.assertIn("upload_marker_needed=true", self.outputs_file.read_text())
        self.environment["GITHUB_RUN_ATTEMPT"] = "2"
        self.run_command("prepare-publish")
        self.assertEqual(self.context(), original)
        self.assertTrue(self.outputs_file.read_text().endswith("upload_marker_needed=false\n"))

    def test_known_number_conflicts_stop_before_marker_and_still_stop_on_rerun(self):
        pending = {"id": "other-upload", "attributes": {
            "cfBundleShortVersionString": "1.10.3", "cfBundleVersion": "42"}}
        for kind in ("build", "pending upload"):
            with self.subTest(conflict=kind):
                original = self.resolved_context()
                (self.artifacts / "Comma.ipa").write_bytes(b"this run's IPA")
                self.outputs_file.unlink(missing_ok=True)
                self.log_file.unlink(missing_ok=True)
                self.scenario(self.route("builds list", {"data": [BUILD] if kind == "build" else []}),
                    self.route("builds uploads list", {"data": [pending] if kind == "pending upload" else []}),
                    self.route("builds wait", {}), self.route("publish testflight", {}))
                for attempt in ("1", "2"):
                    self.environment["GITHUB_RUN_ATTEMPT"] = attempt
                    result = self.run_command("prepare-publish", success=False)
                    self.assertIn("already in use", result.stderr)
                    self.assertEqual(self.context(), original)
                    self.run_command("publish", success=False)
                self.assertFalse(self.outputs_file.exists())
                self.assertFalse(any(request[:2] in (["builds", "upload"], ["publish", "testflight"])
                                     for request in self.requests()))
                if kind == "pending upload":
                    query = next(request for request in self.requests() if request[:3] == ["builds", "uploads", "list"])
                    for flag, value in (("--app", APP), ("--platform", "IOS"),
                                        ("--cf-bundle-short-version", "1.10.3"), ("--cf-bundle-version", "42")):
                        self.assertEqual(query[query.index(flag) + 1], value)

    def test_upload_timeout_is_reconciled_without_reupload_on_next_attempt(self):
        self.resolved_context(upload_started=True, upload_attempt=1)
        self.scenario(self.route("builds list", {"data": []}),
            self.route("builds uploads list", {"data": []}),
            self.route("builds upload", {}))
        spec = importlib.util.spec_from_file_location("testflight_release_under_test", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        real_run = subprocess.run
        def upload_outlives_budget(arguments, **kwargs):
            result = real_run(arguments, **kwargs)
            if arguments[:3] == ["asc", "builds", "upload"]:
                # The upload reached ASC, but its time budget ran out first.
                raise subprocess.TimeoutExpired(arguments, kwargs["timeout"])
            return result
        with mock.patch.dict(os.environ, self.environment, clear=True), \
             mock.patch.object(module.subprocess, "run", upload_outlives_budget):
            with self.assertRaisesRegex(module.ReleaseError, "exceeded its time budget"):
                module.publish()
        self.assertIn("unknown", self.context()["status"])
        self.assertEqual(sum(request[:2] == ["builds", "upload"] for request in self.requests()), 1)
        self.environment["GITHUB_RUN_ATTEMPT"] = "2"
        self.assertIn("not exposed", self.run_command("publish", success=False).stderr)
        self.assertEqual(sum(request[:2] == ["builds", "upload"] for request in self.requests()), 1)
        self.assertEqual(self.context()["status"], "upload outcome unresolved")
        self.scenario(self.route("builds list", {"data": [BUILD]}),
            self.route("builds wait", {}), self.route("publish testflight", {}))
        self.run_command("publish")
        self.assertEqual(self.context()["status"], "available to Internal Testers")
        self.assertEqual(sum(request[:2] == ["builds", "upload"] for request in self.requests()), 1)

    def test_first_publish_uploads_the_signed_ipa_despite_a_build_appearing_after_marker(self):
        self.resolved_context()
        ipa = self.artifacts / "Comma.ipa"
        ipa.write_bytes(b"local test fixture")
        self.scenario(self.route("builds list", {"data": []}),
                      self.route("builds uploads list", {"data": []}))
        self.run_command("prepare-publish")
        self.log_file.unlink(missing_ok=True)
        self.scenario(self.route("builds list", {"data": [BUILD]}),
            self.route("builds uploads list", {"data": []}),
            self.route("builds upload", {"uploadID": "accepted-upload"}),
            self.route("builds wait", {}), self.route("publish testflight", {}))
        self.run_command("publish")
        uploads = [request for request in self.requests() if request[:2] == ["builds", "upload"]]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0][uploads[0].index("--ipa") + 1], str(ipa))
        self.assertEqual(uploads[0][uploads[0].index("--app") + 1], APP)
        self.assertEqual(self.requests()[0][:2], ["builds", "upload"])
        self.assertEqual(self.context()["build_id"], BUILD["id"])
        self.assertEqual(self.context()["status"], "available to Internal Testers")

    def test_failed_current_upload_does_not_distribute_the_competing_existing_build(self):
        for competitor in ("build", "pending upload"):
            with self.subTest(competitor=competitor):
                self.resolved_context(upload_started=True, upload_attempt=1)
                (self.artifacts / "Comma.ipa").write_bytes(b"this run's IPA")
                self.log_file.unlink(missing_ok=True)
                self.scenario(self.route("builds list", {"data": [BUILD] if competitor == "build" else []}),
                    self.route("builds uploads list", {"data": [{"id": "competing-upload"}]}),
                    self.route("builds upload", {"error": "duplicate build number"}),
                    self.route("builds wait", {}), self.route("publish testflight", {}))
                self.assertIn("duplicate build number", self.run_command("publish", success=False).stderr)
                self.assertEqual(sum(request[:2] == ["builds", "upload"] for request in self.requests()), 1)
                self.assertFalse(any(request[:2] in (["builds", "wait"], ["publish", "testflight"])
                                     for request in self.requests()))
                self.assertIn("unknown", self.context()["status"])

    def test_invalid_processing_stops_before_distribution(self):
        self.resolved_context(upload_started=True, upload_attempt=1)
        self.environment["GITHUB_RUN_ATTEMPT"] = "2"
        self.scenario(self.route("builds list", {"data": [BUILD]}),
            self.route("builds wait", {"error": "build processing state INVALID"}))
        self.assertIn("INVALID", self.run_command("publish", success=False).stderr)
        self.assertIn("--fail-on-invalid", self.requests()[-1])
        self.assertFalse(any(request[:2] == ["publish", "testflight"] for request in self.requests()))
        self.run_command("summary")
        self.assertIn("failed", self.summary_file.read_text())

    def test_retry_reconciles_exact_build_without_upload_and_preserves_notes(self):
        notes = 'Line one\n"quoted"; $(touch /tmp/never-run)'
        self.resolved_context(upload_started=True, upload_attempt=1, test_notes=notes)
        self.environment["GITHUB_RUN_ATTEMPT"] = "2"
        self.scenario(self.route("builds list", {"data": [BUILD]}),
            self.route("builds wait", {}), self.route("publish testflight", {}))
        self.run_command("publish")
        self.assertFalse(any(request[:2] == ["builds", "upload"] for request in self.requests()))
        distribution = self.requests()[-1]
        self.assertEqual(distribution[distribution.index("--test-notes") + 1], notes)
        self.assertEqual(distribution[distribution.index("--group") + 1], GROUP["id"])
        self.assertEqual(self.context()["build_id"], BUILD["id"])
        self.assertIn("tuple", self.context().get("origin", ""))
        self.assertIn("source and backend are not independently verified", self.context().get("origin", ""))
        self.run_command("summary")
        summary = self.summary_file.read_text()
        self.assertIn("source and backend are not independently verified", summary)
        self.assertNotIn("- Source:", summary)
        self.assertNotIn("- Backend:", summary)

    def test_resumed_build_checks_app_and_platform_and_reports_unknown_origin(self):
        self.environment["IOS_RESUME_BUILD_ID"] = BUILD["id"]
        def scenario(app=APP, platform="IOS"):
            self.scenario(self.route("testflight groups list", {"data": [GROUP]}),
                self.route("builds app view", {"data": {"id": app}}),
                self.route("builds info", {"data": BUILD}),
                self.route("builds pre-release-version view", {"data": {"attributes": {
                    "version": "1.10.3", "platform": platform}}}))
        scenario(app="other-app")
        self.assertIn("another App Store Connect app", self.run_command("resolve", success=False).stderr)
        scenario(platform="MAC_OS")
        self.assertIn("must be an iOS build", self.run_command("resolve", success=False).stderr)
        self.environment["IOS_VERSION_BUMP"] = "patch"
        scenario()
        self.assertIn("Version bump must be none when resuming an existing build",
                      self.run_command("resolve", success=False).stderr)
        self.assertFalse(self.context_file.exists())
        self.environment["IOS_VERSION_BUMP"] = "none"
        scenario()
        result = self.run_command("resolve")
        self.assertIn("not verified", result.stdout)
        self.assertNotIn("backend staging", result.stdout)
        self.assertEqual(self.context()["build_number"], "42")
        self.assertIn("needs_build=false", self.outputs_file.read_text())
        self.run_command("summary")
        summary = self.summary_file.read_text()
        self.assertIn("source and backend are not verified", summary)
        self.assertNotIn("- Source:", summary)
        self.assertNotIn("- Backend:", summary)
        self.log_file.unlink()
        self.scenario(self.route("builds wait", {}), self.route("publish testflight", {}))
        self.run_command("prepare-publish")
        self.run_command("publish")
        self.assertEqual(self.requests()[0][:2], ["builds", "wait"])
        self.assertEqual(self.context()["build_id"], BUILD["id"])
        distribution = self.requests()[-1]
        self.assertEqual(distribution[distribution.index("--group") + 1], GROUP["id"])
        self.assertFalse(any(request[:2] == ["builds", "upload"] for request in self.requests()))


if __name__ == "__main__":
    unittest.main()
