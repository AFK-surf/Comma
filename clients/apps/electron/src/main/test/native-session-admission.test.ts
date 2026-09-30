import { sessionProductLease, type SessionProductLease } from "@comma/session-contract";
import type { NativeCommandContract } from "@comma/native-bridge";
import { z } from "zod";
import { describe, expect, it, vi } from "vitest";
import { NativeSessionAdmissionError } from "../modules/ipc";
import {
  getCurrentNativeSessionAdmission,
  MainNativeSessionAdmissionGuard,
  MainProductCredentialAuthority,
} from "../modules/session";

const audience = "https://api.comma.example";
const requiredContract = {
  channel: "comma:test:required",
  input: z.strictObject({
    session: z.object({
      audience: z.string(),
      authorityInstanceId: z.string(),
      generation: z.number(),
      sessionId: z.string(),
    }),
  }),
  output: z.string(),
  sessionAdmission: "required",
} satisfies NativeCommandContract<{ session: SessionProductLease }, string>;

describe("MainNativeSessionAdmissionGuard", () => {
  it("rejects missing or stale lease input before the handler", async () => {
    const { authority, guard, lease } = createGuard();
    const handler = vi.fn(() => "unreachable");

    let error: unknown;
    try {
      guard.run({
        contract: requiredContract,
        handler,
        input: {
          session: {
            ...lease,
            generation: lease.generation + 1,
          },
        },
      });
    } catch (caught) {
      error = caught;
    }
    expect(error).toMatchObject({
      admission: {
        code: "session_product_lease_unavailable",
        recovery: {
          authorityInstanceId: "authority-1",
          generation: authority.getSnapshot().generation,
        },
      },
    });
    expect(handler).not.toHaveBeenCalled();
  });

  it("exposes the Main-only credential only inside an exact admitted handler", async () => {
    const { guard, lease } = createGuard();

    await expect(
      guard.run({
        contract: requiredContract,
        handler: () => {
          const admission = getCurrentNativeSessionAdmission();
          expect(admission.session).toEqual(lease);
          expect(admission.credential).toMatchObject({
            ...lease,
            token: "main_secret",
          });
          expect(admission.principalUserId).toBe("user-1");
          return "ok";
        },
        input: { session: lease },
      })
    ).resolves.toBe("ok");
    expect(() => getCurrentNativeSessionAdmission()).toThrow(
      "No native Session admission context"
    );
  });

  it("settles again before a delayed result crosses IPC", async () => {
    const { authority, guard, lease } = createGuard();
    const delayed = deferred<string>();
    const result = guard.run({
      contract: requiredContract,
      handler: () => delayed.promise,
      input: { session: lease },
    });

    authority.beginInvalidation({
      authorityInstanceId: lease.authorityInstanceId,
      expectedAudience: lease.audience,
      expectedSessionId: lease.sessionId,
      generation: lease.generation,
    });
    delayed.resolve("stale");

    await expect(result).rejects.toBeInstanceOf(NativeSessionAdmissionError);
  });

  it("fences Main-owned meeting work when the account changes during a request", async () => {
    const { authority, guard, lease } = createGuard();
    const delayed = deferred<string>();
    const result = guard.runOwned(() => {
      expect(getCurrentNativeSessionAdmission().principalUserId).toBe("user-1");
      return delayed.promise;
    });
    authority.beginInvalidation({
      authorityInstanceId: lease.authorityInstanceId,
      expectedAudience: lease.audience,
      expectedSessionId: lease.sessionId,
      generation: lease.generation,
    });
    delayed.resolve("stale");
    await expect(result).rejects.toBeInstanceOf(NativeSessionAdmissionError);
  });

  it("does not require a product lease for lifecycle commands", async () => {
    const { guard } = createGuard();
    const lifecycleContract = {
      channel: "comma:test:lifecycle",
      input: z.void(),
      output: z.string(),
      sessionAdmission: "lifecycle",
    } satisfies NativeCommandContract<void, string>;

    expect(
      await guard.run({
        contract: lifecycleContract,
        handler: () => "ok",
        input: undefined,
      })
    ).toBe("ok");
  });
});

function createGuard() {
  const authority = new MainProductCredentialAuthority({
    authorityInstanceId: "authority-1",
    trustedAudience: audience,
  });
  const snapshot = authority.acceptVerifiedCredential({
    audience,
    email: "peng@example.com",
    expiresAtEpochSeconds: 1_900_000_000,
    sessionId: "session-1",
    token: "main_secret",
    userId: "user-1",
  });
  const lease = sessionProductLease(snapshot);
  if (!lease) throw new Error("Expected signed-in lease.");
  return {
    authority,
    guard: new MainNativeSessionAdmissionGuard(authority),
    lease,
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}
