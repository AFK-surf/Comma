FROM golang:1.25-bookworm AS connector-builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN CGO_ENABLED=0 go build -trimpath -o /out/salix-connect .

FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash build-essential ca-certificates coreutils curl findutils git jq \
    nodejs npm protobuf-compiler sqlite3 \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    aiofiles aiohttp argon2-cffi boto3 brotli click cryptography flask \
    hiredis httpx hypothesis imbalanced-learn numpy packaging pandas paramiko \
    pyjwt pyopenssl pyyaml pytest pytest-asyncio pytest-cov pytest-flask redis \
    requests requests-mock scikit-learn scipy starlette statsmodels werkzeug

RUN npm install --global \
    dompurify@3.0 ejs@3.1 express@4.18 jsdom@24 ts-node@10.9 typescript@5

RUN useradd -m -u 10001 agent
COPY --from=connector-builder /out/salix-connect /usr/local/bin/salix-connect
COPY --from=connector-builder /usr/local/go /usr/local/go

ENV NODE_PATH="/usr/local/lib/node_modules"
ENV NPM_CONFIG_OFFLINE="true"
ENV NPM_CONFIG_FETCH_RETRIES="0"
ENV PATH="/usr/local/go/bin:${PATH}"

USER agent
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/salix-connect"]
CMD ["--config", "/run/secrets/salix-connector.json"]
