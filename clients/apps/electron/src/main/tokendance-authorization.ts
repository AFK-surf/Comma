import {
  authorizationReturnCsp,
  type AuthorizationReturn,
} from "./authorization-return";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import {
  calculatePKCECodeChallenge,
  randomPKCECodeVerifier,
  randomState,
} from "openid-client";
import { z } from "zod";
import type { MainSessionBoundApi } from "./modules/session/main-session-transport";
import type {
  TokenDanceAuthorizationSaveInput,
  TokenDanceAuthorizationStatus,
} from "@comma/native-bridge";
import { subscriptionAuthorizationPage } from "./subscription-authorization-page";
import { getCommaReleaseConfig, type CommaReleaseConfig } from "../release-config";

const origin = "https://tokendance.space";
const baseUrl = `${origin}/gateway/v1`;
const keyResponse = z.object({ key: z.string().min(1).max(8192) });
type Status = TokenDanceAuthorizationStatus;
type Attempt = {
  id: string;
  workspaceId: string;
  boundary: MainSessionBoundApi;
  server: Server;
  abort: AbortController;
  timer: ReturnType<typeof setTimeout>;
  detachSession: () => void;
  callbackReceived: boolean;
  saving: boolean;
  key?: string | undefined;
  result: Status;
};

/** One authorization per app. The Key never crosses the Main/renderer boundary. */
export class TokenDanceAuthorizationService {
  #attempt: Attempt | undefined;

  constructor(
    private readonly bindSession: () => MainSessionBoundApi & { signal?: AbortSignal },
    private readonly openExternal: (url: string) => Promise<void>,
    private readonly fetchImpl: typeof fetch = fetch,
    private readonly timeoutMs = 600_000,
    private readonly returnToApp?: AuthorizationReturn,
    private readonly appIdentity: Pick<
      CommaReleaseConfig,
      "urlScheme" | "productName"
    > = getCommaReleaseConfig()
  ) {}

  async start(input: { requestId: string; workspaceId: string }): Promise<Status> {
    if (this.#attempt?.saving || this.#attempt?.result.status === "pending")
      return { status: "failed", error: "authorization_in_progress" };
    this.dispose();
    const boundary = this.bindSession();
    // TokenDance's documented exchange is not a standard OAuth token response,
    // so use openid-client's PKCE primitives and isolate the custom exchange here.
    // Main alone holds the expected verifier/state. S256 prevents an intercepted
    // callback code from yielding a Key. A mismatched callback does not exchange.
    const verifier = randomPKCECodeVerifier();
    const state = randomState();
    let callbackUrl: URL;
    const server = createServer((request, response) => {
      response.setHeader("Cache-Control", "no-store");
      response.setHeader("Content-Type", "text/html; charset=utf-8");
      response.setHeader("Content-Security-Policy", authorizationReturnCsp);
      let url: URL;
      try {
        if (!callbackUrl || (request.url?.length ?? 0) > 8192) throw new Error();
        url = new URL(request.url ?? "/", callbackUrl);
      } catch {
        response.writeHead(400).end(subscriptionAuthorizationPage("invalid", "byok"));
        return;
      }
      if (
        request.method !== "GET" ||
        request.headers.host !== callbackUrl.host ||
        url.pathname !== callbackUrl.pathname
      ) {
        response.writeHead(404).end(subscriptionAuthorizationPage("notFound", "byok"));
        return;
      }
      if (
        !this.current(attempt) ||
        attempt.callbackReceived ||
        url.searchParams.getAll("state").length !== 1 ||
        url.searchParams.get("state") !== state
      ) {
        response.writeHead(400).end(subscriptionAuthorizationPage("invalid", "byok"));
        return;
      }
      const code = url.searchParams.get("code");
      if (
        !code ||
        url.searchParams.getAll("code").length !== 1 ||
        url.searchParams.has("error")
      ) {
        response
          .writeHead(400)
          .end(subscriptionAuthorizationPage("denied", "byok", this.returnToApp?.url));
        this.returnToApp?.open();
        this.fail(attempt, "authorization_denied");
        return;
      }
      attempt.callbackReceived = true;
      this.returnToApp?.open();
      response.end(
        subscriptionAuthorizationPage("received", "byok", this.returnToApp?.url)
      );
      server.close();
      void this.exchange(attempt, code, verifier);
    });
    const abort = new AbortController();
    const attempt: Attempt = {
      id: input.requestId,
      workspaceId: input.workspaceId,
      boundary,
      server,
      abort,
      timer: setTimeout(
        () => this.fail(attempt, "authorization_expired"),
        this.timeoutMs
      ),
      detachSession: () => {},
      callbackReceived: false,
      saving: false,
      result: { status: "pending" },
    };
    attempt.timer.unref();
    this.#attempt = attempt;
    const expired = () => this.fail(attempt, "authorization_expired");
    boundary.signal?.addEventListener("abort", expired, { once: true });
    attempt.detachSession = () =>
      boundary.signal?.removeEventListener("abort", expired);
    if (boundary.signal?.aborted) {
      expired();
      return attempt.result;
    }
    try {
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", () => {
          server.off("error", reject);
          resolve();
        });
      });
      if (!this.current(attempt)) {
        server.close();
        server.closeAllConnections();
        return attempt.result;
      }
      callbackUrl = new URL(
        `http://127.0.0.1:${(server.address() as AddressInfo).port}/callback`
      );
      callbackUrl.searchParams.set("state", state);
      const authorization = new URL(`${origin}/auth`);
      authorization.searchParams.set("callback_url", callbackUrl.href);
      authorization.searchParams.set(
        "code_challenge",
        await calculatePKCECodeChallenge(verifier)
      );
      authorization.searchParams.set("code_challenge_method", "S256");
      authorization.searchParams.set("app_url", `app://${this.appIdentity.urlScheme}`);
      authorization.searchParams.set("key_name", this.appIdentity.productName);
      if (!this.current(attempt)) return attempt.result;
      await this.openExternal(authorization.href);
    } catch {
      this.fail(attempt, "authorization_failed");
    }
    return attempt.result;
  }

  private async exchange(attempt: Attempt, code: string, verifier: string) {
    try {
      const response = await this.fetchImpl(`${origin}/portal/api/v1/auth/keys`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          code,
          code_verifier: verifier,
          code_challenge_method: "S256",
        }),
        credentials: "omit",
        redirect: "error",
        signal: AbortSignal.any([attempt.abort.signal, AbortSignal.timeout(15_000)]),
      });
      if (!response.ok) throw new Error();
      const key = keyResponse.parse(await boundedKeyResponse(response)).key;
      if (!this.current(attempt)) return;
      attempt.key = key;
      const models = await attempt.boundary.api.discoverModels(
        attempt.workspaceId,
        {
          base_url: baseUrl,
          api_key: key,
          protocol: "responses",
        },
        { signal: attempt.abort.signal }
      );
      if (!this.current(attempt)) return;
      attempt.result = {
        status: "complete",
        models: { ...models, protocol: "responses" },
      };
      // Give the user a full selection budget after the browser authorization.
      clearTimeout(attempt.timer);
      attempt.timer = setTimeout(
        () => this.fail(attempt, "authorization_expired"),
        this.timeoutMs
      );
      attempt.timer.unref();
    } catch {
      this.fail(attempt, "authorization_failed");
    }
  }

  status({ requestId }: { requestId: string }): Status {
    const attempt = this.#attempt;
    if (!attempt || attempt.id !== requestId)
      return { status: "failed", error: "authorization_unavailable" };
    if (!attempt.boundary.isCurrent()) this.fail(attempt, "authorization_expired");
    return attempt.result;
  }

  async save(input: TokenDanceAuthorizationSaveInput): Promise<{ ok: boolean }> {
    const attempt = this.#attempt;
    if (
      !attempt ||
      attempt.id !== input.requestId ||
      !this.current(attempt) ||
      !attempt.key ||
      attempt.result.status !== "complete" ||
      attempt.saving
    )
      throw new Error("authorization_unavailable");
    const model = attempt.result.models?.data.find((entry) => entry.id === input.model);
    if (!model) throw new Error("invalid_model_configuration");
    attempt.saving = true;
    try {
      attempt.boundary.assertCurrent();
      await attempt.boundary.api.createModelTemplate(attempt.workspaceId, {
        name: input.name,
        model: model.id,
        model_display_name: model.name,
        model_vendor: model.vendor ?? null,
        supports_images: model.supports_images,
        provider: "openai",
        protocol: "responses",
        base_url: baseUrl,
        api_key: attempt.key,
        max_tokens: input.maxTokens,
        context_tokens: input.contextTokens,
      });
      attempt.boundary.assertCurrent();
      if (this.#attempt === attempt) this.dispose();
      return { ok: true };
    } catch {
      throw new Error("model_save_failed");
    } finally {
      attempt.saving = false;
    }
  }

  cancel({ requestId }: { requestId: string }): { ok: true } {
    if (this.#attempt?.id === requestId) this.dispose();
    return { ok: true };
  }

  private current(attempt: Attempt): boolean {
    return (
      this.#attempt === attempt &&
      !attempt.abort.signal.aborted &&
      attempt.boundary.isCurrent()
    );
  }

  private fail(attempt: Attempt, error: string) {
    clearTimeout(attempt.timer);
    attempt.detachSession();
    attempt.key = undefined;
    attempt.result = { status: "failed", error };
    attempt.abort.abort();
    attempt.server.close();
    attempt.server.closeAllConnections();
  }

  dispose() {
    if (this.#attempt) this.fail(this.#attempt, "authorization_cancelled");
    this.#attempt = undefined;
  }
}

async function boundedKeyResponse(response: Response): Promise<unknown> {
  const reader = response.body?.getReader();
  if (!reader) throw new Error("authorization_failed");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      size += chunk.value.byteLength;
      if (size > 16_384) throw new Error("authorization_failed");
      chunks.push(chunk.value);
    }
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } finally {
    await reader.cancel();
  }
}
