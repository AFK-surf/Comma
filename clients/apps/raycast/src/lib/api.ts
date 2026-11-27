// The Comma API as the extension uses it, with the extension's own session.

/** The session is gone: expired, revoked, or ended with the desktop session that paired it. */
export class Unauthorized extends Error {
  constructor() {
    super("The Comma session ended.");
  }
}

export class ApiError extends Error {
  readonly status: number;
  constructor(status: number) {
    super(`Comma answered ${status}.`);
    this.status = status;
  }
}

export type Fetch = (
  url: string,
  init: {
    method: string;
    headers: Record<string, string>;
    body?: string;
    redirect: "error";
    signal?: AbortSignal;
  }
) => Promise<{ status: number; json(): Promise<unknown> }>;

export interface IssuedSession {
  token: string;
  email: string;
  expiresAt: number;
}

export interface ApiWorkspace {
  id: string;
  groupId: string;
  name: string;
}

export interface ApiTask {
  conversationId: string;
  groupId: string;
  title: string;
  status: string;
}

/** A Task that a search found. `snippet` is the text that matched. */
export interface ApiTaskHit {
  conversationId: string;
  groupId: string;
  title: string;
  snippet: string;
  matchedField: "title" | "content";
}

/** The most Tasks one search answers. */
export const SEARCH_LIMIT = 20;
/** The longest query the extension sends, in code points. The Comma app uses the same limit. */
export const SEARCH_MAX_CODEPOINTS = 128;

/**
 * The query as the extension sends it: no NUL, NFKC-normalized, no outer blank space, and no longer than the limit.
 * The server and the Comma core normalize a query the same way.
 */
export function searchQuery(typed: string): string {
  return Array.from(typed.replaceAll("\0", "").normalize("NFKC").trim())
    .slice(0, SEARCH_MAX_CODEPOINTS)
    .join("")
    .trim();
}

/** How long one request may take before the command says Comma could not be reached. */
export const REQUEST_TIMEOUT_MS = 15_000;

const text = (value: unknown, fallback = ""): string =>
  typeof value === "string" ? value : fallback;
const record = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" ? (value as Record<string, unknown>) : {};
const list = (value: unknown): unknown[] => (Array.isArray(value) ? value : []);

export class CommaApi {
  readonly #origin: string;
  readonly #fetch: Fetch;
  readonly #token: string | undefined;

  constructor(origin: string, fetch: Fetch, token?: string) {
    this.#origin = origin;
    this.#fetch = fetch;
    this.#token = token;
  }

  /** Exchanges the desktop app's pairing, with the verifier this extension kept, for a session of its own. */
  async exchange(input: {
    pairingId: string;
    pairingSecret: string;
    verifier: string;
    platform: "macos" | "windows";
  }): Promise<IssuedSession> {
    const answer = record(
      await this.#request("POST", "/v1/comma/auth/raycast/exchange", {
        pairing_id: input.pairingId,
        pairing_secret: input.pairingSecret,
        verifier: input.verifier,
        client_platform: input.platform,
      })
    );
    const token = text(answer["token"]);
    const expiresAt = answer["expires_at"];
    if (!token || typeof expiresAt !== "number") throw new ApiError(502);
    return { token, email: text(record(answer["user"])["email"]), expiresAt };
  }

  /** Ends this session only. The desktop app stays signed in. */
  async logout(): Promise<void> {
    await this.#request("POST", "/v1/comma/auth/logout", {});
  }

  async workspaces(): Promise<ApiWorkspace[]> {
    const answer = record(await this.#request("GET", "/v1/comma/workspaces"));
    return list(answer["data"])
      .map(record)
      .map((row) => ({
        id: text(row["id"]),
        groupId: text(row["group_id"]),
        name: text(row["name"], "Workspace"),
      }))
      .filter((workspace) => workspace.id && workspace.groupId);
  }

  /** The Workspace's Home conversation. */
  async home(groupId: string): Promise<string> {
    const answer = record(
      await this.#request(
        "POST",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/assistant-chat?message_limit=1`,
        {}
      )
    );
    const id = text(answer["id"]);
    if (!id) throw new ApiError(502);
    return id;
  }

  /** Sends an ordinary message. Only an accepted message id means the server took it. */
  async send(
    groupId: string,
    conversationId: string,
    message: string,
    requestId: string
  ): Promise<void> {
    const answer = record(
      await this.#request(
        "POST",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/conversations/${encodeURIComponent(conversationId)}/messages`,
        { message: { type: "text", text: message }, client_request_id: requestId }
      )
    );
    if (!text(answer["accepted_message_id"])) throw new ApiError(502);
  }

  /** One page of the Workspace's Tasks, newest first. */
  async tasks(
    groupId: string,
    cursor?: string
  ): Promise<{ tasks: ApiTask[]; next: string | undefined }> {
    const query = new URLSearchParams({ limit: "50" });
    if (cursor) query.set("cursor", cursor);
    const answer = record(
      await this.#request(
        "GET",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/conversations?${query}`
      )
    );
    return {
      tasks: list(answer["data"])
        .map(record)
        .map((row) => ({
          conversationId: text(row["id"]),
          groupId: text(row["group_id"], groupId),
          title: text(row["title"], "Untitled Task"),
          status: text(row["status"]),
        }))
        .filter((task) => task.conversationId),
      next:
        answer["has_more"] === true
          ? text(answer["next_cursor"]) || undefined
          : undefined,
    };
  }

  /** The Workspace's Tasks whose title or Message text matches `query`, best match first. */
  async search(groupId: string, query: string): Promise<ApiTaskHit[]> {
    const params = new URLSearchParams({ q: query, limit: String(SEARCH_LIMIT) });
    const answer = record(
      await this.#request(
        "GET",
        `/v1/comma/groups/${encodeURIComponent(groupId)}/conversations/search?${params}`
      )
    );
    return list(answer["data"])
      .map(record)
      .map((row) => ({
        conversationId: text(row["conversation_id"]),
        groupId,
        title: text(row["title"]) || "Untitled Task",
        // One line: a List subtitle does not show line breaks.
        snippet: text(row["snippet"]).replace(/\s+/g, " ").trim(),
        matchedField:
          row["matched_field"] === "content"
            ? ("content" as const)
            : ("title" as const),
      }))
      .filter((hit) => hit.conversationId);
  }

  async #request(method: string, path: string, body?: unknown): Promise<unknown> {
    const response = await this.#fetch(this.#origin + path, {
      method,
      headers: {
        accept: "application/json",
        "x-comma-session-transport": "bearer",
        ...(body === undefined ? {} : { "content-type": "application/json" }),
        ...(this.#token ? { authorization: `Bearer ${this.#token}` } : {}),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      // The session goes only to the origin the extension was built for.
      redirect: "error",
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (response.status === 401) throw new Unauthorized();
    if (response.status < 200 || response.status >= 300)
      throw new ApiError(response.status);
    return response.json();
  }
}

/**
 * Statuses of a Task that is no longer under way: the `done`, `cancelled` and `archived` buckets of the Comma app's
 * task-status vocabulary (`clients/packages/i18n/src/task-status.ts`).
 */
const ENDED_TASK_STATUSES = new Set([
  "completed",
  "cancelled",
  "canceled",
  "failed",
  "error",
  "closed",
  "done",
  "success",
  "succeeded",
  "terminal",
  "archived",
]);

/** A Task that is still under way, for the menu bar's count. */
export function taskIsActive(task: Pick<ApiTask, "status">): boolean {
  return !ENDED_TASK_STATUSES.has(task.status.trim().toLowerCase());
}
