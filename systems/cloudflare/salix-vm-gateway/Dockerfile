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

FROM docker.io/cloudflare/sandbox:0.7.0

USER root

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
  && rm -rf /var/lib/apt/lists/*

COPY --from=python-build /opt/python3.13 /opt/python3.13
COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=uv-runtime /uv /uvx /usr/local/bin/
RUN ln -s /opt/python3.13/bin/python3.13 /usr/local/bin/python3 \
  && python3 -V \
  && python3 -m pip --version

COPY .build/runtime-dependencies.lock.json .build/install-harnesses.mjs /tmp/salix-harness-build/
RUN node /tmp/salix-harness-build/install-harnesses.mjs /tmp/salix-harness-build/runtime-dependencies.lock.json \
  && rm -rf /tmp/salix-harness-build
ENV DISABLE_AUTOUPDATER=1
ENV PATH="${PATH}:/opt/salix/default-harness/bin"

COPY entrypoint.sh /usr/local/bin/salix-vm-entrypoint
COPY .build/salix-runtime-agent /usr/local/bin/salix-runtime-agent
RUN chmod +x /usr/local/bin/salix-vm-entrypoint
RUN chmod +x /usr/local/bin/salix-runtime-agent

# Consumed once by Connector; archives never copy this local admission fact.
RUN mkdir -p /workspace/.salix && touch /workspace/.salix/cloud-runtime-fresh

WORKDIR /workspace
EXPOSE 3000
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/salix-vm-entrypoint"]
