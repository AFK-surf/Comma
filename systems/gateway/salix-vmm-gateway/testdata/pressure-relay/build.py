#!/usr/bin/env python3
"""Build isolated Comma/VMM pressure-test artifacts; never deploy or enroll a saved Host."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import uuid


def run(*args, cwd=None, env=None):
    subprocess.run(args, cwd=cwd, env=env, check=True)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--vmm", required=True, type=Path)
parser.add_argument("--guest-bundle", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
fixture = Path(__file__).resolve().parent
comma = fixture.parents[4]
vmm, bundle, output = args.vmm.resolve(), args.guest_bundle.resolve(), args.output.resolve()
output.mkdir(mode=0o700, parents=True, exist_ok=False)
image = output / "image"
image.mkdir()
lock = json.loads((comma / "systems/runtime-images/runtime-dependencies.lock.json").read_text())
for name in ("Dockerfile", "start.sh"):
    shutil.copy2(fixture / name, image / name)
linux_env = {**os.environ, "CGO_ENABLED": "0", "GOOS": "linux", "GOARCH": "arm64"}
run("go", "build", "-o", str(image / "salix-runtime-agent"), ".",
    cwd=comma / "systems/connector/salix-connect", env=linux_env)
run("go", "build", "-o", str(image / "pressure-relay"), str(fixture / "main.go"), env=linux_env)
archive = output / "image.oci.tar"
run("docker", "buildx", "build", "--platform=linux/arm64", "--provenance=false",
    "--build-arg", "EXTERNAL_IMAGE=" + lock["baseImages"]["external"],
    "--build-arg", "PI_TARBALL=" + lock["pi"]["tarball"],
    "--build-arg", "PI_INTEGRITY=" + lock["pi"]["integrity"],
    "--output", "type=oci,dest=" + str(archive), str(image))
with tarfile.open(archive) as content:
    index = json.load(content.extractfile("index.json"))
    digest = index["manifests"][0]["digest"]
image_metadata = output / "image.json"
with archive.open("rb") as stream:
    archive_sha = hashlib.file_digest(stream, "sha256").hexdigest()
image_metadata.write_text(json.dumps({
    "reference": "comma.local/runtime/external@" + digest,
    "manifestDigest": digest, "platform": "linux/arm64", "class": "external",
    "archiveSha256": archive_sha,
    "archiveSize": archive.stat().st_size,
}))

# The scratch Guest observes real cgroups and runs bounded child/parent OOM
# probes. Its source bundle stays read-only; no installed Host state is used.
name = "comma-pressure-build-" + uuid.uuid4().hex[:12]
run("docker", "volume", "create", name)
try:
    run("docker", "create", "--name", name,
        "-v", str(bundle) + ":/input:ro",
        "-v", str(vmm / "test/e2e/testdata/pressure") + ":/fixture:ro",
        "-v", name + ":/output", "alpine:3.23.5", "sh", "/fixture/repack.sh")
    run("docker", "start", "--attach", name)
    status = subprocess.check_output(["docker", "inspect", "--format", "{{.State.ExitCode}}", name], text=True)
    if status.strip() != "0":
        raise RuntimeError("Guest diagnostic bundle build failed")
    run("docker", "cp", name + ":/output/bundle", str(output / "bundle"))
finally:
    run("docker", "rm", "--force", name)
    run("docker", "volume", "rm", name)

guest_digest = hashlib.sha256((output / "bundle/manifest.json").read_bytes()).hexdigest()
host = output / "agent-vmm-host"
run("go", "build", "-tags=e2e", "-ldflags", "-X main.guestManifestDigest=" + guest_digest,
    "-o", str(host), "./cmd/agent-vmm-host", cwd=vmm)
run("codesign", "--force", "--sign", "-", "--entitlements", str(vmm / "build/host/vz.entitlements.plist"), str(host))
run("cargo", "build", "--locked", "--release", "--manifest-path", str(vmm / "data/agent-vmm-data/Cargo.toml"))
run("go", "test", "-tags=e2e", "-c", "-o", str(output / "host.test"), "./test/e2e", cwd=vmm)
run("go", "test", "-c", "-o", str(output / "gateway.test"), ".", cwd=fixture.parents[1])
environment = {
    "COMMA_VMM_PRESSURE_E2E": "1", "COMMA_VMM_SOURCE": vmm,
    "COMMA_VMM_PRESSURE_IMAGE": image_metadata, "COMMA_VMM_PRESSURE_ARCHIVE": archive,
    "COMMA_VMM_PRESSURE_GATEWAY": output / "gateway.test", "COMMA_VMM_PRESSURE_HOST": output / "host.test",
    "AGENT_VMM_E2E_HOST_BINARY": host, "AGENT_VMM_E2E_BUNDLE": output / "bundle",
    "AGENT_VMM_E2E_DATA_BINARY": vmm / "data/agent-vmm-data/target/release/agent-vmm-data",
}
(output / "env.sh").write_text("\n".join("export " + key + "=" + shlex.quote(str(value)) for key, value in environment.items()) + "\n")
print("Fixture built. Source " + str(output / "env.sh") + " and run the opt-in ExUnit test with Docker test database settings.")
