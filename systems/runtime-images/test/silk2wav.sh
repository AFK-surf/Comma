#!/usr/bin/env sh
set -eu

# Run against a locally built Cloud VM image (the Cloudflare Sandbox or the
# station image), without network. A Task gets a WeChat voice message as
# voice.silk (0x02 "#!SILK_V3"); silk2wav must turn it into a 24 kHz mono
# 16-bit WAV with the locked decoder's samples. voice.silk is 1 s of a
# voice-like test signal, encoded with the same SDK's encoder (-tencent).
image="${1:?usage: silk2wav.sh IMAGE}"
here="$(cd "$(dirname "$0")" && pwd)"
docker run --rm --network none --entrypoint sh \
  --mount "type=bind,src=${here}/voice.silk,dst=/fixture/voice.silk,readonly" \
  "$image" -eu -c '
cd "$(mktemp -d)"
cp /fixture/voice.silk voice.silk
silk2wav voice.silk voice.wav
# QQ and other sources send the same stream without the leading 0x02. A long
# TMPDIR must not reach the decoder (it keeps paths in 150-byte buffers).
tail -c +2 voice.silk >plain.silk
long="$PWD/$(printf "%0200d" 0)"
mkdir "$long"
TMPDIR="$long" silk2wav plain.silk plain.wav
cmp voice.wav plain.wav
printf "RIFF not silk" >other.silk
if silk2wav other.silk other.wav 2>/dev/null; then
  echo "silk2wav accepted a file that is not SILK" >&2
  exit 1
fi
test ! -e other.wav
node -e "
const assert = require(\"node:assert/strict\");
const wav = require(\"node:fs\").readFileSync(\"voice.wav\");
const pcm = wav.subarray(44);
assert.equal(wav.toString(\"latin1\", 0, 4), \"RIFF\");
assert.equal(wav.readUInt32LE(4), wav.length - 8);
assert.equal(wav.toString(\"latin1\", 8, 16), \"WAVEfmt \");
assert.deepEqual([wav.readUInt16LE(20), wav.readUInt16LE(22), wav.readUInt32LE(24), wav.readUInt16LE(34)], [1, 1, 24000, 16]);
assert.equal(wav.toString(\"latin1\", 36, 40), \"data\");
assert.equal(wav.readUInt32LE(40), pcm.length);
assert.equal(pcm.length, 48000);
const sha = require(\"node:crypto\").createHash(\"sha256\").update(pcm).digest(\"hex\");
assert.equal(sha, \"74ea9e7b2e33071bc95f2c6e2623f48ea9ff93a7a8cc91c2428de78aa8d30b4e\");
console.log(\"silk2wav: decoded a WeChat voice message to 1 s of 24 kHz mono WAV, \" + sha);
"
'
