#!/usr/bin/env python3
"""Exercise the signed helper without access to SwiftPM's build-time resources.

Run after packaging, on a macOS GUI runner. The sandbox prevents a surviving
.build directory from hiding a broken resource lookup. No TCC grants are needed
for session lifecycle, cursor-position, and permission-window resource loading.
Use --screenshots on an authorized desktop to cover the ScreenCaptureKit bridge.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import uuid


def request(path, token, **payload):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(20)
        connection.connect(str(path))
        connection.sendall(json.dumps(dict(payload, auth_token=token)).encode() + b"\n")
        with connection.makefile() as stream:
            for line in stream:
                message = json.loads(line)
                if message.get("kind") == "final":
                    response = message["response"]
                    assert response.get("ok"), response
                    return response
    raise AssertionError("helper exited without a final response")


def test_standalone_application(root, packaged_app):
    nested = root / "Comma.app/Contents/Resources/Comma Computer Use.app"
    shutil.copytree(packaged_app, nested, symlinks=True)
    # Isolate the installed app and TCC identity from developer and release apps.
    identifier = "surf.comma.test.isolation." + uuid.uuid4().hex
    info_path = nested / "Contents/Info.plist"
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    info["CFBundleIdentifier"] = identifier
    with info_path.open("wb") as output:
        plistlib.dump(info, output)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(nested)], check=True)
    executable = nested / "Contents/MacOS/CommaComputerUseDaemon"
    installed = Path(subprocess.check_output([str(executable), "--prepare-app"], text=True, timeout=20).strip())
    assert installed.name == nested.name and installed.parent.name == identifier, installed
    assert not any(parent.suffix == ".app" for parent in installed.parents), installed
    path = root / "standalone.sock"
    token = secrets.token_hex(24)
    try:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(installed)], check=True)
        assert subprocess.check_output([str(executable), "--prepare-app"], text=True, timeout=20).strip() == str(installed)
        for attempt in range(2):
            output_path = root / f"standalone-{attempt}.log"
            subprocess.run([
                "open", "-n", "-g", "--stdout", str(output_path), "--stderr", str(output_path),
                "--env", f"COMMA_COMPUTER_USE_AUTH_TOKEN={token}",
                "--env", f"COMMA_COMPUTER_USE_SOCKET_PATH={path}", str(installed),
            ], check=True, timeout=15)
            deadline = time.monotonic() + 15
            while not path.exists():
                assert time.monotonic() < deadline, output_path.read_text()
                time.sleep(0.1)
            assert request(path, token, control="hello")["message"] == "comma-computer-use-daemon"
            # LaunchServices must register the independent app, including after relaunch.
            asn = subprocess.check_output([
                "lsappinfo", "find", f"bundleid={identifier}",
            ], text=True, timeout=10).strip()
            assert asn, "helper did not register with LaunchServices"
            identity = subprocess.check_output([
                "lsappinfo", "info", "-only", "bundlepath", "-only", "CFBundleIdentifier", asn,
            ], text=True, timeout=10)
            assert str(installed) in identity and identifier in identity, identity
            request(path, token, control="permissions-status")
            request(path, token, control="shutdown")
            while path.exists():
                assert time.monotonic() < deadline, "helper did not release its socket"
                time.sleep(0.1)
        print("PASS: nested distribution installs and relaunches with an independent LaunchServices identity", flush=True)
    finally:
        if path.exists():
            request(path, token, control="shutdown")
        shutil.rmtree(installed.parent)


def test_restart_during_shutdown(root, app):
    path = root / "restart.sock"
    token = secrets.token_hex(24)
    environment = dict(os.environ, COMMA_COMPUTER_USE_AUTH_TOKEN=token,
                       COMMA_COMPUTER_USE_SOCKET_PATH=str(path))
    processes = []

    def wait_for(predicate, message):
        deadline = time.monotonic() + 10
        while not predicate():
            assert time.monotonic() < deadline, message
            time.sleep(0.001)

    with (root / "restart.log").open("w+") as log:
        def launch():
            process = subprocess.Popen(
                [str(app / "Contents/MacOS/CommaComputerUseDaemon")],
                env=environment, stdout=log, stderr=log)
            processes.append(process)
            wait_for(lambda: path.exists() or process.poll() is not None,
                     "helper did not open its socket")
            assert process.poll() is None, f"helper exited: {process.returncode}"
            assert request(path, token, control="hello")["message"] == "comma-computer-use-daemon"
            return process

        try:
            old = launch()
            request(path, token, control="shutdown")
            wait_for(lambda: not path.exists(), "old helper did not release its socket")
            # Hold the old process before its final cleanup. The replacement must
            # remain reachable when that cleanup runs, regardless of launch speed.
            old.send_signal(signal.SIGSTOP)
            assert old.poll() is None, "old helper exited before the restart overlap"
            replacement = launch()
            old.send_signal(signal.SIGCONT)
            assert old.wait(timeout=10) == 0
            assert replacement.poll() is None, "replacement helper exited"
            assert path.exists(), "old helper removed the replacement socket"
            assert request(path, token, control="hello")["message"] == "comma-computer-use-daemon"
            request(path, token, control="shutdown")
            assert replacement.wait(timeout=10) == 0
            assert not path.exists(), "replacement helper left its socket after shutdown"
            print("PASS: replacement helper remains reachable after old helper exits", flush=True)
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read()[-12000:], flush=True)
            raise
        finally:
            for process in processes:
                if process.poll() is None:
                    process.send_signal(signal.SIGCONT)
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


def test_drag_panel(root, app, build, profile):
    # Use the helper's patched dependency. The native SwiftPM accessor used by
    # release builds must work without its build directory, even on newer Xcode.
    package = root / "panel-fixture"
    package.mkdir()
    dependency = build / "checkouts/PermissionFlow"
    (package / "Package.swift").write_text(f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "PermissionPanel",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: {json.dumps(str(dependency))})],
    targets: [.executableTarget(
        name: "PermissionPanel",
        dependencies: [.product(name: "PermissionFlow", package: "PermissionFlow")],
        path: ".", sources: ["main.swift"]
    )]
)
''')
    shutil.copyfile(Path(__file__).parent / "fixtures/permission_flow_panel.swift",
                    package / "main.swift")
    command = ["swift", "build", "--package-path", str(package), "--build-system", "native"]
    subprocess.run(command, check=True, timeout=120)
    products = Path(subprocess.check_output([*command, "--show-bin-path"], text=True).strip())
    fixture = root / "Permission Panel.app"
    executable = fixture / "Contents/MacOS/PermissionPanel"
    resources = fixture / "Contents/Resources"
    executable.parent.mkdir(parents=True)
    resources.mkdir()
    with (fixture / "Contents/Info.plist").open("wb") as info:
        plistlib.dump({
            "CFBundleExecutable": executable.name,
            "CFBundleIdentifier": "surf.comma.test.permission-panel",
            "CFBundlePackageType": "APPL",
        }, info)
    shutil.copytree(app / "Contents/Resources/PermissionFlow_PermissionFlow.bundle",
                    resources / "PermissionFlow_PermissionFlow.bundle")
    shutil.copyfile(products / "PermissionPanel", executable)
    executable.chmod(0o755)
    subprocess.run(["codesign", "--force", "--sign", "-", str(fixture)], check=True)
    profile += f"(deny file-read* (subpath {json.dumps(str(package.resolve()))}))"
    subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, str(executable)],
                   check=True, timeout=20)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--build-directory", required=True, type=Path)
    parser.add_argument("--screenshots", action="store_true",
                        help="Also capture a real screenshot; requires Screen Recording permission")
    args = parser.parse_args()
    build = args.build_directory.resolve()
    assert build.is_dir(), f"Expected build directory: {build}"
    # /tmp keeps the Unix socket below sockaddr_un's 104-byte path limit.
    with tempfile.TemporaryDirectory(prefix="comma-packaged-", dir="/tmp") as directory:
        root = Path(directory)
        app = root / "Comma Computer Use.app"
        shutil.copytree(args.app, app, symlinks=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        test_restart_during_shutdown(root, app)
        test_standalone_application(root, app)
        token = secrets.token_hex(24)
        path = root / "daemon.sock"
        environment = dict(os.environ, COMMA_COMPUTER_USE_AUTH_TOKEN=token,
                           COMMA_COMPUTER_USE_SOCKET_PATH=str(path))
        profile = f"(version 1)(allow default)(deny file-read* (subpath {json.dumps(str(build))}))"
        test_drag_panel(root, app, build, profile)
        with (root / "daemon.log").open("w+") as log:
            process = subprocess.Popen([
                "/usr/bin/sandbox-exec", "-p", profile,
                str(app / "Contents/MacOS/CommaComputerUseDaemon"),
            ], env=environment, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 20
                while not path.exists():
                    assert process.poll() is None, f"helper exited: {process.returncode}"
                    assert time.monotonic() < deadline, "helper did not open socket"
                    time.sleep(0.1)
                assert request(path, token, control="hello")["message"] == "comma-computer-use-daemon"
                request(path, token, control="open-permission-flow")
                for mode in ("foreground", "background"):
                    response = request(path, token, action={"start": {"mode": mode}})
                    print(f"{mode} start: {response}", flush=True)
                    if mode == "foreground":
                        position = request(path, token, action={"get_cursor_position": {}})
                        print(f"foreground cursor: {position}", flush=True)
                        if args.screenshots:
                            screenshot = request(path, token, action={"get_screenshot": {}})
                            image = base64.b64decode(screenshot.get("imageData", ""), validate=True)
                            assert image.startswith(b"\x89PNG\r\n\x1a\n"), "missing PNG screenshot"
                            assert screenshot["imageWidth"] > 0 and screenshot["imageHeight"] > 0
                            print("foreground screenshot: received image bytes", flush=True)
                    request(path, token, action={"status": {}})
                    request(path, token, action={"stop": {}})
                request(path, token, control="shutdown")
                assert process.wait(timeout=10) == 0
                print("PASS: relocated signed helper, build resources denied, permission UI and both sessions")
            except BaseException:
                log.flush()
                log.seek(0)
                print(log.read()[-12000:], flush=True)
                raise
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    main()
