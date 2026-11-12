#!/usr/bin/env sh
set -eu
image="${1:?usage: station-tools.sh IMAGE}"
here="$(cd "$(dirname "$0")" && pwd)"
node_version="$(cat "$here/../../station/.node-version")"
lock="$here/../runtime-dependencies.lock.json"
codex_version="$(jq -er .codex.version "$lock")"
claude_version="$(jq -er .claude.version "$lock")"
docker run --rm -i --network none --read-only \
  --tmpfs /workspace:exec,uid=1000,gid=1000,mode=0700 \
  --tmpfs /tmp:exec,mode=1777 --entrypoint sh \
  -e "EXPECTED_NODE=$node_version" -e "EXPECTED_CODEX=$codex_version" -e "EXPECTED_CLAUDE=$claude_version" \
  "$image" -eu <<'TOOLS'
test "$(id -u):$(id -g)" = 1000:1000
test "$(node --version)" = "v$EXPECTED_NODE"
test "$(/opt/comma-station/node/bin/node --version)" = "v$EXPECTED_NODE"
test "$(codex --version)" = "codex-cli $EXPECTED_CODEX"
test "$(claude --version | awk '{print $1}')" = "$EXPECTED_CLAUDE"
cd /workspace
python3 -c 'from PIL import Image; Image.new("RGB", (32, 24), "red").save("native.png")'
/opt/comma-station/node/bin/node --input-type=module <<'JS'
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
const native = createRequire(import.meta.url)('/opt/comma-station/station/mesh.node');
const image = await native.thumbhash('/workspace/native.png');
assert.equal(image.width, 32);
assert.equal(image.height, 24);
assert.ok(image.hash.length > 0);
JS
test "$(/opt/comma-station/mesh/target/release/comma-station handoff-version)" = 2
Xvfb :99 -screen 0 1280x720x24 -nolisten tcp > /tmp/xvfb.log 2>&1 &
xvfb=$!
DISPLAY=:99 meet-native serve > /tmp/meeting.log 2>&1 &
meeting=$!
browser=
trap 'kill $browser "$meeting" "$xvfb" 2>/dev/null || true' EXIT
for attempt in $(seq 1 100); do
  if curl --fail --silent http://127.0.0.1:8081/v1/meetings > /tmp/meetings.json; then break; fi
  sleep 0.1
done
node -e 'const assert = require("node:assert/strict"); assert.deepEqual(JSON.parse(require("node:fs").readFileSync("/tmp/meetings.json")), {sessions: []})'
printf '<meta charset="utf-8"><title>Meeting browser</title><body>中文会议</body>' > /workspace/meeting.html
DISPLAY=:99 chromium --no-sandbox --disable-dev-shm-usage --disable-background-networking \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 \
  --user-data-dir=/workspace/chromium file:///workspace/meeting.html > /tmp/chromium.log 2>&1 &
browser=$!
for attempt in $(seq 1 100); do
  if curl --fail --silent http://127.0.0.1:9222/json/list > /tmp/pages.json \
    && grep -q file:///workspace/meeting.html /tmp/pages.json; then break; fi
  sleep 0.1
done
node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const page = JSON.parse(readFileSync('/tmp/pages.json')).find(page => page.url === 'file:///workspace/meeting.html');
assert.ok(page, 'Chromium opened the meeting page on the virtual display');
const socket = new WebSocket(page.webSocketDebuggerUrl);
const result = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('Chromium did not answer')), 5000);
  socket.addEventListener('open', () => socket.send(JSON.stringify({
    id: 1, method: 'Runtime.evaluate', params: { expression: 'document.title + ":" + document.body.textContent' },
  })));
  socket.addEventListener('message', ({data}) => {
    const reply = JSON.parse(data);
    if (reply.id === 1) { clearTimeout(timer); resolve(reply.result.result.value); }
  });
  socket.addEventListener('error', reject);
}).finally(() => socket.close());
assert.equal(result, 'Meeting browser:中文会议');
JS
echo 'station: locked CLIs and shared Node, native image codec, meeting server and Chromium on Xvfb'
TOOLS
