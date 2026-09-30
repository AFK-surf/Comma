ARG EXTERNAL_IMAGE=node:24.19.0-bookworm-slim
FROM ${EXTERNAL_IMAGE}
ARG PI_TARBALL
ARG PI_INTEGRITY
RUN node -e 'const fs=require("fs"),crypto=require("crypto");(async()=>{const response=await fetch(process.env.PI_TARBALL);if(!response.ok)throw Error("Pi download failed");const data=Buffer.from(await response.arrayBuffer());if("sha512-"+crypto.createHash("sha512").update(data).digest("base64")!==process.env.PI_INTEGRITY)throw Error("Pi lock integrity mismatch");fs.writeFileSync("/tmp/pi.tgz",data)})().catch(e=>{console.error(e);process.exit(1)})' \
    && npm install --prefix /opt/pi --no-audit --no-fund /tmp/pi.tgz \
    && ln -s /opt/pi/node_modules/.bin/pi /usr/local/bin/pi \
    && rm /tmp/pi.tgz \
    && install -d -o node -g node -m 0700 /workspace
COPY salix-runtime-agent pressure-relay /usr/local/bin/
COPY start.sh /usr/local/bin/start-fixture
USER node
ENV HOME=/workspace
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/start-fixture"]
