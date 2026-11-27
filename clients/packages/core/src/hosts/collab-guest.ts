import { z } from "zod";

/**
 * Credential-free / guest-token client for external email guest collaboration
 * pages (`/c/:token`). Holds no Comma account session; all requests use
 * `credentials: "omit"` and `referrerPolicy: "no-referrer"`.
 */

export const MAX_GUEST_FILE_BYTES = 25 * 1024 * 1024;

const inviteInfoSchema = z
  .object({
    invite: z
      .object({
        status: z.enum(["invited", "active"]),
        email_hint: z.string(),
        expires_at: z.string(),
        title: z.string(),
        host_name: z.string(),
      })
      .strip(),
  })
  .strip();

const otpRequestResponseSchema = z
  .object({
    challenge_id: z.string(),
    expires_in_seconds: z.number(),
    resend_after_seconds: z.number(),
    email_hint: z.string(),
  })
  .strip();

const guestIdentitySchema = z
  .object({
    email: z.string(),
    name: z.string().nullable().optional(),
  })
  .strip()
  .transform((g) => ({
    email: g.email,
    name: g.name ?? "",
  }));

const otpVerifyResponseSchema = z
  .object({
    token: z.string(),
    expires_at: z.string(),
    guest: guestIdentitySchema,
    task: z
      .object({
        group_id: z.string(),
        conversation_id: z.string(),
        title: z.string(),
        status: z.string(),
      })
      .strip(),
  })
  .strip();

// Privacy rule (4.2): other members never expose email or email_hint.
const memberSchema = z
  .object({
    role: z.enum(["host", "member"]),
    name: z.string().nullable().optional(),
    status: z.enum(["active", "invited"]),
    is_guest: z.boolean().optional(),
    is_self: z.boolean().optional(),
  })
  .strip()
  .transform((m) => ({
    role: m.role,
    name: m.name ?? null,
    status: m.status,
    is_guest: m.is_guest ?? false,
    is_self: m.is_self ?? false,
  }));

const taskPayloadSchema = z
  .object({
    guest: guestIdentitySchema,
    task: z
      .object({
        group_id: z.string(),
        conversation_id: z.string(),
        title: z.string(),
        status: z.string(),
        host_name: z.string(),
        members: z.array(memberSchema),
      })
      .strip(),
    messages: z.array(z.unknown()),
    next_cursor: z.string().nullable().optional(),
  })
  .strip();

const filesPayloadSchema = z
  .object({
    entries: z.array(
      z
        .object({
          path: z.string(),
          size: z.number().optional(),
          updated_at: z.string().optional(),
          content_type: z.string().optional(),
        })
        .strip()
    ),
  })
  .strip();

export type CollabGuestInvite = z.output<typeof inviteInfoSchema>["invite"];
export type CollabGuestOtpChallenge = z.output<typeof otpRequestResponseSchema>;
export type CollabGuestIdentity = z.output<typeof guestIdentitySchema>;
export type CollabGuestVerifyResult = z.output<typeof otpVerifyResponseSchema>;
export type CollabGuestMember = z.output<typeof memberSchema>;
export type CollabGuestTaskData = z.output<typeof taskPayloadSchema>;
export type CollabGuestFileEntry = z.output<
  typeof filesPayloadSchema
>["entries"][number];
export type CollabGuestFilesData = z.output<typeof filesPayloadSchema>;

export interface CollabGuestMiniAppBlock {
  appId: string;
  name: string;
  summary: string;
  version?: number | undefined;
}

export interface CollabGuestAttachmentBlock {
  fileName: string;
  path?: string | undefined;
  size?: number | undefined;
  mimeType?: string | undefined;
}

export interface CollabGuestMessage {
  id: string;
  role: "user" | "assistant" | "system";
  senderName: string | null;
  isGuestSender: boolean;
  isSelf: boolean;
  createdAt?: string | number | undefined;
  text: string;
  miniApps: CollabGuestMiniAppBlock[];
  attachments: CollabGuestAttachmentBlock[];
  streaming?: boolean | undefined;
}

export type CollabGuestErrorCode =
  | "not_found"
  | "invite_expired"
  | "email_mismatch"
  | "rate_limited"
  | "invalid_code"
  | "challenge_expired"
  | "guest_session_revoked"
  | "file_too_large"
  | "unavailable";

export class CollabGuestError extends Error {
  readonly code: CollabGuestErrorCode;
  readonly status: number;
  readonly retryAfterSeconds?: number | undefined;

  constructor(
    code: CollabGuestErrorCode,
    status: number,
    extra?: {
      message?: string | undefined;
      retryAfterSeconds?: number | undefined;
    }
  ) {
    super(extra?.message ?? code);
    this.name = "CollabGuestError";
    this.code = code;
    this.status = status;
    this.retryAfterSeconds = extra?.retryAfterSeconds;
  }
}

export interface StoredGuestSession {
  token: string;
  expiresAt?: string | undefined;
  guest?: CollabGuestIdentity | undefined;
}

const STORAGE_PREFIX = "comma:collab-guest:v1:";

export function readStoredGuestSession(inviteToken: string): StoredGuestSession | null {
  if (!inviteToken) return null;
  try {
    const raw =
      window.sessionStorage.getItem(`${STORAGE_PREFIX}${inviteToken}`) ??
      window.localStorage.getItem(`${STORAGE_PREFIX}${inviteToken}`);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<StoredGuestSession>;
    if (typeof parsed.token !== "string" || !parsed.token) return null;
    return {
      token: parsed.token,
      expiresAt: typeof parsed.expiresAt === "string" ? parsed.expiresAt : undefined,
      guest:
        parsed.guest && typeof parsed.guest.email === "string"
          ? { email: parsed.guest.email, name: parsed.guest.name ?? "" }
          : undefined,
    };
  } catch {
    return null;
  }
}

export function writeStoredGuestSession(
  inviteToken: string,
  session: StoredGuestSession
): void {
  if (!inviteToken) return;
  const serialized = JSON.stringify(session);
  try {
    window.sessionStorage.setItem(`${STORAGE_PREFIX}${inviteToken}`, serialized);
  } catch {
    // Ignore storage quota or private-mode restrictions.
  }
  try {
    window.localStorage.setItem(`${STORAGE_PREFIX}${inviteToken}`, serialized);
  } catch {
    // Ignore storage quota or private-mode restrictions.
  }
}

export function clearStoredGuestSession(inviteToken: string): void {
  if (!inviteToken) return;
  try {
    window.sessionStorage.removeItem(`${STORAGE_PREFIX}${inviteToken}`);
  } catch {
    // Ignore storage restrictions.
  }
  try {
    window.localStorage.removeItem(`${STORAGE_PREFIX}${inviteToken}`);
  } catch {
    // Ignore storage restrictions.
  }
}

/** Extracts the invite token from `/c/<token>`. */
export function collabTokenFromPath(pathname: string): string | undefined {
  const match = /^\/c\/([^/?#]+)\/?$/.exec(pathname);
  if (!match?.[1]) return undefined;
  try {
    return decodeURIComponent(match[1]);
  } catch {
    return match[1];
  }
}

/** Normalizes a raw backend message object into a UI-safe CollabGuestMessage. */
export function normalizeGuestMessage(
  raw: unknown,
  fallbackId: string
): CollabGuestMessage {
  const obj = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const id =
    typeof obj.id === "string" && obj.id
      ? obj.id
      : typeof obj.message_id === "string" && obj.message_id
        ? obj.message_id
        : fallbackId;
  const rawRole = typeof obj.role === "string" ? obj.role : "user";
  const role: "user" | "assistant" | "system" =
    rawRole === "assistant" || rawRole === "worker" || rawRole === "agent"
      ? "assistant"
      : rawRole === "system"
        ? "system"
        : "user";

  const senderObj =
    obj.sender && typeof obj.sender === "object"
      ? (obj.sender as Record<string, unknown>)
      : undefined;
  const rawName =
    typeof obj.sender_name === "string"
      ? obj.sender_name
      : typeof senderObj?.name === "string"
        ? senderObj.name
        : typeof obj.author_name === "string"
          ? obj.author_name
          : null;
  const senderName = rawName && rawName.trim() ? rawName.trim() : null;
  const isGuestSender = obj.is_guest === true || senderObj?.is_guest === true;
  const isSelf = obj.is_self === true || senderObj?.is_self === true;
  const createdAt =
    typeof obj.created_at === "string" || typeof obj.created_at === "number"
      ? obj.created_at
      : undefined;

  const textParts: string[] = [];
  const miniApps: CollabGuestMiniAppBlock[] = [];
  const attachments: CollabGuestAttachmentBlock[] = [];

  if (typeof obj.text === "string" && obj.text.trim()) {
    textParts.push(obj.text);
  } else if (typeof obj.content === "string" && obj.content.trim()) {
    textParts.push(obj.content);
  }

  const blocks = Array.isArray(obj.content)
    ? obj.content
    : Array.isArray(obj.parts)
      ? obj.parts
      : [];

  for (const item of blocks) {
    if (!item || typeof item !== "object") continue;
    const block = item as Record<string, unknown>;
    const type = typeof block.type === "string" ? block.type : block.kind;
    if ((type === "text" || type === "markdown") && typeof block.text === "string") {
      textParts.push(block.text);
    } else if (type === "mini_app" || type === "mini-app") {
      const appId =
        typeof block.app_id === "string"
          ? block.app_id
          : typeof block.appId === "string"
            ? block.appId
            : "";
      if (appId) {
        const versionRaw = block.version ?? block.appVersion ?? block.app_version;
        const version =
          typeof versionRaw === "number" &&
          Number.isSafeInteger(versionRaw) &&
          versionRaw > 0
            ? versionRaw
            : undefined;
        miniApps.push({
          appId,
          name:
            typeof block.name === "string" && block.name.trim()
              ? block.name.trim()
              : "Mini App",
          summary: typeof block.summary === "string" ? block.summary : "",
          version,
        });
      }
    } else if (type === "file" || type === "image") {
      const fileName =
        typeof block.file_name === "string"
          ? block.file_name
          : typeof block.fileName === "string"
            ? block.fileName
            : typeof block.path === "string"
              ? (block.path.split("/").pop() ?? block.path)
              : "";
      if (fileName) {
        attachments.push({
          fileName,
          path: typeof block.path === "string" ? block.path : undefined,
          size: typeof block.size === "number" ? block.size : undefined,
          mimeType:
            typeof block.mime_type === "string"
              ? block.mime_type
              : typeof block.mimeType === "string"
                ? block.mimeType
                : undefined,
        });
      }
    }
  }

  return {
    id,
    role,
    senderName,
    isGuestSender,
    isSelf,
    createdAt,
    text: textParts.join("\n\n").trim(),
    miniApps,
    attachments,
    streaming: obj.streaming === true,
  };
}

async function parseErrorResponse(response: Response): Promise<CollabGuestError> {
  let body: Record<string, unknown> = {};
  try {
    const json: unknown = await response.json();
    if (json && typeof json === "object") body = json as Record<string, unknown>;
  } catch {
    // Non-JSON error body.
  }
  const errorTag = typeof body.error === "string" ? body.error : undefined;
  const message = typeof body.message === "string" ? body.message : undefined;
  const retryAfterSeconds =
    typeof body.retry_after_seconds === "number" ? body.retry_after_seconds : undefined;

  if (response.status === 410 || errorTag === "invite_expired") {
    return new CollabGuestError("invite_expired", response.status, { message });
  }
  if (response.status === 404 || errorTag === "not_found") {
    return new CollabGuestError("not_found", response.status, { message });
  }
  if (response.status === 403 && errorTag === "email_mismatch") {
    return new CollabGuestError("email_mismatch", response.status, { message });
  }
  if (response.status === 429 || errorTag === "rate_limited") {
    return new CollabGuestError("rate_limited", response.status, {
      message,
      retryAfterSeconds,
    });
  }
  if (errorTag === "guest_session_revoked" || response.status === 401) {
    if (errorTag === "invalid_code") {
      return new CollabGuestError("invalid_code", response.status, { message });
    }
    if (errorTag === "challenge_expired") {
      return new CollabGuestError("challenge_expired", response.status, { message });
    }
    return new CollabGuestError("guest_session_revoked", response.status, { message });
  }
  if (errorTag === "invalid_code") {
    return new CollabGuestError("invalid_code", response.status, { message });
  }
  if (errorTag === "challenge_expired") {
    return new CollabGuestError("challenge_expired", response.status, { message });
  }
  if (errorTag === "file_too_large") {
    return new CollabGuestError("file_too_large", response.status, { message });
  }
  if (response.status === 413) {
    return new CollabGuestError("file_too_large", response.status, { message });
  }
  return new CollabGuestError("unavailable", response.status, { message });
}

export type CollabGuestClient = ReturnType<typeof createCollabGuestClient>;

export function createCollabGuestClient(
  baseUrl: string,
  inviteToken: string,
  fetchImpl: typeof fetch = (input, init) => fetch(input, init)
) {
  const root = `${baseUrl.replace(/\/+$/, "")}/v1/comma/public/collaborations`;
  const encodedInvite = encodeURIComponent(inviteToken);
  let sentSeq = 0;

  async function request(path: string, init: RequestInit = {}): Promise<Response> {
    let response: Response;
    try {
      response = await fetchImpl(root + path, {
        ...init,
        credentials: "omit",
        referrerPolicy: "no-referrer",
      });
    } catch (error) {
      if (init.signal?.aborted) throw error;
      throw new CollabGuestError("unavailable", 0);
    }
    if (!response.ok) {
      throw await parseErrorResponse(response);
    }
    return response;
  }

  return {
    async getInvite(signal?: AbortSignal): Promise<CollabGuestInvite> {
      const res = await request(`/invites/${encodedInvite}`, {
        method: "GET",
        ...(signal ? { signal } : {}),
      });
      return inviteInfoSchema.parse(await res.json()).invite;
    },

    async requestOtp(
      email?: string,
      signal?: AbortSignal
    ): Promise<CollabGuestOtpChallenge> {
      const res = await request(`/invites/${encodedInvite}/otp/request`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(email ? { email } : {}),
        ...(signal ? { signal } : {}),
      });
      return otpRequestResponseSchema.parse(await res.json());
    },

    async verifyOtp(
      params: { challengeId: string; code: string; name?: string },
      signal?: AbortSignal
    ): Promise<CollabGuestVerifyResult> {
      const res = await request(`/invites/${encodedInvite}/otp/verify`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          challenge_id: params.challengeId,
          code: params.code,
          ...(params.name?.trim() ? { name: params.name.trim() } : {}),
        }),
        ...(signal ? { signal } : {}),
      });
      return otpVerifyResponseSchema.parse(await res.json());
    },

    async getTask(
      sessionToken: string,
      options?: { limit?: number; before?: string; signal?: AbortSignal }
    ): Promise<CollabGuestTaskData> {
      const params = new URLSearchParams({
        limit: String(options?.limit ?? 100),
      });
      if (options?.before) params.set("before", options.before);
      const res = await request(`/task?${params.toString()}`, {
        method: "GET",
        headers: { authorization: `Bearer ${sessionToken}` },
        ...(options?.signal ? { signal: options.signal } : {}),
      });
      return taskPayloadSchema.parse(await res.json());
    },

    async sendMessage(
      sessionToken: string,
      params: { text: string; mentionComma?: boolean },
      signal?: AbortSignal
    ): Promise<CollabGuestMessage> {
      const res = await request("/task/messages", {
        method: "POST",
        headers: {
          authorization: `Bearer ${sessionToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          text: params.text,
          ...(params.mentionComma !== undefined
            ? { mention_comma: params.mentionComma }
            : {}),
        }),
        ...(signal ? { signal } : {}),
      });
      const json = (await res.json()) as { message?: unknown };
      return normalizeGuestMessage(json.message ?? json, `msg-${++sentSeq}`);
    },

    async listFiles(
      sessionToken: string,
      signal?: AbortSignal
    ): Promise<CollabGuestFilesData> {
      const res = await request("/task/files", {
        method: "GET",
        headers: { authorization: `Bearer ${sessionToken}` },
        ...(signal ? { signal } : {}),
      });
      return filesPayloadSchema.parse(await res.json());
    },

    async uploadFile(
      sessionToken: string,
      file: File,
      signal?: AbortSignal
    ): Promise<void> {
      const form = new FormData();
      form.append("file", file, file.name);
      await request("/task/files", {
        method: "POST",
        headers: { authorization: `Bearer ${sessionToken}` },
        body: form,
        ...(signal ? { signal } : {}),
      });
    },

    async leaveTask(sessionToken: string, signal?: AbortSignal): Promise<void> {
      await request("/task/leave", {
        method: "POST",
        headers: { authorization: `Bearer ${sessionToken}` },
        ...(signal ? { signal } : {}),
      });
    },

    eventsUrl(sessionToken: string): string {
      return `${root}/task/events?token=${encodeURIComponent(sessionToken)}`;
    },

    openEvents(sessionToken: string): EventSource | null {
      if (typeof EventSource === "undefined") return null;
      return new EventSource(
        `${root}/task/events?token=${encodeURIComponent(sessionToken)}`
      );
    },

    downloadFileUrl(sessionToken: string, path: string): string {
      const params = new URLSearchParams({ path, token: sessionToken });
      return `${root}/task/files/download?${params.toString()}`;
    },
  };
}
