// The web page on the session the client core runs: what AuthGate and the login screen show for what the core's
// `session` topic says, and which `session.*` call each thing a person does makes. The core is scripted.
import userEvent from "@testing-library/user-event";
import type {
  SessionLifecycleSnapshot,
  SignedInSessionSnapshot,
  SignedOutSessionSnapshot,
} from "@comma/session-contract";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { toast } from "@comma/ui/components/toast";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CommaAuthGate, useCommaAuth } from "../../components/AuthGate";
import { CommaSessionHostProvider } from "../react";
import { createCoreSessionHostController } from "../core-session-host-controller";

const attemptRef = {
  attemptId: "attempt-from-another-tab",
  expected: {
    authorityInstanceId: "core-authority",
    expectedSessionId: null,
    generation: 0,
  },
};

function signedOut(): SignedOutSessionSnapshot {
  return {
    authority: { authorityInstanceId: "core-authority", kind: "web_cookie" },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation: 0,
    phase: "signed_out",
    principal: null,
    reason: "no_session",
    revision: 1,
    session: null,
  };
}

function signedIn(generation = 1): SignedInSessionSnapshot {
  return {
    authority: { authorityInstanceId: "core-authority", kind: "web_cookie" },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation,
    phase: "signed_in",
    principal: { email: "person@example.com", userId: "user-1" },
    revision: generation + 1,
    session: {
      audience: "https://api.example",
      expiresAtEpochSeconds: 2_000_000_000,
      sessionId: "11111111-1111-4111-8111-111111111111",
    },
  };
}

/** The `session` topic's value for a lifecycle snapshot. */
function topic(
  lifecycle: SessionLifecycleSnapshot,
  extra: Record<string, unknown> = {}
) {
  const account =
    lifecycle.phase === "signed_in"
      ? {
          phase: "signed_in",
          userId: lifecycle.principal.userId,
          audience: lifecycle.session.audience,
          sessionId: lifecycle.session.sessionId,
        }
      : { phase: lifecycle.phase === "signed_out" ? "signed_out" : "unknown" };
  return { ...account, lifecycle, attempt: null, guestImports: 0, ...extra };
}

function renderPage(initial: unknown) {
  const calls: [string, unknown][] = [];
  const scripted = createScriptedCore({
    owns: (name) => name === "session" || name.startsWith("session."),
    values: (t) => (t.topic === "session" ? initial : undefined),
    calls(name, params) {
      calls.push([name, params]);
      // The Google button is unavailable here: no attempt is prepared.
      if (name === "session.google.attempt")
        return {
          ok: false,
          error: {
            code: "provider_unavailable",
            operation: "sign_in_with_google",
            recovery: "retry_operation",
            retryable: true,
          },
        };
      if (name === "session.email.verify") return { ok: true, value: signedIn() };
      if (name === "session.signOut") return { ok: true, value: signedOut() };
      return null;
    },
  });
  const controller = createCoreSessionHostController({
    apiBaseUrl: "https://api.example",
    core: scripted.client,
  });
  const view = render(
    scripted.wrap(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <Product />
        </CommaAuthGate>
      </CommaSessionHostProvider>
    )
  );
  return {
    ...view,
    calls,
    controller,
    /** The core sends a new `session` value. */
    send: (value: unknown) => act(() => scripted.emit("session", value)),
    named: (name: string) => calls.filter(([n]) => n === name).map(([, p]) => p),
  };
}

let shownSignal: AbortSignal | undefined;

function Product() {
  const auth = useCommaAuth();
  shownSignal = auth.sessionSignal;
  return (
    <>
      <output aria-label="account">{auth.userEmail}</output>
      <button
        type="button"
        onClick={() => auth.sessionTransport.reportSessionRejection(401)}
      >
        Refused
      </button>
      <button type="button" onClick={auth.signOut}>
        Sign out
      </button>
    </>
  );
}

describe("the web page on the core's session", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    shownSignal = undefined;
  });

  it("shows nothing until the core says what the session is, then the login screen", async () => {
    const page = renderPage(undefined);
    await waitFor(() => expect(page.calls).toEqual([]));
    expect(screen.queryByRole("heading")).toBeNull();
    page.send(topic(signedOut()));
    expect(
      await screen.findByRole("heading", { name: "Sign in to Comma" })
    ).toBeVisible();
  });

  it("continues the sign-in another tab started, with its attempt, and leaves it once it is gone", async () => {
    const page = renderPage(
      topic({ ...signedOut(), phase: "authenticating" } as SessionLifecycleSnapshot, {
        attempt: {
          ref: attemptRef,
          method: "email",
          challenge: {
            challengeId: "challenge-1",
            purpose: "email_login",
            email: "person@example.com",
          },
        },
      })
    );
    expect(
      await screen.findByRole("heading", { name: "Check your email" })
    ).toBeVisible();
    expect(screen.getByText("person@example.com")).toBeVisible();
    // This tab does not start a Google sign-in of its own, which would replace the other tab's.
    expect(page.named("session.google.attempt")).toEqual([]);

    await userEvent.type(
      screen.getByRole("textbox", { name: /verification code/i }),
      "123456"
    );
    await userEvent.click(screen.getByRole("button", { name: "Verify code" }));
    await waitFor(() =>
      expect(page.named("session.email.verify")).toEqual([
        { attempt: attemptRef, challengeId: "challenge-1", code: "123456" },
      ])
    );

    // The other tab gave it up: this one is back at the start.
    page.send(topic(signedOut()));
    expect(
      await screen.findByRole("heading", { name: "Sign in to Comma" })
    ).toBeVisible();
    expect(screen.queryByRole("textbox", { name: /verification code/i })).toBeNull();
  });

  it("names the session in the page's own requests, and tells the core when one is refused", async () => {
    const page = renderPage(topic(signedIn()));
    expect(await screen.findByLabelText("account")).toHaveTextContent(
      "person@example.com"
    );
    await userEvent.click(screen.getByRole("button", { name: "Refused" }));
    await waitFor(() =>
      expect(page.named("session.rejected")).toEqual([
        {
          sessionId: "11111111-1111-4111-8111-111111111111",
          generation: 1,
          status: 401,
        },
      ])
    );

    // The core gave a new lease (another generation): what the page started with the last one stops.
    const first = shownSignal;
    page.send(topic(signedIn(2)));
    await waitFor(() => expect(shownSignal).not.toBe(first));
    expect(first?.aborted).toBe(true);
    expect(shownSignal?.aborted).toBe(false);

    await userEvent.click(screen.getByRole("button", { name: "Sign out" }));
    await waitFor(() =>
      expect(page.named("session.signOut")).toEqual([
        {
          expected: {
            authorityInstanceId: "core-authority",
            expectedAudience: "https://api.example",
            expectedSessionId: "11111111-1111-4111-8111-111111111111",
            generation: 2,
          },
        },
      ])
    );
  });

  it("keeps the product shown while a core started again finds the session out", async () => {
    const page = renderPage(topic(signedIn()));
    expect(await screen.findByLabelText("account")).toBeVisible();
    // The tab running the core closed; another tab's worker started a new core, which knows nothing yet.
    page.send(
      topic({
        authority: { authorityInstanceId: "next-core", kind: "web_cookie" },
        cleanup: { revocation: "idle" },
        contractVersion: 1,
        generation: 0,
        phase: "initializing",
        principal: null,
        revision: 0,
        session: null,
      })
    );
    expect(screen.getByLabelText("account")).toBeVisible();
    page.send(topic(signedOut()));
    expect(
      await screen.findByRole("heading", { name: "Sign in to Comma" })
    ).toBeVisible();
  });

  it("tells of a guest chat the core imported while the page was open, not of earlier ones", async () => {
    const success = vi.spyOn(toast, "success");
    const page = renderPage(topic(signedIn(), { guestImports: 1 }));
    expect(await screen.findByLabelText("account")).toBeVisible();
    expect(success).not.toHaveBeenCalled();
    page.send(topic(signedIn(), { guestImports: 2 }));
    await waitFor(() =>
      expect(success).toHaveBeenCalledWith("Imported your guest chat.")
    );
    expect(success).toHaveBeenCalledOnce();
  });
});
