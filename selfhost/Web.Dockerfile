FROM docker.io/library/node:24-bookworm-slim AS build
WORKDIR /src
RUN corepack enable
COPY . .
ENV HUSKY=0 ELECTRON_SKIP_BINARY_DOWNLOAD=1
RUN pnpm install --frozen-lockfile --ignore-scripts
ARG COMMA_API_BASE_URL=http://localhost:8081
RUN COMMA_SELFHOST_BUILD=true COMMA_BUILD_FLAVOR=prod COMMA_API_BASE_URL=${COMMA_API_BASE_URL} pnpm --dir clients/apps/web build
RUN COMMA_SELFHOST_BUILD=true COMMA_BUILD_FLAVOR=prod COMMA_API_BASE_URL=${COMMA_API_BASE_URL} pnpm --dir clients/apps/admin build:prod
RUN node -e 'const fs=require("fs");for(const app of ["web","admin"]){const p=`clients/apps/${app}/dist/index.html`;fs.writeFileSync(p,fs.readFileSync(p,"utf8").replace("</body>","<a href=\"/source.tar.gz\" style=\"position:fixed;bottom:4px;right:8px;font-size:11px;z-index:9999\">Source · AGPL-3.0</a></body>"))}'
# Ship the corresponding source for this exact build, including local changes.
RUN tar --exclude=node_modules --exclude=dist --exclude=.git -czf /source.tar.gz .

FROM docker.io/library/caddy:2.10-alpine
COPY selfhost/Caddyfile /etc/caddy/Caddyfile
COPY --from=build /src/clients/apps/web/dist /srv/web
COPY --from=build /src/clients/apps/admin/dist /srv/admin
COPY --from=build /source.tar.gz /srv/source.tar.gz
COPY LICENSE /srv/LICENSE
EXPOSE 8080 8081 8082
