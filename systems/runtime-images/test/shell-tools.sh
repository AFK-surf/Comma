#!/usr/bin/env sh
set -eu
image="${1:?usage: shell-tools.sh IMAGE}"
docker run --rm -i --network none --read-only \
  --tmpfs /workspace:exec,uid=10001,gid=10001,mode=0700 \
  --tmpfs /tmp:mode=1777 --entrypoint sh "$image" -eu <<'TOOLS'
test "$(id -u):$(id -g)" = 10001:10001
cd /workspace
virtualenv --no-download /workspace/virtualenv
/workspace/virtualenv/bin/python -m pip --version
python3 -m venv venv
venv/bin/python -m pip --version
python -c 'import json; open("data.json", "w").write(json.dumps({"value": 42}))'
test "$(jq .value data.json)" = 42
mkdir pkg
printf '%s\n' '{"name":"local-tools-check","version":"1.0.0","main":"index.js"}' > pkg/package.json
printf '%s\n' 'module.exports = 42' > pkg/index.js
npm install --prefix /workspace/node --offline --ignore-scripts --no-audit --no-fund ./pkg
node -e 'if (require("/workspace/node/node_modules/local-tools-check") !== 42) process.exit(1)'
cat > hello.cpp <<'CPP'
#include <iostream>
int main() { std::cout << "compiled"; }
CPP
printf 'hello: hello.cpp\n\tg++ hello.cpp -o hello\n' > Makefile
make
test "$(./hello)" = compiled
git init -q repo
git -C repo -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initialized
test "$(git -C repo log -1 --format=%s)" = initialized
printf '# Heading\n' | pandoc -f markdown -t html | rg '<h1.*Heading'
ffmpeg -hide_banner -loglevel error -f lavfi -i sine=frequency=440:duration=0.1 audio.wav
ffprobe -v error -show_entries stream=codec_type -of csv=p=0 audio.wav | rg '^audio$'
printf 'archive\n' > a.txt
zip -q archive.zip a.txt
unzip -p archive.zip a.txt | rg '^archive$'
for tool in bash curl wget ssh file find tar gzip; do command -v "$tool"; done
TOOLS
