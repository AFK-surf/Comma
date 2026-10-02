import { act, renderHook } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { ReactNode } from "react";
import type { CommaApiClient } from "../../../api";
import { CommaAuthContext, type CommaAuthContextValue } from "../../auth-context";
import { useSubscriptionSignIn } from "../useSubscriptionSignIn";

const start = vi.fn(async () => ({ status: "pending" as const }));
vi.mock("@comma/native-bridge", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@comma/native-bridge")>()),
  getNativeBridge: () => ({
    platform: "electron",
    subscriptionAuthorization: {
      start,
      status: vi.fn(async () => ({ status: "pending" })),
      cancel: vi.fn(async () => ({ ok: true })),
    },
  }),
}));

describe("useSubscriptionSignIn on desktop", () => {
  it("names the profile a re-authorization renews", async () => {
    const lease = "lease" as unknown as CommaAuthContextValue["productLease"];
    const wrapper = ({ children }: { children: ReactNode }) => (
      <CommaAuthContext.Provider
        value={{ productLease: lease } as unknown as CommaAuthContextValue}
      >
        {children}
      </CommaAuthContext.Provider>
    );
    const { result } = renderHook(
      () => useSubscriptionSignIn({} as CommaApiClient, "workspace", () => undefined),
      { wrapper }
    );
    await act(async () =>
      result.current.begin("codex", { account_id: "profile-codex", version: "v2" })
    );
    expect(start).toHaveBeenCalledWith(
      expect.objectContaining({
        workspaceId: "workspace",
        provider: "codex",
        accountId: "profile-codex",
        version: "v2",
      })
    );
  });
});
