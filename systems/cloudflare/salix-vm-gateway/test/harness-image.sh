#!/usr/bin/env sh
set -eu

# Run against a locally built amd64 image. This check never starts a cloud VM.
image="${1:?usage: harness-image.sh IMAGE}"
root="$(cd "$(dirname "$0")/../../.." && pwd)"
expected=$(node -e 'const lock=require(process.argv[1]); process.stdout.write(JSON.stringify(Object.fromEntries(["codex","claude","pi","uv"].map(name=>[name,lock[name].version]))))' "$root/runtime-images/runtime-dependencies.lock.json")
docker run --rm --platform linux/amd64 --entrypoint node "$image" -e '
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {execFileSync} = require("node:child_process");
const expected = JSON.parse(process.argv[1]);
assert.equal(process.arch, "x64");
const home = fs.mkdtempSync(path.join(os.tmpdir(), "harness-image-check-"));
try {
  for (const provider of ["codex", "claude", "pi"]) {
    const version = expected[provider];
    const command = `/opt/salix/default-harness/bin/${provider}`;
    const actual = execFileSync(command, ["--version"], {encoding:"utf8", env:{...process.env, HOME:home}}).trim();
    assert.equal(actual.split(/\s+/).at(provider === "codex" ? 1 : 0), version);
    assert.equal(execFileSync("sh", ["-c", `command -v ${provider}`], {encoding:"utf8"}).trim(), command);
    console.log(`${provider}: ${actual}`);
  }
  for (const command of ["uv", "uvx"]) {
    const actual = execFileSync(command, ["--version"], {encoding:"utf8"}).trim();
    assert.equal(actual.split(/\s+/)[1], expected.uv);
    console.log(`${command}: ${actual}`);
  }
  const venv = path.join(home, ".venv");
  execFileSync("uv", ["venv", "--offline", "--no-python-downloads", "--python", "/opt/python3.13/bin/python3.13", venv], {env:{...process.env, HOME:home, UV_CACHE_DIR:path.join(home,"uv-cache")}});
  const python = path.join(venv, "bin", "python");
  execFileSync(python, ["-c", "import sys; assert sys.prefix != sys.base_prefix; assert sys.version_info[:2] == (3, 13)"], {stdio:"inherit"});
  console.log("uv: created a working Python 3.13 virtual environment without downloads");
  assert.equal(fs.existsSync("/root/.claude.json"), false);
  assert.equal(fs.existsSync("/root/.codex/auth.json"), false);
  assert.equal(fs.existsSync("/root/.pi/agent/auth.json"), false);
} finally {
  fs.rmSync(home, {recursive:true, force:true});
}
' "$expected"
