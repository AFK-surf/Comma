import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import type { AddressInfo } from "node:net";

export const e2eSessionExpiresAtEpochSeconds = 4_102_444_800;

export interface E2eSessionIdentity {
  email: string;
  handleRequest?: (
    request: IncomingMessage,
    response: ServerResponse,
    path: string
  ) => boolean;
  profile?: {
    avatarId?: string;
    avatarPngBase64?: string;
    /** The account's app language; absent until the first device reports one. */
    locale?: "en" | "zh-CN";
    name?: string;
  };
  sessionId?: string;
  userId?: string;
}

export function createE2eSessionProjection(identity: E2eSessionIdentity) {
  const normalizedEmail = identity.email.toLowerCase();
  return {
    expires_at: e2eSessionExpiresAtEpochSeconds,
    session_id: identity.sessionId ?? `e2e-session:${normalizedEmail}`,
    user: {
      email: identity.email,
      id: identity.userId ?? `e2e-user:${normalizedEmail}`,
      status: "active",
    },
  };
}

type SessionProjection = ReturnType<typeof createE2eSessionProjection>;
const browserSessions = new Map<string, Map<string, SessionProjection>>();

// Node-side fixture authority shared by page and SharedWorker HTTP requests.
// Keep identities keyed by the real cookie, including when two accounts use
// the same stub. Expected-session headers are never an authentication source.
export function registerBrowserSessionFixture(
  apiBaseUrl: string,
  token: string,
  projection: SessionProjection
) {
  const origin = new URL(apiBaseUrl).origin;
  const sessions = browserSessions.get(origin) ?? new Map();
  sessions.set(token, projection);
  browserSessions.set(origin, sessions);
}

export function readBrowserSessionFixture(origin: string, cookie: string | undefined) {
  const sessions = browserSessions.get(origin);
  if (!sessions) return undefined;
  const token = cookie
    ?.split(";")
    .map((part) => part.trim())
    .find((part) => part.startsWith("comma_session="))
    ?.slice("comma_session=".length);
  return (token && sessions.get(token)) || null;
}

export function clearBrowserSessionFixtures(origin: string) {
  browserSessions.delete(origin);
}

export function reflectedCorsRequestHeaders(
  requested: string | string[] | undefined,
  fallback: string
) {
  const value = Array.isArray(requested) ? requested.join(",") : requested;
  return value?.trim() || fallback;
}

export function startSessionProjectionStub(identity: E2eSessionIdentity) {
  // The account profile is server state: a language one page saves is what
  // the next page load reads.
  let accountLocale = identity.profile?.locale ?? null;
  let accountName = identity.profile?.name ?? null;
  const accountProfile = () => ({
    avatar_id: identity.profile?.avatarId ?? null,
    email: identity.email,
    id: identity.userId ?? `e2e-user:${identity.email.toLowerCase()}`,
    locale: accountLocale,
    name: accountName,
  });
  const server = createServer((request, response) => {
    setCorsHeaders(request, response);
    if (request.method === "OPTIONS") {
      response.writeHead(204).end();
      return;
    }

    const path = new URL(request.url ?? "/", "http://127.0.0.1").pathname;
    if (request.method === "GET" && path === "/v1/comma/auth/session") {
      writeJson(response, createE2eSessionProjection(identity));
      return;
    }
    if (
      request.method === "GET" &&
      path === "/v1/comma/me/profile" &&
      identity.profile
    ) {
      writeJson(response, accountProfile());
      return;
    }
    if (
      request.method === "PATCH" &&
      path === "/v1/comma/me/profile" &&
      identity.profile
    ) {
      let body = "";
      request.on("data", (chunk: Buffer) => {
        body += chunk.toString("utf8");
      });
      request.on("end", () => {
        const patch = JSON.parse(body || "{}") as {
          locale?: "en" | "zh-CN";
          name?: string;
        };
        if (patch.locale) accountLocale = patch.locale;
        if (patch.name) accountName = patch.name;
        writeJson(response, accountProfile());
      });
      return;
    }
    if (
      request.method === "GET" &&
      identity.profile?.avatarId &&
      identity.profile.avatarPngBase64 &&
      path === `/v1/comma/me/avatar/${encodeURIComponent(identity.profile.avatarId)}`
    ) {
      response.writeHead(200, {
        "cache-control": "private, max-age=31536000, immutable",
        "content-type": "image/png",
      });
      response.end(Buffer.from(identity.profile.avatarPngBase64, "base64"));
      return;
    }
    if (identity.handleRequest?.(request, response, path)) return;
    writeJson(
      response,
      {
        error: `product backend unavailable for ${request.method ?? "UNKNOWN"} ${path}`,
      },
      503
    );
  });

  return new Promise<{
    baseUrl: string;
    close: () => Promise<void>;
    /** The account every session this stub verifies belongs to. */
    userId: string;
  }>((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as AddressInfo;
      resolve({
        baseUrl: `http://127.0.0.1:${port}`,
        close: () =>
          new Promise<void>((done) => {
            const httpServer = server as Server;
            httpServer.close(() => done());
            httpServer.closeAllConnections();
          }),
        userId: createE2eSessionProjection(identity).user.id,
      });
    });
  });
}

function setCorsHeaders(request: IncomingMessage, response: ServerResponse) {
  response.setHeader("access-control-allow-origin", request.headers.origin ?? "*");
  response.setHeader("access-control-allow-credentials", "true");
  response.setHeader(
    "access-control-allow-headers",
    reflectedCorsRequestHeaders(
      request.headers["access-control-request-headers"],
      "authorization,content-type,x-comma-session-transport"
    )
  );
  response.setHeader(
    "access-control-allow-methods",
    "GET,POST,PATCH,PUT,DELETE,OPTIONS"
  );
}

function writeJson(response: ServerResponse, body: unknown, status = 200) {
  response.writeHead(status, {
    "cache-control": "no-store",
    "content-type": "application/json",
  });
  response.end(JSON.stringify(body));
}
