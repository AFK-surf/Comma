import { describe, expect, it, vi } from "vitest";

import type { ElectronMainSessionService } from "../modules/session";
import {
  ACTIVITY_IDLE_LIMIT_SECONDS,
  startActivityReporter,
} from "../modules/session/activity-reporter";

function fakeSession(signedIn = true) {
  const credential = { signal: new AbortController().signal, token: "comma_sess_t" };
  const session = {
    acquireProductCredential: vi.fn(() => credential),
    reportUnauthorized: vi.fn(async () => undefined),
    state: () =>
      signedIn
        ? {
            authority: { authorityInstanceId: "a1" },
            generation: 1,
            phase: "signed_in",
            session: { audience: "https://api.example", sessionId: "s1" },
          }
        : { phase: "signed_out" },
  };
  return {
    credential,
    session: session as unknown as ElectronMainSessionService & typeof session,
  };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("activity reporter", () => {
  it("reports use only while the computer has recent input", async () => {
    let idle = 0;
    const fetcher = vi.fn(async () => new Response("{}", { status: 200 }));
    const { session } = fakeSession();
    const reporter = startActivityReporter({
      canShowHomeReplies: () => true,
      fetcher: fetcher as unknown as typeof fetch,
      intervalMs: 5,
      session,
      systemIdleSeconds: () => idle,
    });
    await settle();
    expect(fetcher).toHaveBeenCalled();
    const [url, init] = fetcher.mock.calls[0] as unknown as [URL, RequestInit];
    expect(url.href).toBe("https://api.example/v1/comma/auth/session/activity");
    expect((init.headers as Record<string, string>).authorization).toBe(
      "Bearer comma_sess_t"
    );

    idle = ACTIVITY_IDLE_LIMIT_SECONDS;
    await new Promise((resolve) => setTimeout(resolve, 10));
    fetcher.mockClear();
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(fetcher).not.toHaveBeenCalled();
    reporter.close();
  });

  it("sends nothing while Comma cannot show a Home reply", async () => {
    const fetcher = vi.fn(async () => new Response("{}", { status: 200 }));
    const { session } = fakeSession();
    startActivityReporter({
      canShowHomeReplies: () => false,
      fetcher: fetcher as unknown as typeof fetch,
      session,
      systemIdleSeconds: () => 0,
    }).close();
    await settle();
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("sends nothing while signed out and reports a rejected credential", async () => {
    const fetcher = vi.fn(async () => new Response("{}", { status: 401 }));
    const signedOut = fakeSession(false);
    startActivityReporter({
      canShowHomeReplies: () => true,
      fetcher: fetcher as unknown as typeof fetch,
      session: signedOut.session,
      systemIdleSeconds: () => 0,
    }).close();
    await settle();
    expect(fetcher).not.toHaveBeenCalled();

    const { credential, session } = fakeSession();
    startActivityReporter({
      canShowHomeReplies: () => true,
      fetcher: fetcher as unknown as typeof fetch,
      session,
      systemIdleSeconds: () => 0,
    }).close();
    await settle();
    await settle();
    expect(session.reportUnauthorized).toHaveBeenCalledWith(credential);
  });
});
