import { Buffer } from "node:buffer";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { emptyRoutineEnvelope } from "../../../e2e/helpers/routine-fixture";

export const runtimeAccountA = {
  conversationId: "cnv-public-runtime-a",
  email: "runtime-a@comma.local",
  groupId: "grp1_1720000000000000001_1720000000000000002",
  token: "runtime-token-a",
  workspaceId: "ws-runtime-a",
};

export const runtimeAccountB = {
  conversationId: "cnv-public-runtime-b",
  email: "runtime-b@comma.local",
  groupId: "grp1_1720000000000000003_1720000000000000004",
  token: "runtime-token-b",
  workspaceId: "ws-runtime-b",
};

export type RuntimeFailureStatus = 401 | 403 | 404;

export type LateResolutionOutcome =
  | "success"
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "error";

export type RuntimeMessageAttempt = {
  body: {
    client_request_id?: string;
    message?: {
      content?: Array<Record<string, unknown>>;
      text?: string;
      type?: string;
    };
  };
  token: string;
};

export type RuntimeLocalFileRegistration = {
  body: {
    connector_run_id?: string;
    local_file_index_version?: number;
    local_file_ref?: string;
    stable_device_id?: string;
  };
  token: string;
};

export type RuntimeUpload = {
  bytes: Buffer;
  contentType: string;
  filename: string;
  path: string;
  token: string;
  workspaceId: string;
};

export type RuntimeWorkspaceFileRead = {
  path: string;
  token: string;
  workspaceId: string;
};

export async function startChatRuntimeStub({
  bootstrapFailureStatus,
  controlledAccountBEvents = false,
  deferAccountBResolution = false,
  deferAccountBMessages = false,
  ensureFailureStatus,
  googleLinkRequired = false,
  googleAttemptGate,
  googlePreparationFailures = 0,
  hangLogoutTokens = [],
  messageFailureReason,
  messageFailureStatus,
  messageFailureStatuses = [],
  sessionFailureCount = 0,
}: {
  bootstrapFailureStatus?: RuntimeFailureStatus;
  controlledAccountBEvents?: boolean;
  deferAccountBResolution?: boolean;
  deferAccountBMessages?: boolean;
  ensureFailureStatus?: RuntimeFailureStatus;
  googleLinkRequired?: boolean;
  googleAttemptGate?: Promise<void>;
  googlePreparationFailures?: number;
  hangLogoutTokens?: string[];
  /** The billing reason a 402 carries; without it the 402 is a bare billing_unavailable. */
  messageFailureReason?: "insufficient_credits";
  messageFailureStatus?: 402 | 500;
  messageFailureStatuses?: (402 | 500 | undefined)[];
  sessionFailureCount?: number;
} = {}) {
  const requests: { method: string; path: string; token: string }[] = [];
  const localFileRegistrations: RuntimeLocalFileRegistration[] = [];
  const messageAttempts: RuntimeMessageAttempt[] = [];
  const googleAttempts: unknown[] = [];
  const googleCompletions: unknown[] = [];
  const googleLinkVerifications: unknown[] = [];
  const emailVerifications: unknown[] = [];
  const uploads: RuntimeUpload[] = [];
  const workspaceFileReads: RuntimeWorkspaceFileRead[] = [];
  const serverMessages = new Map<string, ReturnType<typeof userMessage>[]>();
  const delayedAResponses: ServerResponse[] = [];
  const delayedAccountABodyResponses: ServerResponse[] = [];
  const delayedBResponses: ServerResponse[] = [];
  let aResolutionOutcome: LateResolutionOutcome | undefined;
  let bResolutionsReleased = false;
  const delayedBMessageResponses: ServerResponse[] = [];
  const queuedMessageFailureStatuses = [...messageFailureStatuses];
  const accountBEventResponses = new Set<ServerResponse>();
  let accountBEventStreamCount = 0;
  let notifyAResolutionStarted: (() => void) | undefined;
  let notifyAccountABodyHeadersSent: (() => void) | undefined;
  let notifyBResolutionStarted: (() => void) | undefined;
  const aResolutionStarted = new Promise<void>((resolve) => {
    notifyAResolutionStarted = resolve;
  });
  const accountABodyHeadersSent = new Promise<void>((resolve) => {
    notifyAccountABodyHeadersSent = resolve;
  });
  const bResolutionStarted = new Promise<void>((resolve) => {
    notifyBResolutionStarted = resolve;
  });

  const server = createServer(async (req, res) => {
    setCorsHeaders(res);
    if (req.method === "OPTIONS") {
      res.writeHead(204).end();
      return;
    }

    const method = req.method ?? "GET";
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    const path = url.pathname;
    const token = bearerToken(req);
    requests.push({ method, path, token });

    if (method === "POST" && path === "/v1/comma/auth/email/login") {
      const body = (await readJson(req)) as { email?: string };
      const account =
        body.email === runtimeAccountA.email ? runtimeAccountA : runtimeAccountB;
      writeJson(res, {
        challenge_id:
          account === runtimeAccountA ? "runtime-challenge-a" : "runtime-challenge-b",
        code: "654321",
      });
      return;
    }

    if (method === "POST" && path === "/v1/comma/auth/email/verify") {
      const body = (await readJson(req)) as { challenge_id?: string };
      emailVerifications.push(body);
      writeJson(
        res,
        issuedSessionFor(
          body.challenge_id === "runtime-challenge-a"
            ? runtimeAccountA
            : runtimeAccountB
        )
      );
      return;
    }

    if (method === "POST" && path === "/v1/comma/auth/google/attempt") {
      googleAttempts.push(await readJson(req));
      if (googlePreparationFailures-- > 0) {
        res.writeHead(503, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "auth_unavailable" }));
        return;
      }
      await googleAttemptGate;
      writeJson(res, {
        attempt_id: "runtime-google-attempt",
        client_id: "runtime-desktop-client",
        nonce: "runtime-google-nonce",
        platform: "electron",
      });
      return;
    }

    if (method === "POST" && path === "/v1/comma/auth/google") {
      googleCompletions.push(await readJson(req));
      if (googleLinkRequired) {
        writeJson(res, {
          challenge_id: "runtime-google-link-challenge",
          code: "654321",
          email: runtimeAccountB.email,
          status: "otp_required",
        });
        return;
      }
      writeJson(res, issuedSessionFor(runtimeAccountB));
      return;
    }

    if (method === "POST" && path === "/v1/comma/auth/google/link/verify") {
      googleLinkVerifications.push(await readJson(req));
      writeJson(res, issuedSessionFor(runtimeAccountB));
      return;
    }

    if (
      method === "POST" &&
      path === "/v1/comma/auth/logout" &&
      hangLogoutTokens.includes(token)
    ) {
      return;
    }

    const account = accountForToken(token);
    if (!account) {
      writeJson(res, { error: "unauthorized" }, 401);
      return;
    }

    if (
      account === runtimeAccountA &&
      method === "GET" &&
      path === "/v1/e2e/delayed-body"
    ) {
      res.writeHead(200, {
        "cache-control": "no-store",
        "content-type": "application/json",
      });
      res.flushHeaders();
      delayedAccountABodyResponses.push(res);
      notifyAccountABodyHeadersSent?.();
      notifyAccountABodyHeadersSent = undefined;
      return;
    }

    if (method === "GET" && path === "/v1/comma/auth/session") {
      if (sessionFailureCount > 0) {
        sessionFailureCount -= 1;
        writeJson(res, { error: "unavailable" }, 503);
        return;
      }
      const { token: _token, ...current } = issuedSessionFor(account);
      writeJson(res, current);
      return;
    }

    if (method === "POST" && path === "/v1/comma/auth/logout") {
      writeJson(res, { signed_out: true });
      return;
    }

    if (method === "POST" && path === "/v1/comma/me/bootstrap") {
      if (bootstrapFailureStatus) {
        writeRuntimeFailure(res, bootstrapFailureStatus);
        return;
      }
      writeJson(res, {
        status: "ready",
        workspace: {
          group_id: account.groupId,
          id: account.workspaceId,
          name: `Runtime ${account.email}`,
        },
      });
      return;
    }

    if (
      method === "POST" &&
      path === `/v1/comma/groups/${account.groupId}/assistant-chat`
    ) {
      if (account === runtimeAccountA) {
        notifyAResolutionStarted?.();
        notifyAResolutionStarted = undefined;
        if (!aResolutionOutcome) {
          delayedAResponses.push(res);
          return;
        }
        writeAResolution(res, aResolutionOutcome);
        return;
      }
      if (ensureFailureStatus) {
        writeRuntimeFailure(res, ensureFailureStatus);
        return;
      }
      if (deferAccountBResolution && !bResolutionsReleased) {
        delayedBResponses.push(res);
        notifyBResolutionStarted?.();
        notifyBResolutionStarted = undefined;
        return;
      }

      writeJson(res, conversationFor(account, messagesFor(account.token)));
      return;
    }

    if (
      method === "GET" &&
      path === `/v1/comma/workspaces/${account.workspaceId}/skills`
    ) {
      writeJson(res, { data: [] });
      return;
    }

    if (
      method === "GET" &&
      path === `/v1/comma/workspaces/${account.workspaceId}/recommendations`
    ) {
      writeJson(res, emptyRoutineEnvelope);
      return;
    }

    if (
      method === "POST" &&
      path === `/v1/comma/workspaces/${account.workspaceId}/local-file-refs`
    ) {
      const body = (await readJson(req)) as RuntimeLocalFileRegistration["body"];
      localFileRegistrations.push({ body, token });
      writeJson(res, { local_file_ref: body.local_file_ref, state: "registered" }, 201);
      return;
    }

    if (
      method === "GET" &&
      path ===
        `/v1/comma/groups/${account.groupId}/conversations/${account.conversationId}`
    ) {
      writeJson(res, conversationFor(account, messagesFor(account.token)));
      return;
    }

    if (method === "POST" && path === `/v1/comma/groups/${account.groupId}/files`) {
      const body = await readBuffer(req);
      const file = parseMultipartFile(req.headers["content-type"], body);
      const filename = file?.filename ?? "file.bin";
      const bytes = file?.bytes ?? Buffer.alloc(0);
      const upload = {
        bytes,
        contentType: imageContentType(filename),
        filename,
        path: `/uploads/${String(uploads.length + 1).padStart(22, "0")}-${filename}`,
        token,
        workspaceId: account.workspaceId,
      };
      uploads.push(upload);
      writeJson(
        res,
        { name: upload.filename, path: upload.path, size: upload.bytes.byteLength },
        201
      );
      return;
    }

    if (method === "GET" && path === `/v1/comma/groups/${account.groupId}/files`) {
      const requestedPath = url.searchParams.get("path") ?? "";
      const upload = uploads.find(
        (candidate) =>
          candidate.path === requestedPath &&
          candidate.token === token &&
          candidate.workspaceId === account.workspaceId
      );
      if (
        !upload ||
        upload.bytes.byteLength === 0 ||
        upload.bytes.byteLength > 10_000_000 ||
        !upload.contentType.startsWith("image/")
      ) {
        writeJson(res, { error: "not_found" }, 404);
        return;
      }
      workspaceFileReads.push({
        path: requestedPath,
        token,
        workspaceId: account.workspaceId,
      });
      res.writeHead(200, {
        "cache-control": "private, no-store",
        "content-length": upload.bytes.byteLength,
        "content-type": upload.contentType,
        "x-content-type-options": "nosniff",
      });
      res.end(upload.bytes);
      return;
    }

    if (
      method === "GET" &&
      path ===
        `/v1/comma/groups/${account.groupId}/conversations/${account.conversationId}/messages`
    ) {
      writeJson(res, { data: messagesFor(account.token) });
      return;
    }

    if (
      method === "POST" &&
      path ===
        `/v1/comma/groups/${account.groupId}/conversations/${account.conversationId}/messages`
    ) {
      const body = (await readJson(req)) as RuntimeMessageAttempt["body"];
      messageAttempts.push({ body, token });
      const queuedFailureStatus = queuedMessageFailureStatuses.shift();
      const currentMessageFailureStatus = queuedFailureStatus ?? messageFailureStatus;
      if (currentMessageFailureStatus) {
        writeJson(
          res,
          {
            error:
              currentMessageFailureStatus === 402
                ? "billing_unavailable"
                : `runtime_message_${currentMessageFailureStatus}`,
            ...(currentMessageFailureStatus === 402 && messageFailureReason
              ? { reason: messageFailureReason }
              : {}),
          },
          currentMessageFailureStatus
        );
        return;
      }

      const message = userMessage(body, messageAttempts.length);
      if (controlledAccountBEvents && account === runtimeAccountB) {
        messagesFor(account.token).push(message);
      } else {
        messagesFor(account.token).splice(0, Infinity, message);
      }
      if (deferAccountBMessages && account === runtimeAccountB) {
        delayedBMessageResponses.push(res);
        return;
      }
      writeJson(res, conversationFor(account, messagesFor(account.token)));
      return;
    }

    if (
      method === "GET" &&
      path ===
        `/v1/comma/groups/${account.groupId}/conversations/${account.conversationId}/events`
    ) {
      if (controlledAccountBEvents && account === runtimeAccountB) {
        accountBEventStreamCount += 1;
        accountBEventResponses.add(res);
        res.on("close", () => accountBEventResponses.delete(res));
        openSse(res);
        return;
      }
      writeSse(res, {
        conversation_id: account.conversationId,
        messages: messagesFor(account.token),
        status: "open",
        type: "snapshot",
        group_id: account.groupId,
      });
      return;
    }

    writeJson(res, { error: `unhandled ${method} ${path}` }, 404);
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;

  return {
    get accountBEventClientCount() {
      return accountBEventResponses.size;
    },
    get accountBEventStreamCount() {
      return accountBEventStreamCount;
    },
    aResolutionStarted,
    accountABodyHeadersSent,
    baseUrl: `http://127.0.0.1:${port}`,
    bResolutionStarted,
    close: () =>
      new Promise<void>((resolve) => {
        server.close(() => resolve());
        server.closeAllConnections();
      }),
    emailVerifications,
    googleAttempts,
    googleCompletions,
    googleLinkVerifications,
    localFileRegistrations,
    messageAttempts,
    requests,
    disconnectAccountBEvents() {
      if (accountBEventResponses.size === 0) {
        throw new Error("Account B has no open controlled event stream.");
      }
      for (const response of accountBEventResponses) {
        response.end();
      }
    },
    emitAccountBEvent(event: string, data: Record<string, unknown>) {
      if (accountBEventResponses.size === 0) {
        throw new Error("Account B has no open controlled event stream.");
      }
      if (event === "snapshot" && Array.isArray(data.messages)) {
        messagesFor(runtimeAccountB.token).splice(
          0,
          Infinity,
          ...(data.messages as ReturnType<typeof userMessage>[])
        );
      }
      for (const response of accountBEventResponses) {
        response.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
      }
    },
    emitAccountBEventBatch(events: { data: Record<string, unknown>; event: string }[]) {
      if (accountBEventResponses.size === 0) {
        throw new Error("Account B has no open controlled event stream.");
      }
      for (const { data, event } of events) {
        if (event === "snapshot" && Array.isArray(data.messages)) {
          messagesFor(runtimeAccountB.token).splice(
            0,
            Infinity,
            ...(data.messages as ReturnType<typeof userMessage>[])
          );
        }
      }
      const payload = events
        .map(({ data, event }) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`)
        .join("");
      for (const response of accountBEventResponses) {
        response.write(payload);
      }
    },
    settleAResolution(outcome: LateResolutionOutcome) {
      if (delayedAResponses.length === 0) {
        throw new Error("Account A Workspace Chat resolution has not started.");
      }
      aResolutionOutcome = outcome;
      for (const response of delayedAResponses.splice(0)) {
        writeAResolution(response, outcome);
      }
    },
    settleAccountADelayedBody() {
      if (delayedAccountABodyResponses.length === 0) {
        throw new Error("Account A delayed response headers have not been sent.");
      }
      for (const response of delayedAccountABodyResponses.splice(0)) {
        response.end(
          JSON.stringify({
            account: runtimeAccountA.email,
            marker: "account-a-delayed-body",
          })
        );
      }
    },
    settleBResolution(failureStatus?: RuntimeFailureStatus) {
      if (delayedBResponses.length === 0) {
        throw new Error("Account B Workspace Chat resolution has not started.");
      }
      bResolutionsReleased = true;
      for (const response of delayedBResponses.splice(0)) {
        if (failureStatus) {
          writeRuntimeFailure(response, failureStatus);
        } else {
          writeJson(
            response,
            conversationFor(runtimeAccountB, messagesFor(runtimeAccountB.token))
          );
        }
      }
    },
    settleNextAccountBMessage() {
      const response = delayedBMessageResponses.shift();
      if (!response) {
        throw new Error("Account B has no deferred message response.");
      }
      writeJson(
        response,
        conversationFor(runtimeAccountB, messagesFor(runtimeAccountB.token))
      );
    },
    uploads,
    workspaceFileReads,
  };

  function messagesFor(token: string) {
    let messages = serverMessages.get(token);
    if (!messages) {
      messages = [];
      serverMessages.set(token, messages);
    }
    return messages;
  }

  function writeAResolution(response: ServerResponse, outcome: LateResolutionOutcome) {
    if (outcome === "success") {
      writeJson(
        response,
        conversationFor(runtimeAccountA, messagesFor(runtimeAccountA.token))
      );
      return;
    }
    if (outcome === "unauthorized") {
      writeRuntimeFailure(response, 401);
      return;
    }
    if (outcome === "forbidden") {
      writeRuntimeFailure(response, 403);
      return;
    }
    if (outcome === "not_found") {
      writeRuntimeFailure(response, 404);
      return;
    }
    writeJson(response, { error: "runtime_error" }, 500);
  }
}

function accountForToken(token: string) {
  if (token === runtimeAccountA.token) return runtimeAccountA;
  if (token === runtimeAccountB.token) return runtimeAccountB;
  return undefined;
}

function issuedSessionFor(account: typeof runtimeAccountA | typeof runtimeAccountB) {
  return {
    expires_at: 4_102_444_800,
    session_id: `runtime-session:${account.email}`,
    token: account.token,
    user: {
      email: account.email,
      id: account === runtimeAccountA ? "user-runtime-a" : "user-runtime-b",
      name: null,
      status: "active",
    },
  };
}

function conversationFor(
  account: typeof runtimeAccountA | typeof runtimeAccountB,
  messages: ReturnType<typeof userMessage>[]
) {
  return {
    id: account.conversationId,
    group_id: account.groupId,
    kind: "user_chat",
    messages,
    status: "open",
    title: `Chat ${account.email}`,
  };
}

function userMessage(body: RuntimeMessageAttempt["body"], sequence: number) {
  const contentBlocks = body.message?.content;
  const textBlockValue = contentBlocks?.find((block) => block.type === "text")?.text;
  const text =
    typeof textBlockValue === "string" ? textBlockValue : (body.message?.text ?? "");
  return {
    actor_type: "user",
    client_request_id: body.client_request_id ?? `runtime-request-${sequence}`,
    content: contentBlocks ?? [{ type: "text", text }],
    created_at: 1_720_000_000 + sequence,
    kind: "message",
    message_id: `runtime-user-message-${sequence}`,
  };
}

function bearerToken(req: IncomingMessage) {
  const header = req.headers.authorization ?? "";
  return header.startsWith("Bearer ") ? header.slice("Bearer ".length) : "";
}

function setCorsHeaders(res: ServerResponse) {
  res.setHeader("access-control-allow-origin", "*");
  res.setHeader("access-control-allow-headers", "authorization,content-type,accept");
  res.setHeader("access-control-allow-methods", "GET,POST,OPTIONS");
}

function writeJson(res: ServerResponse, body: unknown, status = 200) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

function writeRuntimeFailure(res: ServerResponse, status: RuntimeFailureStatus) {
  const error =
    status === 401 ? "unauthorized" : status === 403 ? "forbidden" : "not_found";
  writeJson(res, { error }, status);
}

function writeSse(res: ServerResponse, snapshot: unknown) {
  res.writeHead(200, { "content-type": "text/event-stream" });
  res.end(`event: snapshot\ndata: ${JSON.stringify(snapshot)}\n\n`);
}

function openSse(res: ServerResponse) {
  res.writeHead(200, {
    "cache-control": "no-cache",
    connection: "keep-alive",
    "content-type": "text/event-stream",
  });
  res.flushHeaders();
}

function readJson(req: IncomingMessage) {
  return readBuffer(req).then((buffer) => {
    const raw = buffer.toString("utf8");
    return raw ? JSON.parse(raw) : {};
  });
}

function readBuffer(req: IncomingMessage) {
  return new Promise<Buffer>((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function parseMultipartFile(contentType: string | undefined, body: Buffer) {
  const boundary = contentType
    ?.match(/boundary=(?:"([^"]+)"|([^;\s]+))/i)
    ?.slice(1)
    .find(Boolean);
  if (!boundary) return undefined;

  const headerEnd = body.indexOf(Buffer.from("\r\n\r\n"));
  const contentEnd = body.lastIndexOf(Buffer.from(`\r\n--${boundary}`));
  if (headerEnd < 0 || contentEnd < headerEnd + 4) return undefined;

  const headers = body.subarray(0, headerEnd).toString("latin1");
  const filename = headers.match(/filename="([^"]+)"/)?.[1];
  if (!filename) return undefined;
  return {
    bytes: body.subarray(headerEnd + 4, contentEnd),
    filename,
  };
}

function imageContentType(filename: string) {
  const normalized = filename.toLowerCase();
  if (normalized.endsWith(".png")) return "image/png";
  if (normalized.endsWith(".jpg") || normalized.endsWith(".jpeg")) {
    return "image/jpeg";
  }
  if (normalized.endsWith(".gif")) return "image/gif";
  if (normalized.endsWith(".webp")) return "image/webp";
  return "application/octet-stream";
}
