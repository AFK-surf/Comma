import type { ProductInboxListResult } from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import { vi } from "vitest";
import { createCommaApi, type CommaApiSessionTransport } from "../api";
import type { CommaAuthContextValue } from "../components/auth-context";
import {
  createElectronProductInboxProjectionController,
  type ProductInboxProjectionBridge,
  type ProductInboxProjectionEnvelope,
  type ProductInboxRefresh,
} from "../product-inbox";

export const testProductLease: SessionProductLease = {
  audience: "https://api.comma.test",
  authorityInstanceId: "test-electron-main",
  generation: 1,
  sessionId: "11111111-1111-4111-8111-111111111111",
};

export function createTestCommaAuthValue(): CommaAuthContextValue {
  const controller = new AbortController();
  const sessionTransport: CommaApiSessionTransport = {
    credentials: "include",
    signal: controller.signal,
    applyHeaders: () => undefined,
    reportSessionRejection: () => undefined,
  };
  return {
    api: createCommaApi({ baseUrl: "", sessionTransport, token: "" }),
    apiBaseUrl: "",
    authenticated: true,
    productLease: testProductLease,
    sessionSignal: controller.signal,
    sessionTransport,
    signOut: vi.fn(),
    userEmail: "test@example.com",
  };
}

export function createProductInboxProjectionHarness({
  initial,
  refresh,
  retain,
}: {
  initial: ProductInboxListResult;
  refresh?: (
    input: ProductInboxRefresh & { session: SessionProductLease }
  ) => ProductInboxListResult | Promise<ProductInboxListResult>;
  retain?: (input: {
    session: SessionProductLease;
  }) => ProductInboxListResult | Promise<ProductInboxListResult>;
}) {
  let current = envelope(initial);
  const listeners = new Set<(value: ProductInboxProjectionEnvelope) => void>();
  const get = vi.fn(async () => current);
  const state = Object.assign(get, {
    get,
    subscribe(
      listener: (value: ProductInboxProjectionEnvelope) => void,
      _input: { session: SessionProductLease }
    ) {
      listeners.add(listener);
      queueMicrotask(() => listener(current));
      return () => {
        listeners.delete(listener);
      };
    },
  });
  const retainBridge = vi.fn(async (input: { session: SessionProductLease }) => {
    const result = retain ? await retain(input) : current.snapshot;
    current = envelope(result, input.session);
    return current;
  });
  const release = vi.fn(async () => true);
  const refreshBridge = vi.fn(
    async (
      input: ProductInboxRefresh & { session: SessionProductLease }
    ): Promise<ProductInboxProjectionEnvelope> => {
      const result = refresh ? await refresh(input) : current.snapshot;
      current = envelope(result, input.session);
      for (const listener of listeners) {
        listener(current);
      }
      return current;
    }
  );
  const bridge = {
    refresh: refreshBridge,
    release,
    retain: retainBridge,
    state,
  } satisfies ProductInboxProjectionBridge;

  return {
    controller: createElectronProductInboxProjectionController({ bridge }),
    emit(result: ProductInboxListResult, session = current.session) {
      current = envelope(result, session);
      for (const listener of listeners) {
        listener(current);
      }
    },
    refresh: refreshBridge,
    release,
    retain: retainBridge,
  };
}

function envelope(
  snapshot: ProductInboxListResult,
  session = testProductLease
): ProductInboxProjectionEnvelope {
  return { session, snapshot };
}
