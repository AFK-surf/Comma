import {
  authorizationReturnCsp,
  type AuthorizationReturn,
} from "./authorization-return";
import { createServer, type Server } from "node:http";
import { subscriptionAuthorizationPage } from "./subscription-authorization-page";
import type { MainSessionBoundApi } from "./modules/session/main-session-transport";

export interface SubscriptionAuthorizationInput {
  requestId: string;
  workspaceId: string;
  provider: "codex" | "claude";
  accountId?: string | undefined;
  version?: string | undefined;
}
export type SubscriptionAuthorizationStatus = {
  status: "pending" | "complete" | "failed";
  error?: string | undefined;
};
interface Attempt {
  id: string;
  server: Server;
  timer: ReturnType<typeof setTimeout>;
  boundary: MainSessionBoundApi;
  result: SubscriptionAuthorizationStatus;
  settled: boolean;
  detachSession: () => void;
}

export class SubscriptionAuthorizationService {
  #attempt: Attempt | undefined;
  constructor(
    private readonly bindSession: () => MainSessionBoundApi & { signal?: AbortSignal },
    private readonly openExternal: (url: string) => Promise<void>,
    private readonly timeoutMs = 900_000,
    private readonly returnToApp?: AuthorizationReturn
  ) {}

  async start(
    input: SubscriptionAuthorizationInput
  ): Promise<SubscriptionAuthorizationStatus> {
    if (this.#attempt?.result.status === "pending")
      throw new Error("authorization_in_progress");
    this.dispose();
    const boundary = this.bindSession();
    const port = input.provider === "codex" ? 1455 : 54545;
    const path = input.provider === "codex" ? "/auth/callback" : "/callback";
    let expectedState = "";
    let backendId = "";
    const server = createServer((request, response) => {
      response.setHeader("Cache-Control", "no-store");
      response.setHeader("Content-Type", "text/html; charset=utf-8");
      response.setHeader("Content-Security-Policy", authorizationReturnCsp);
      let url: URL;
      try {
        if ((request.url?.length ?? 0) > 8192) throw new Error("invalid_callback");
        url = new URL(request.url ?? "/", `http://localhost:${port}`);
      } catch {
        response.writeHead(400).end(subscriptionAuthorizationPage("invalid"));
        return;
      }
      const host = request.headers.host;
      if (
        request.method !== "GET" ||
        url.pathname !== path ||
        (host !== `localhost:${port}` && host !== `127.0.0.1:${port}`)
      ) {
        response.writeHead(404).end(subscriptionAuthorizationPage("notFound"));
        return;
      }
      if (
        !expectedState ||
        url.searchParams.get("state") !== expectedState ||
        attempt.settled ||
        !boundary.isCurrent()
      ) {
        response.writeHead(400).end(subscriptionAuthorizationPage("invalid"));
        return;
      }
      if (!url.searchParams.get("code") || url.searchParams.has("error")) {
        response
          .writeHead(400)
          .end(
            subscriptionAuthorizationPage(
              "denied",
              "subscription",
              this.returnToApp?.url
            ),
            () => {
              this.returnToApp?.open();
              this.finish(attempt, { status: "failed", error: "authorization_denied" });
            }
          );
        return;
      }
      attempt.settled = true;
      this.returnToApp?.open();
      server.close();
      response.end(
        subscriptionAuthorizationPage("received", "subscription", this.returnToApp?.url)
      );
      void (async () => {
        try {
          boundary.assertCurrent();
          await boundary.api.completeSubscriptionOAuth(
            input.workspaceId,
            backendId,
            url.href
          );
          boundary.assertCurrent();
          this.finish(attempt, { status: "complete" });
        } catch {
          this.finish(attempt, { status: "failed", error: "authorization_failed" });
        }
      })();
    });
    const attempt: Attempt = {
      id: input.requestId,
      server,
      boundary,
      result: { status: "pending" },
      settled: false,
      detachSession: () => {},
      timer: setTimeout(
        () =>
          this.finish(attempt, { status: "failed", error: "authorization_expired" }),
        this.timeoutMs
      ),
    };
    attempt.timer.unref();
    this.#attempt = attempt;
    const expiredSession = () =>
      this.finish(attempt, { status: "failed", error: "authorization_expired" });
    boundary.signal?.addEventListener("abort", expiredSession, { once: true });
    attempt.detachSession = () =>
      boundary.signal?.removeEventListener("abort", expiredSession);
    if (boundary.signal?.aborted) {
      expiredSession();
      return attempt.result;
    }
    try {
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, "127.0.0.1", () => {
          server.off("error", reject);
          resolve();
        });
      });
      if (this.#attempt !== attempt || attempt.settled) {
        server.close();
        return { status: "failed" };
      }
      const result = await boundary.api.beginSubscriptionOAuth(input.workspaceId, {
        provider: input.provider,
        mode: "callback",
        ...(input.accountId && input.version
          ? { account_id: input.accountId, version: input.version }
          : {}),
      });
      boundary.assertCurrent();
      if (this.#attempt !== attempt || attempt.settled) return { status: "failed" };
      const authorizationUrl = new URL(result.url);
      const origin =
        input.provider === "codex" ? "https://auth.openai.com" : "https://claude.ai";
      if (
        authorizationUrl.origin !== origin ||
        authorizationUrl.searchParams.get("redirect_uri") !==
          `http://localhost:${port}${path}`
      ) {
        throw new Error("invalid_authorization_url");
      }
      expectedState = authorizationUrl.searchParams.get("state") ?? "";
      if (!expectedState) throw new Error("invalid_authorization_url");
      backendId = result.id;
      await this.openExternal(authorizationUrl.href);
      return attempt.result;
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      this.finish(attempt, {
        status: "failed",
        error:
          code === "EADDRINUSE" ? "authorization_port_in_use" : "authorization_failed",
      });
      return attempt.result;
    }
  }

  status({ requestId }: { requestId: string }): SubscriptionAuthorizationStatus {
    const attempt = this.#attempt;
    if (!attempt || attempt.id !== requestId)
      return { status: "failed", error: "authorization_unavailable" };
    if (!attempt.boundary.isCurrent())
      this.finish(attempt, { status: "failed", error: "authorization_expired" });
    return attempt.result;
  }

  cancel({ requestId }: { requestId: string }): { ok: true } {
    if (this.#attempt?.id === requestId) this.dispose();
    return { ok: true };
  }

  private finish(attempt: Attempt, result: SubscriptionAuthorizationStatus) {
    clearTimeout(attempt.timer);
    attempt.detachSession();
    attempt.settled = true;
    attempt.result = result;
    attempt.server.close();
    attempt.server.closeAllConnections();
  }

  dispose() {
    if (this.#attempt)
      this.finish(this.#attempt, {
        status: "failed",
        error: "authorization_cancelled",
      });
    this.#attempt = undefined;
  }
}
