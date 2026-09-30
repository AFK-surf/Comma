#!/usr/bin/env python3
"""Contract tests for the BFT runner device provisioning installer."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import platform
import plistlib
import pwd
import shlex
import shutil
import stat
import subprocess
import tempfile
import unittest
import urllib.parse
import zipfile


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
INSTALLER = REPO_ROOT / "systems" / "connector" / "mac-mini-provisioner-install.sh"
SERVICE_ARGS = f"--service-type agent --service-user {pwd.getpwuid(os.getuid()).pw_name}"


def write_executable(path: pathlib.Path, body: str) -> str:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_worker(path: pathlib.Path) -> str:
    return write_executable(
        path,
        "#!/bin/sh\nprintf 'fake bft runner\\n'\n",
    )


def write_worker_recorder(path: pathlib.Path, log_path: pathlib.Path) -> str:
    return write_executable(
        path,
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$*\" >> {str(log_path)!r}\n"
        "printf 'fake bft runner\\n'\n",
    )


def write_host_runtime_archive(
    archive_path: pathlib.Path,
    log_path: pathlib.Path,
    ready: bool = True,
    ready_after_status_checks: int = 0,
    install_error: str | None = None,
    version_side_effect: pathlib.Path | None = None,
    ready_after_repair: bool = False,
) -> str:
    app = archive_path.parent / "Agent VMM Host.app"
    helper = app / "Contents" / "Helpers" / "agent-vmm-lifecycle"
    cli = app / "Contents" / "Helpers" / "agent-vmm"
    executor = app / "Contents" / "Helpers" / "agent-vmm-service-executor"
    executable = app / "Contents" / "MacOS" / "agent-vmm-host"
    status = {
        "hostInstalled": True,
        "hostLoaded": True,
        "hostReadable": True,
        "hostHealthy": ready,
        # Org-scoped runner onboarding prepares the shared Host only. The
        # project-scoped compute-node operation installs the appliance and
        # attaches the exact external registration later.
        "applianceInstalled": False,
        "applianceHealthy": False,
        "controllerActive": False,
        "inventoryComplete": False,
    }
    helper.parent.mkdir(parents=True, exist_ok=True)
    executable.parent.mkdir(parents=True, exist_ok=True)
    install_failure = ""
    if install_error is not None:
        install_failure = (
            "if [ \"${1:-}\" = install ]; then "
            f"printf '%s\\n' {shlex.quote(install_error)} >&2; exit 1; fi\n"
        )
    repair_marker = archive_path.parent / "agent-vmm-repair-complete"
    repair_status = ""
    if ready_after_repair:
        not_ready = dict(status)
        not_ready["hostHealthy"] = False
        repair_status = (
            "if [ \"${1:-}\" = repair ]; then "
            f"touch {shlex.quote(str(repair_marker))}; fi\n"
            "if [ \"${1:-}\" = status ] && "
            f"[ ! -e {shlex.quote(str(repair_marker))} ]; then "
            f"printf '%s\\n' {shlex.quote(json.dumps(not_ready))}; exit 0; fi\n"
        )
    status_counter = archive_path.parent / "agent-vmm-status-count"
    delayed_status = ""
    if ready and ready_after_status_checks > 0:
        not_ready = dict(status)
        not_ready["hostHealthy"] = False
        delayed_status = (
            "if [ \"${1:-}\" = status ]; then\n"
            f"count=$(cat {shlex.quote(str(status_counter))} 2>/dev/null || printf 0)\n"
            "count=$((count + 1))\n"
            f"printf '%s' \"$count\" > {shlex.quote(str(status_counter))}\n"
            f"if [ \"$count\" -le {ready_after_status_checks} ]; then "
            f"printf '%s\\n' {shlex.quote(json.dumps(not_ready))}; exit 0; fi\n"
            "fi\n"
        )
    version_command = ""
    if version_side_effect is not None:
        version_command = f"touch {shlex.quote(str(version_side_effect))}; "
    write_executable(
        helper,
        "#!/bin/sh\n"
        f"if [ \"${{1:-}}\" = version ]; then {version_command}printf '%s\\n' '{{\"component\":\"agent-vmm-host\",\"version\":\"release-test\",\"release_id\":\"release-test\"}}'; exit 0; fi\n"
        f"printf '%s\\n' \"$*\" >> {shlex.quote(str(log_path))}\n"
        f"{install_failure}"
        f"{repair_status}"
        f"{delayed_status}"
        f"if [ \"${{1:-}}\" = status ]; then printf '%s\\n' {shlex.quote(json.dumps(status))}; fi\n",
    )
    write_executable(cli, "#!/bin/sh\nexit 0\n")
    write_executable(executor, "#!/bin/sh\nexit 0\n")
    write_executable(executable, "#!/bin/sh\nexit 0\n")
    with zipfile.ZipFile(archive_path, "w") as archive:
        for path in sorted(app.rglob("*")):
            archive.write(path, path.relative_to(archive_path.parent))
    shutil.rmtree(app)
    return hashlib.sha256(archive_path.read_bytes()).hexdigest()


def write_fake_host_tools(command_dir: pathlib.Path) -> None:
    write_executable(
        command_dir / "codesign",
        "#!/bin/sh\nexit 0\n",
    )
    write_executable(command_dir / "sleep", "#!/bin/sh\nexit 0\n")
    write_executable(
        command_dir / "ditto",
        "#!/bin/sh\n"
        "set -eu\n"
        "if [ \"${1:-}\" = -x ]; then\n"
        "  python3 - \"$3\" \"$4\" <<'PY'\n"
        "import os, sys, zipfile\n"
        "with zipfile.ZipFile(sys.argv[1]) as archive: archive.extractall(sys.argv[2])\n"
        "for root, _, files in os.walk(sys.argv[2]):\n"
        "    for name in files:\n"
        "        path = os.path.join(root, name)\n"
        "        os.chmod(path, os.stat(path).st_mode | 0o111)\n"
        "PY\n"
        "else\n"
        "  cp -R \"$1\" \"$2\"\n"
        "fi\n",
    )


def agent_vmm_host_env(
    root: pathlib.Path,
    artifact_dir: pathlib.Path,
    command_prefix: pathlib.Path | None = None,
) -> dict[str, str]:
    command_dir = root / "host-tools"
    command_dir.mkdir(exist_ok=True)
    write_fake_host_tools(command_dir)
    archive = artifact_dir / "agent-vmm-host.zip"
    host_sha = write_host_runtime_archive(archive, root / "host-lifecycle.log")
    path_parts = [str(command_dir)]
    if command_prefix is not None:
        path_parts.append(str(command_prefix))
    path_parts.append(os.environ["PATH"])
    return {
        "PATH": ":".join(path_parts),
        "BFT_AGENT_VMM_HOST_URL": archive.as_uri(),
        "BFT_AGENT_VMM_HOST_SHA256": host_sha,
        "BFT_AGENT_VMM_HOST_SIZE": str(archive.stat().st_size),
    }


def installer_platform() -> str:
    os_name = platform.system().lower()
    machine = platform.machine().lower()

    if os_name == "darwin":
        goos = "darwin"
    elif os_name == "linux":
        goos = "linux"
    else:
        raise AssertionError(f"unsupported test OS: {os_name}")

    if machine in ("x86_64", "amd64"):
        goarch = "amd64"
    elif machine in ("arm64", "aarch64"):
        goarch = "arm64"
    else:
        raise AssertionError(f"unsupported test arch: {machine}")

    return f"{goos}-{goarch}"


def write_fake_launchctl(path: pathlib.Path, log_path: pathlib.Path) -> str:
    return write_executable(
        path,
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$*\" >> {str(log_path)!r}\n"
        "case \"$1\" in\n"
        "  print) printf 'fake launchd service\\n' ;;\n"
        "esac\n",
    )


class MacMiniProvisionerInstallTest(unittest.TestCase):
    def run_installer(
        self, env: dict[str, str], installer: pathlib.Path = INSTALLER
    ) -> subprocess.CompletedProcess[str]:
        merged = os.environ.copy()
        merged["BFT_AGENT_VMM_SERVICE_TYPE"] = "agent"
        merged.update(env)
        for url_key, size_key in (
            ("BFT_RUNNER_URL", "BFT_RUNNER_SIZE"),
            ("BFT_SALIX_CONNECTOR_URL", "BFT_SALIX_CONNECTOR_SIZE"),
            ("BFT_AGENT_VMM_HOST_URL", "BFT_AGENT_VMM_HOST_SIZE"),
        ):
            raw_url = merged.get(url_key)
            if raw_url and size_key not in merged:
                parsed = urllib.parse.urlparse(raw_url)
                if parsed.scheme == "file":
                    merged[size_key] = str(
                        pathlib.Path(urllib.parse.unquote(parsed.path)).stat().st_size
                    )
        return subprocess.run(
            ["sh", str(installer)],
            cwd=str(REPO_ROOT),
            env=merged,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_downloads_salix_connect_without_echoing_token(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            prefix = root / "install"

            connector_sha = write_executable(
                artifacts / "salix-connector",
                "#!/bin/sh\nprintf 'fake salix connector\\n'\n",
            )
            worker_sha = write_worker(artifacts / "mac-mini-provisioner")
            secret = "bft_secret_token_should_not_be_logged"

            proc = self.run_installer(
                {
                    "HOME": str(root / "home"),
                    "BFT_INSTALL_PREFIX": str(prefix),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    **agent_vmm_host_env(root, artifacts),
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                    "BFT_RUNNER_SHA256": worker_sha,
                    "BFT_API_BASE_URL": "https://bridge.example.test",
                    "BFT_ORG_ID": "org_test",
                    "BFT_RUNNER_TOKEN": secret,
                    "BFT_RUNNER_STABLE_ID": "lab-mac-mini",
                    "BFT_RUNNER_NAME": "Lab Runner",
                }
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertNotIn(secret, proc.stdout)
            self.assertNotIn(secret, proc.stderr)

            salix_connect = prefix / "bin" / "salix-connect"
            runner = prefix / "bin" / "bft-runner"
            self.assertTrue(os.access(salix_connect, os.X_OK))
            self.assertTrue(os.access(runner, os.X_OK))
            for installed in (salix_connect, runner):
                self.assertFalse(
                    pathlib.Path(str(installed) + ".sha256").exists(),
                    f"local checksum sidecar must not be written: {installed}",
                )
            self.assertEqual(hashlib.sha256(salix_connect.read_bytes()).hexdigest(), connector_sha)
            self.assertEqual(
                hashlib.sha256(runner.read_bytes()).hexdigest(), worker_sha
            )

            config = json.loads((prefix / "runner.json").read_text(encoding="utf-8"))
            status_payload = json.loads(
                (prefix / "runner-install-status.json").read_text(encoding="utf-8")
            )
            launchd_plist = prefix / "com.bridgeforteams.runner.plist"
            launchd_payload = plistlib.loads(launchd_plist.read_bytes())

            self.assertEqual(config["runner_token"], secret)
            self.assertEqual(config["paths"]["salix_connect"], str(salix_connect))
            self.assertEqual(config["paths"]["runner"], str(runner))
            self.assertEqual(status_payload["status"], "ready")
            self.assertEqual(status_payload["install"]["runner_source"], "download")
            self.assertEqual(status_payload["install"]["fallback_tooling_source"], "skipped")
            self.assertEqual(status_payload["launchd"]["plist"], str(launchd_plist))
            self.assertFalse(status_payload["launchd"]["installed"])
            self.assertFalse(status_payload["launchd"]["loaded"])
            self.assertNotIn(secret, json.dumps(status_payload))
            self.assertNotIn(secret, json.dumps(launchd_payload))

            self.assertEqual(
                launchd_payload["ProgramArguments"],
                [
                    str(runner),
                ],
            )
            self.assertTrue(launchd_payload["KeepAlive"])
            self.assertTrue(launchd_payload["RunAtLoad"])
            self.assertEqual(launchd_payload["SoftResourceLimits"]["NumberOfFiles"], 65536)
            self.assertEqual(launchd_payload["HardResourceLimits"]["NumberOfFiles"], 524288)
            launchd_path = launchd_payload["EnvironmentVariables"]["PATH"].split(":")
            self.assertEqual(launchd_path[0], str(prefix / "bin"))
            self.assertIn("/Applications/LibreOffice.app/Contents/MacOS", launchd_path)

            config_mode = stat.S_IMODE((prefix / "runner.json").stat().st_mode)
            self.assertEqual(config_mode, 0o600)

            self.assertNotIn(secret, runner.read_text(encoding="utf-8"))

    def test_server_runner_identity_replaces_stale_local_identity_on_reinstall(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            prefix = root / "install"
            prefix.mkdir()
            (prefix / "runner.json").write_text(
                json.dumps(
                    {
                        "runner": {
                            "stable_id": "stale-local-runner",
                            "name": "Lab Runner",
                        }
                    }
                ),
                encoding="utf-8",
            )

            connector_sha = write_executable(
                artifacts / "salix-connector",
                "#!/bin/sh\nprintf 'fake salix connector\\n'\n",
            )
            worker_sha = write_worker(artifacts / "mac-mini-provisioner")

            proc = self.run_installer(
                {
                    "HOME": str(root / "home"),
                    "BFT_INSTALL_PREFIX": str(prefix),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    **agent_vmm_host_env(root, artifacts),
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                    "BFT_RUNNER_SHA256": worker_sha,
                    "BFT_API_BASE_URL": "https://bridge.example.test",
                    "BFT_ORG_ID": "org_test",
                    "BFT_RUNNER_TOKEN": "runner-token",
                    "BFT_RUNNER_STABLE_ID": "server-authoritative-runner",
                }
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            config = json.loads((prefix / "runner.json").read_text(encoding="utf-8"))
            self.assertEqual(
                config["runner"]["stable_id"], "server-authoritative-runner"
            )

    def test_rejects_oversized_and_undersized_artifacts_before_install(self) -> None:
        for delta, detail in ((-1, "exceeds expected size"), (1, "smaller than expected size")):
            with self.subTest(delta=delta), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                artifacts = root / "artifacts"
                artifacts.mkdir()
                prefix = root / "install"
                connector_sha = write_executable(
                    artifacts / "salix-connector", "#!/bin/sh\nexit 0\n"
                )
                connector_size = (artifacts / "salix-connector").stat().st_size

                proc = self.run_installer(
                    {
                        "HOME": str(root / "home"),
                        "BFT_INSTALL_PREFIX": str(prefix),
                        "BFT_SALIX_CONNECTOR_URL": (
                            artifacts / "salix-connector"
                        ).as_uri(),
                        "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                        "BFT_SALIX_CONNECTOR_SIZE": str(connector_size + delta),
                    }
                )

                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("preflight.salix_connect_size_mismatch", proc.stderr)
                self.assertIn(detail, proc.stderr)
                self.assertFalse((prefix / "bin" / "salix-connect").exists())

    def test_installs_shared_host_runtime_and_observes_readiness(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            command_dir = root / "commands"
            artifacts.mkdir()
            command_dir.mkdir()
            prefix = root / "install"
            host_log = root / "host-lifecycle.log"
            write_fake_host_tools(command_dir)

            connector_sha = write_executable(
                artifacts / "salix-connector",
                "#!/bin/sh\nprintf 'fake salix connector\\n'\n",
            )
            worker_sha = write_worker(artifacts / "mac-mini-provisioner")
            host_sha = write_host_runtime_archive(artifacts / "agent-vmm-host.zip", host_log)

            install_env = {
                    "HOME": str(root / "home"),
                    "PATH": f"{command_dir}:{os.environ['PATH']}",
                    "BFT_INSTALL_PREFIX": str(prefix),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    "BFT_AGENT_VMM_HOST_URL": (artifacts / "agent-vmm-host.zip").as_uri(),
                    "BFT_AGENT_VMM_HOST_SHA256": host_sha,
                    "BFT_AGENT_VMM_SERVICE_TYPE": "auto",
                    "BFT_VMM_REQUEST_ID": "bft-host-install-test",
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                    "BFT_RUNNER_SHA256": worker_sha,
                }
            proc = self.run_installer(install_env)

            self.assertEqual(proc.returncode, 0, proc.stderr)
            host_app = (
                root
                / "home"
                / "Library"
                / "Application Support"
                / "Agent VMM Host"
                / "current"
                / "Agent VMM Host.app"
            )
            self.assertTrue((host_app / "Contents" / "MacOS" / "agent-vmm-host").exists())
            self.assertEqual(
                host_log.read_text(encoding="utf-8").splitlines(),
                [
                    f"install --service-type agent --service-user {pwd.getpwuid(os.getuid()).pw_name} --request-id bft-host-install-test-install",
                    f"status --service-type agent --service-user {pwd.getpwuid(os.getuid()).pw_name}",
                ],
            )
            self.assertFalse((root / "home" / "Applications" / "Agent VMM.app").exists())

            config = json.loads((prefix / "runner.json").read_text(encoding="utf-8"))
            self.assertEqual(config["launchd"]["domain"], f"gui/{os.getuid()}")
            self.assertEqual(
                config["launchd"]["service_user"],
                pwd.getpwuid(os.getuid()).pw_name,
            )
            self.assertEqual(
                config["paths"]["host_runtime_lifecycle"],
                str(host_app / "Contents" / "Helpers" / "agent-vmm-lifecycle"),
            )
            self.assertEqual(
                config["paths"]["host_runtime_cli"],
                str(host_app / "Contents" / "Helpers" / "agent-vmm"),
            )

            helper = host_app / "Contents" / "Helpers" / "agent-vmm-lifecycle"
            install_env.pop("BFT_VMM_REQUEST_ID")
            host_log.write_text("", encoding="utf-8")
            proc = self.run_installer(install_env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(host_log.read_text(encoding="utf-8").splitlines(), [f"status {SERVICE_ARGS}"])
            self.assertFalse(any(host_app.parent.glob(".Agent VMM Host.*.app")))

            marker = host_app / "old-generation"
            marker.write_text("retained", encoding="utf-8")
            original = helper.read_text(encoding="utf-8")
            helper.write_text(
                "#!/bin/sh\n"
                "if [ \"${1:-}\" = version ]; then printf '%s\\n' '{\"release_id\":\"release-old\"}'; exit 0; fi\n"
                f"test -f {shlex.quote(str(marker))} || exit 32\n" + original,
                encoding="utf-8",
            )
            ids = []
            for _ in range(2):
                host_log.write_text("", encoding="utf-8")
                proc = self.run_installer(install_env)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                lines = host_log.read_text(encoding="utf-8").splitlines()
                self.assertTrue(lines[0].startswith("update --source-app "), lines)
                self.assertEqual(lines[1], f"status {SERVICE_ARGS}")
                arguments = lines[0].split()
                request_id = arguments[arguments.index("--request-id") + 1]
                self.assertIn("--target-release-id release-test", lines[0])
                ids.append(request_id)
            self.assertEqual(ids[0], ids[1])
            self.assertEqual(ids[0], f"bft-host-{host_sha}-update")
            marker.write_text("retained", encoding="utf-8")
            write_executable(helper, "#!/bin/sh\nprintf 'disk still owned\n' >&2\nexit 1\n")
            proc = self.run_installer(install_env)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("install.agent_vmm_host_update_failed", proc.stderr)
            self.assertEqual(marker.read_text(encoding="utf-8"), "retained")
            self.assertIn("disk still owned", helper.read_text(encoding="utf-8"))

    def test_rejects_unsigned_host_before_executing_staged_helper(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            command_dir = root / "commands"
            artifacts.mkdir()
            command_dir.mkdir()
            write_fake_host_tools(command_dir)
            write_executable(command_dir / "codesign", "#!/bin/sh\nexit 1\n")
            connector_sha = write_executable(artifacts / "salix-connector", "#!/bin/sh\n")
            worker_sha = write_worker(artifacts / "mac-mini-provisioner")
            execution_marker = root / "staged-helper-executed"
            host_sha = write_host_runtime_archive(
                artifacts / "agent-vmm-host.zip",
                root / "host-lifecycle.log",
                version_side_effect=execution_marker,
            )

            proc = self.run_installer(
                {
                    "HOME": str(root / "home"),
                    "PATH": f"{command_dir}:{os.environ['PATH']}",
                    "BFT_INSTALL_PREFIX": str(root / "install"),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    "BFT_AGENT_VMM_HOST_URL": (artifacts / "agent-vmm-host.zip").as_uri(),
                    "BFT_AGENT_VMM_HOST_SHA256": host_sha,
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                    "BFT_RUNNER_SHA256": worker_sha,
                }
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("preflight.agent_vmm_host_signature_invalid", proc.stderr)
            self.assertFalse(execution_marker.exists())

    def test_host_runtime_install_failure_retains_local_forward_repair_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            command_dir = root / "commands"
            artifacts.mkdir()
            command_dir.mkdir()
            write_fake_host_tools(command_dir)
            connector_sha = write_executable(artifacts / "salix-connector", "#!/bin/sh\n")
            worker_sha = write_worker(artifacts / "mac-mini-provisioner")
            host_log = root / "host-lifecycle.log"
            diagnostic = (
                '{"failureStage":"install","failureCode":"VM_START_FAILED",'
                '"failureMessage":"Virtualization is not available on this hardware"}'
            )
            host_sha = write_host_runtime_archive(
                artifacts / "agent-vmm-host.zip",
                host_log,
                install_error=diagnostic,
            )

            proc = self.run_installer(
                {
                    "HOME": str(root / "home"),
                    "PATH": f"{command_dir}:{os.environ['PATH']}",
                    "BFT_INSTALL_PREFIX": str(root / "install"),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    "BFT_AGENT_VMM_HOST_URL": (artifacts / "agent-vmm-host.zip").as_uri(),
                    "BFT_AGENT_VMM_HOST_SHA256": host_sha,
                    "BFT_VMM_REQUEST_ID": "bft-host-install-test",
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                    "BFT_RUNNER_SHA256": worker_sha,
                }
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn(diagnostic, proc.stderr)
            self.assertEqual(
                host_log.read_text(encoding="utf-8").splitlines(),
                [f"install {SERVICE_ARGS} --request-id bft-host-install-test-install"],
            )
            host_app = (
                root
                / "home"
                / "Library"
                / "Application Support"
                / "Agent VMM Host"
                / "current"
                / "Agent VMM Host.app"
            )
            self.assertTrue(host_app.exists())

    def test_host_runtime_install_rerun_repairs_same_release(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            command_dir = root / "commands"
            artifacts.mkdir()
            command_dir.mkdir()
            write_fake_host_tools(command_dir)
            connector_sha = write_executable(artifacts / "salix-connector", "#!/bin/sh\n")
            worker_sha = write_worker(artifacts / "mac-mini-provisioner")
            host_log = root / "host-lifecycle.log"
            host_sha = write_host_runtime_archive(
                artifacts / "agent-vmm-host.zip",
                host_log,
                install_error="first install failed",
                ready_after_repair=True,
            )
            install_env = {
                "HOME": str(root / "home"),
                "PATH": f"{command_dir}:{os.environ['PATH']}",
                "BFT_INSTALL_PREFIX": str(root / "install"),
                "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                "BFT_AGENT_VMM_HOST_URL": (artifacts / "agent-vmm-host.zip").as_uri(),
                "BFT_AGENT_VMM_HOST_SHA256": host_sha,
                "BFT_VMM_REQUEST_ID": "bft-host-recovery-test",
                "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                "BFT_RUNNER_SHA256": worker_sha,
            }

            first = self.run_installer(install_env)
            self.assertNotEqual(first.returncode, 0)
            self.assertIn("install.agent_vmm_host_install_failed", first.stderr)

            second = self.run_installer(install_env)
            self.assertEqual(second.returncode, 0, second.stderr)
            lines = host_log.read_text(encoding="utf-8").splitlines()
            self.assertIn(
                f"repair {SERVICE_ARGS} --request-id bft-host-recovery-test-repair",
                lines,
            )
            self.assertEqual(lines[-1], f"status {SERVICE_ARGS}")

    def test_host_runtime_update_failure_preserves_current_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            command_dir = root / "commands"
            artifacts.mkdir()
            command_dir.mkdir()
            write_fake_host_tools(command_dir)
            connector_sha = write_executable(artifacts / "salix-connector", "#!/bin/sh\n")
            worker_sha = write_worker(artifacts / "mac-mini-provisioner")
            new_log = root / "new-host-lifecycle.log"
            host_sha = write_host_runtime_archive(
                artifacts / "agent-vmm-host.zip",
                new_log,
                install_error="new Host install failed",
            )
            home = root / "home"
            old_app = (
                home
                / "Library"
                / "Application Support"
                / "Agent VMM Host"
                / "current"
                / "Agent VMM Host.app"
            )
            old_helper = old_app / "Contents" / "Helpers" / "agent-vmm-lifecycle"
            old_executable = old_app / "Contents" / "MacOS" / "agent-vmm-host"
            old_helper.parent.mkdir(parents=True, exist_ok=True)
            old_executable.parent.mkdir(parents=True, exist_ok=True)
            old_log = root / "old-host-lifecycle.log"
            write_executable(
                old_helper,
                "#!/bin/sh\n"
                "if [ \"${1:-}\" = version ]; then printf '%s\\n' '{\"component\":\"agent-vmm-host\",\"version\":\"release-old\",\"release_id\":\"release-old\"}'; exit 0; fi\n"
                f"printf '%s\\n' \"$*\" >> {shlex.quote(str(old_log))}\n"
                "if [ \"${1:-}\" = update ]; then printf 'pre-cutover update failed\\n' >&2; exit 1; fi\n",
            )
            write_executable(old_executable, "#!/bin/sh\nexit 0\n")

            proc = self.run_installer(
                {
                    "HOME": str(home),
                    "PATH": f"{command_dir}:{os.environ['PATH']}",
                    "BFT_INSTALL_PREFIX": str(root / "install"),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    "BFT_AGENT_VMM_HOST_URL": (artifacts / "agent-vmm-host.zip").as_uri(),
                    "BFT_AGENT_VMM_HOST_SHA256": host_sha,
                    "BFT_VMM_REQUEST_ID": "bft-host-install",
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                    "BFT_RUNNER_SHA256": worker_sha,
                }
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("install.agent_vmm_host_update_failed", proc.stderr)
            lines = old_log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 1, lines)
            self.assertTrue(lines[0].startswith("update --source-app "), lines)
            self.assertIn("--target-release-id release-test --request-id bft-host-install-update", lines[0])
            self.assertTrue(old_app.exists())

    def test_host_runtime_install_fails_when_local_readiness_is_not_observed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            command_dir = root / "commands"
            artifacts.mkdir()
            command_dir.mkdir()
            write_fake_host_tools(command_dir)
            connector_sha = write_executable(artifacts / "salix-connector", "#!/bin/sh\n")
            worker_sha = write_worker(artifacts / "mac-mini-provisioner")
            host_sha = write_host_runtime_archive(
                artifacts / "agent-vmm-host.zip", root / "host-lifecycle.log", ready=False
            )

            proc = self.run_installer(
                {
                    "HOME": str(root / "home"),
                    "PATH": f"{command_dir}:{os.environ['PATH']}",
                    "BFT_INSTALL_PREFIX": str(root / "install"),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    "BFT_AGENT_VMM_HOST_URL": (artifacts / "agent-vmm-host.zip").as_uri(),
                    "BFT_AGENT_VMM_HOST_SHA256": host_sha,
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                    "BFT_RUNNER_SHA256": worker_sha,
                }
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Agent VMM Host is not ready", proc.stderr)

    def test_host_runtime_installer_waits_for_and_only_prepares_the_shared_host(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            command_dir = root / "commands"
            artifacts.mkdir()
            command_dir.mkdir()
            prefix = root / "install"
            host_log = root / "host-lifecycle.log"
            write_fake_host_tools(command_dir)

            connector_sha = write_executable(
                artifacts / "salix-connector", "#!/bin/sh\nprintf 'fake salix connector\\n'\n"
            )
            worker_sha = write_worker(artifacts / "mac-mini-provisioner")
            host_sha = write_host_runtime_archive(
                artifacts / "agent-vmm-host.zip",
                host_log,
                ready_after_status_checks=2,
            )

            proc = self.run_installer(
                {
                    "HOME": str(root / "home"),
                    "PATH": f"{command_dir}:{os.environ['PATH']}",
                    "BFT_INSTALL_PREFIX": str(prefix),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    "BFT_AGENT_VMM_HOST_URL": (artifacts / "agent-vmm-host.zip").as_uri(),
                    "BFT_AGENT_VMM_HOST_SHA256": host_sha,
                    "BFT_VMM_REQUEST_ID": "bft-host-install",
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                    "BFT_RUNNER_SHA256": worker_sha,
                }
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(
                host_log.read_text(encoding="utf-8").splitlines(),
                [
                    f"install {SERVICE_ARGS} --request-id bft-host-install-install",
                    f"status {SERVICE_ARGS}",
                    f"status {SERVICE_ARGS}",
                    f"status {SERVICE_ARGS}",
                ],
            )

    def test_runner_installs_directly(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            prefix = root / "install"
            worker_args = root / "worker-args.log"

            connector_sha = write_executable(
                artifacts / "salix-connector",
                "#!/bin/sh\nprintf 'fake salix connector\\n'\n",
            )
            worker_sha = write_worker_recorder(artifacts / "mac-mini-provisioner", worker_args)

            proc = self.run_installer(
                {
                    "HOME": str(root / "home"),
                    "BFT_INSTALL_PREFIX": str(prefix),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    **agent_vmm_host_env(root, artifacts),
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                    "BFT_RUNNER_SHA256": worker_sha,
                }
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)

            runner = prefix / "bin" / "bft-runner"

            for args in (["doctor"], ["dry-run"], ["start"], ["status"]):
                result = subprocess.run(
                    [str(runner), *args],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

            self.assertEqual(
                worker_args.read_text(encoding="utf-8").splitlines(),
                [
                    "doctor",
                    "dry-run",
                    "start",
                    "status",
                ],
            )

    def test_opt_in_launchd_install_writes_plist_without_loading(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            prefix = root / "install"
            existing_bin = root / "existing-bin"
            existing_bin.mkdir()
            launch_agents = root / "LaunchAgents"

            connector_sha = write_executable(
                artifacts / "salix-connector",
                "#!/bin/sh\nprintf 'fake salix connector\\n'\n",
            )
            worker_sha = write_worker(artifacts / "mac-mini-provisioner")
            secret = "bft_launchd_secret_should_not_leak"

            proc = self.run_installer(
                {
                    "HOME": str(root / "home"),
                    "PATH": f"{existing_bin}:{os.environ['PATH']}",
                    "BFT_INSTALL_PREFIX": str(prefix),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    **agent_vmm_host_env(root, artifacts, existing_bin),
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                    "BFT_RUNNER_SHA256": worker_sha,
                    "BFT_RUNNER_TOKEN": secret,
                    "BFT_INSTALL_LAUNCHD": "1",
                    "BFT_LAUNCHD_INSTALL_PATH": str(
                        launch_agents / "com.bridgeforteams.runner.plist"
                    ),
                }
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("launchd not loaded", proc.stdout)
            self.assertNotIn(secret, proc.stdout)
            self.assertNotIn(secret, proc.stderr)

            status_payload = json.loads(
                (prefix / "runner-install-status.json").read_text(encoding="utf-8")
            )
            install_path = pathlib.Path(status_payload["launchd"]["install_path"])
            self.assertTrue(status_payload["launchd"]["installed"])
            self.assertFalse(status_payload["launchd"]["loaded"])
            self.assertTrue(install_path.exists())
            self.assertEqual(
                plistlib.loads(install_path.read_bytes()),
                plistlib.loads((prefix / "com.bridgeforteams.runner.plist").read_bytes()),
            )
            self.assertNotIn(secret, json.dumps(status_payload))

    def test_system_launchd_load_is_rejected_before_download(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            prefix = root / "install"
            existing_bin = root / "existing-bin"
            existing_bin.mkdir()
            launch_agents = root / "LaunchAgents"
            launchctl_log = root / "launchctl.log"

            connector_sha = write_executable(
                artifacts / "salix-connector",
                "#!/bin/sh\nprintf 'fake salix connector\\n'\n",
            )
            write_fake_launchctl(existing_bin / "launchctl", launchctl_log)
            worker_sha = write_worker(artifacts / "mac-mini-provisioner")

            install_path = launch_agents / "com.bridgeforteams.runner.plist"
            proc = self.run_installer(
                {
                    "HOME": str(root / "home"),
                    "PATH": f"{existing_bin}:{os.environ['PATH']}",
                    "BFT_INSTALL_PREFIX": str(prefix),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    **agent_vmm_host_env(root, artifacts, existing_bin),
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                    "BFT_RUNNER_SHA256": worker_sha,
                    "BFT_INSTALL_LAUNCHD": "1",
                    "BFT_LOAD_LAUNCHD": "1",
                    "BFT_LAUNCHD_DOMAIN": "system",
                    "BFT_LAUNCHD_INSTALL_PATH": str(install_path),
                }
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("preflight.system_launchd_executor_required", proc.stderr)
            self.assertIn("cannot manage a system job", proc.stderr)
            self.assertFalse(launchctl_log.exists())
            self.assertFalse(install_path.exists())
            self.assertFalse((prefix / "bin" / "bft-runner").exists())

    def test_invalid_launchd_load_requests_fail_before_launchctl(self) -> None:
        cases = [
            ("load without explicit plist install", {}, "preflight.launchd_install_missing"),
            (
                "load and remove conflict",
                {"BFT_REMOVE_LAUNCHD": "1"},
                "preflight.launchd_action_conflict",
            ),
        ]
        for name, extra_env, error_code in cases:
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                artifacts = root / "artifacts"
                artifacts.mkdir()
                prefix = root / "install"
                existing_bin = root / "existing-bin"
                existing_bin.mkdir()
                launchctl_log = root / "launchctl.log"

                connector_sha = write_executable(
                    artifacts / "salix-connector",
                    "#!/bin/sh\nprintf 'fake salix connector\\n'\n",
                )
                write_fake_launchctl(existing_bin / "launchctl", launchctl_log)
                worker_sha = write_worker(artifacts / "mac-mini-provisioner")

                proc = self.run_installer(
                    {
                        "HOME": str(root / "home"),
                        "PATH": f"{existing_bin}:{os.environ['PATH']}",
                        "BFT_INSTALL_PREFIX": str(prefix),
                        "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                        "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                        **agent_vmm_host_env(root, artifacts, existing_bin),
                        "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                        "BFT_RUNNER_SHA256": worker_sha,
                        "BFT_LOAD_LAUNCHD": "1",
                        **extra_env,
                    }
                )

                self.assertNotEqual(proc.returncode, 0)
                self.assertIn(error_code, proc.stderr)
                self.assertFalse(launchctl_log.exists())

    def test_explicit_launchd_remove_unloads_and_removes_installed_plist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            prefix = root / "install"
            existing_bin = root / "existing-bin"
            existing_bin.mkdir()
            launch_agents = root / "LaunchAgents"
            launch_agents.mkdir()
            launchctl_log = root / "launchctl.log"

            connector_sha = write_executable(
                artifacts / "salix-connector",
                "#!/bin/sh\nprintf 'fake salix connector\\n'\n",
            )
            write_fake_launchctl(existing_bin / "launchctl", launchctl_log)
            worker_sha = write_worker(artifacts / "mac-mini-provisioner")

            install_path = launch_agents / "com.bridgeforteams.runner.plist"
            install_path.write_text("old plist\n", encoding="utf-8")

            proc = self.run_installer(
                {
                    "HOME": str(root / "home"),
                    "PATH": f"{existing_bin}:{os.environ['PATH']}",
                    "BFT_INSTALL_PREFIX": str(prefix),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    **agent_vmm_host_env(root, artifacts, existing_bin),
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                    "BFT_RUNNER_SHA256": worker_sha,
                    "BFT_UNLOAD_LAUNCHD": "1",
                    "BFT_REMOVE_LAUNCHD": "1",
                    "BFT_LAUNCHD_INSTALL_PATH": str(install_path),
                }
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("launchd unloaded", proc.stdout)
            self.assertIn("launchd install removed", proc.stdout)
            self.assertFalse(install_path.exists())

            launchctl_calls = launchctl_log.read_text(encoding="utf-8")
            self.assertIn(
                f"bootout gui/{os.getuid()}/com.bridgeforteams.runner",
                launchctl_calls,
            )

            status_payload = json.loads(
                (prefix / "runner-install-status.json").read_text(encoding="utf-8")
            )
            self.assertFalse(status_payload["launchd"]["installed"])
            self.assertFalse(status_payload["launchd"]["loaded"])
            self.assertEqual(status_payload["launchd"]["last_action"], "remove")
            self.assertTrue(status_payload["launchd"]["last_remove_removed"])
            self.assertTrue((prefix / "com.bridgeforteams.runner.plist").exists())

    def test_missing_runner_sha_identifies_runner_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            prefix = root / "install"
            existing_bin = root / "existing-bin"
            existing_bin.mkdir()
            connector_sha = write_executable(
                artifacts / "salix-connector",
                "#!/bin/sh\nprintf 'fake salix connector\\n'\n",
            )
            write_worker(artifacts / "mac-mini-provisioner")

            proc = self.run_installer(
                {
                    "HOME": str(root / "home"),
                    "PATH": f"{existing_bin}:{os.environ['PATH']}",
                    "BFT_INSTALL_PREFIX": str(prefix),
                    "BFT_SALIX_CONNECTOR_URL": (artifacts / "salix-connector").as_uri(),
                    "BFT_SALIX_CONNECTOR_SHA256": connector_sha,
                    **agent_vmm_host_env(root, artifacts, existing_bin),
                    "BFT_RUNNER_URL": (artifacts / "mac-mini-provisioner").as_uri(),
                }
            )

            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("preflight.runner_sha_missing", proc.stderr)
            self.assertIn("runner sha256 is required", proc.stderr)

if __name__ == "__main__":
    unittest.main()
