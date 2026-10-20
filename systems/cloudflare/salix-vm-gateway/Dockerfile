ARG NODE_IMAGE
ARG UV_IMAGE
FROM ${NODE_IMAGE} AS node-runtime

FROM ${UV_IMAGE} AS uv-runtime

FROM docker.io/cloudflare/sandbox:0.7.0 AS python-build

USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl libbz2-dev libffi-dev libgdbm-dev \
    liblzma-dev libncursesw5-dev libreadline-dev libsqlite3-dev libssl-dev \
    uuid-dev zlib1g-dev \
  && curl -fsSLo /tmp/Python-3.13.7.tgz https://www.python.org/ftp/python/3.13.7/Python-3.13.7.tgz \
  && tar -xzf /tmp/Python-3.13.7.tgz -C /tmp \
  && cd /tmp/Python-3.13.7 \
  && ./configure --prefix=/opt/python3.13 --with-ensurepip=install \
  && make -j2 \
  && make install

# The locked SILK v3 decoder, for the WeChat and QQ voice messages Tasks receive
# (ffmpeg has no SILK decoder); silk2wav wraps it.
FROM docker.io/cloudflare/sandbox:0.7.0 AS silk-build
ARG SILK_V3_DECODER_TARBALL
ARG SILK_V3_DECODER_INTEGRITY

USER root
RUN set -eu; \
  apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl g++ gcc make openssl \
  && curl --fail --location --silent --show-error "${SILK_V3_DECODER_TARBALL}" --output /tmp/silk.tgz \
  && printf '%s' "${SILK_V3_DECODER_INTEGRITY#sha512-}" | base64 --decode >/tmp/silk.expected \
  && openssl dgst -sha512 -binary /tmp/silk.tgz >/tmp/silk.actual && cmp /tmp/silk.expected /tmp/silk.actual \
  && mkdir /tmp/silk && tar -xzf /tmp/silk.tgz -C /tmp/silk --strip-components=1 \
  && make -C /tmp/silk/silk lib decoder \
  && install -D -m 0755 /tmp/silk/silk/decoder /out/silk-v3-decoder

FROM docker.io/cloudflare/sandbox:0.7.0

USER root

# The tools Tasks use to read what people send them (video, audio, PDF, archives,
# Office files, CJK text), shared with the Agent VMM station image.
COPY .build/file-tools-packages .build/file-tools-requirements.txt /tmp/
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libbz2-1.0 \
    libffi8 \
    libgdbm6 \
    liblzma5 \
    libncursesw6 \
    libreadline8 \
    libsqlite3-0 \
    libpcre2-8-0 \
    procps \
    zlib1g \
  && apt-get install -y --no-install-recommends $(cat /tmp/file-tools-packages) \
  && rm -rf /var/lib/apt/lists/*

COPY --from=python-build /opt/python3.13 /opt/python3.13
COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=uv-runtime /uv /uvx /usr/local/bin/
RUN ln -s /opt/python3.13/bin/python3.13 /usr/local/bin/python3 \
  && python3 -V \
  && python3 -m pip --version \
  && python3 -m pip install --no-cache-dir --only-binary :all: --require-hashes \
    -r /tmp/file-tools-requirements.txt \
  && rm /tmp/file-tools-packages /tmp/file-tools-requirements.txt

COPY .build/runtime-dependencies.lock.json .build/install-harnesses.mjs /tmp/salix-harness-build/
RUN node /tmp/salix-harness-build/install-harnesses.mjs /tmp/salix-harness-build/runtime-dependencies.lock.json \
  && rm -rf /tmp/salix-harness-build
ENV DISABLE_AUTOUPDATER=1
ENV PATH="${PATH}:/opt/salix/default-harness/bin"

COPY --from=silk-build /out/silk-v3-decoder /usr/local/bin/silk-v3-decoder
COPY .build/silk2wav /usr/local/bin/silk2wav
RUN chmod 0755 /usr/local/bin/silk2wav && test -x /usr/local/bin/silk-v3-decoder

COPY entrypoint.sh /usr/local/bin/salix-vm-entrypoint
COPY .build/station /opt/comma-station
RUN chmod +x /usr/local/bin/salix-vm-entrypoint

WORKDIR /workspace
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/salix-vm-entrypoint"]
