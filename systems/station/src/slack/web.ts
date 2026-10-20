// Slack's Web API over HTTP (chat/slack.rs `slack_api`, chat/slack_apps.rs `call`): one client for both, with one
// rule for 429 (wait what Slack says, up to five times). Where Slack is can be changed: tests point it at a stand-in
// ($STILLFAIL_SLACK_API, or the client's `base`).
type Json = any;

export const SLACK_API = "https://slack.com/api";

/// Where Slack's Web API is: $STILLFAIL_SLACK_API (or the old $EMBER_SLACK_API), else Slack itself.
export function apiBase(): string {
  return process.env.STILLFAIL_SLACK_API || process.env.EMBER_SLACK_API || SLACK_API;
}

/// Form fields, in order.
export type Params = [string, string][];

/// A file sent with a call (multipart).
export type FilePart = { bytes: Uint8Array; name: string; mime: string };

/// Slack said no to a call of its app API: its error code, and the details it gave (a manifest's problems, say).
import { wall } from "../ops/fibers.ts";
export class SlackApiError extends Error {
  readonly method: string;
  readonly code: string;
  readonly details: Json | null;
  constructor(method: string, code: string, details: Json | null) {
    super(`${method}: ${code}${details !== null ? ` ${JSON.stringify(details)}` : ""}`);
    this.method = method;
    this.code = code;
    this.details = details;
  }
}

/// A value as a form field: strings as they are, anything else as JSON (blocks, arrays), as Slack takes them.
export const field = (v: unknown): string => (typeof v === "string" ? v : JSON.stringify(v));

const RETRIES = 5;
/// Slack's rate limits are in its time: the machine's.
const sleep = wall.sleep;

export class SlackClient {
  readonly base: string;
  private timeoutMs: number;

  constructor(base: string = apiBase(), timeoutMs = 30_000) {
    this.base = base.replace(/\/+$/, "");
    this.timeoutMs = timeoutMs;
  }

  /// A call as Slack answers it (its status and JSON), after waiting out 429s.
  private async send(method: string, token: string | null, params: Params, file?: FilePart): Promise<[number, Json]> {
    for (let attempt = 0; ; attempt++) {
      let body: URLSearchParams | FormData;
      if (file) {
        const form = new FormData();
        for (const [k, v] of params) form.append(k, v);
        form.append("file", new Blob([file.bytes as Uint8Array<ArrayBuffer>], { type: file.mime }), file.name);
        body = form;
      } else body = new URLSearchParams(params);
      const headers: Record<string, string> = token !== null ? { authorization: `Bearer ${token}` } : {};
      const response = await fetch(`${this.base}/${method}`, { method: "POST", headers, body, signal: AbortSignal.timeout(this.timeoutMs) });
      if (response.status === 429 && attempt < RETRIES) {
        const said = response.headers.get("retry-after") ?? "";
        await response.body?.cancel();
        await sleep((/^\d+$/.test(said) ? Number(said) : 1) * 1000);
        continue;
      }
      return [response.status, await response.json()];
    }
  }

  /// A Web API call as the bot (or app-level token): its answer, or an error `slack <method>: <error>`.
  async api(method: string, params: Params, token: string): Promise<Json> {
    const [, body] = await this.send(method, token, params);
    if (body?.ok !== true) {
      const e = body?.error;
      const code = e === undefined ? "undefined" : typeof e === "string" ? e : JSON.stringify(e);
      throw new Error(`slack ${method}: ${code}`);
    }
    return body;
  }

  /// A call of the app API (manifests, configuration tokens, installs), with a token or none: its answer, or a
  /// SlackApiError.
  async app(method: string, token: string | null, params: Params, file?: FilePart): Promise<Json> {
    const [status, data] = await this.send(method, token, params, file);
    if (data?.ok !== true) {
      const e = data?.error;
      const code = typeof e === "string" ? e : e !== undefined && e !== null ? JSON.stringify(e) : `HTTP ${status}`;
      const details = data?.errors === undefined || data?.errors === null ? null : data.errors;
      throw new SlackApiError(method, code, details);
    }
    return data;
  }

  /// A shared file's bytes from Slack (its url_private), with the bot's token: only to Slack's own hosts (or the stand-in
  /// it is pointed at), never to an address elsewhere. Without files:read Slack answers its sign-in page instead.
  async download(url: string, name: string, token: string): Promise<Uint8Array> {
    let to: URL;
    try {
      to = new URL(url);
    } catch {
      throw new Error(`not an address: ${url}`);
    }
    const slack = to.protocol === "https:" && (to.hostname === "slack.com" || to.hostname.endsWith(".slack.com") || to.hostname.endsWith(".slack-edge.com"));
    if (!slack && to.origin !== new URL(this.base).origin) throw new Error(`not a Slack address: ${to.origin}`);
    const got = await fetch(to, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(120_000) });
    if (!got.ok) {
      await got.body?.cancel();
      throw new Error(`HTTP ${got.status}`);
    }
    const page = (got.headers.get("content-type") ?? "").startsWith("text/html") && (got.redirected || !/\.html?$/i.test(name));
    if (page) {
      await got.body?.cancel();
      throw new Error("Slack answered with its sign-in page: the app lacks files:read (turn on 读写文件 in its permissions)");
    }
    return new Uint8Array(await got.arrayBuffer());
  }

  /// A file's bytes to the address Slack gave for them (files.getUploadURLExternal).
  async upload(url: string, bytes: Uint8Array, name: string): Promise<void> {
    const sent = await fetch(url, { method: "POST", body: bytes as Uint8Array<ArrayBuffer>, signal: AbortSignal.timeout(300_000) });
    await sent.body?.cancel();
    if (!sent.ok) throw new Error(`slack upload of ${name}: HTTP ${sent.status}${sent.statusText ? ` ${sent.statusText}` : ""}`);
  }
}
