import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { ReactNode } from "react";
import { useSubscriptionSignIn } from "../useSubscriptionSignIn";

vi.mock("@comma/native-bridge", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@comma/native-bridge")>()),
  getNativeBridge: () => ({ platform: "electron" }),
}));

describe("useSubscriptionSignIn on desktop", () => {
  it("waits on the core's loopback sign-in, naming the profile a re-authorization renews", async () => {
    const calls: [string, unknown][] = [];
    const profile = { id: "profile-codex", source: "codex" };
    const core = createScriptedCore({
      calls: (name, params) => {
        calls.push([name, params]);
        return profile;
      },
    });
    const completed = vi.fn();
    const { result } = renderHook(() => useSubscriptionSignIn("workspace", completed), {
      wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
    });
    await act(async () =>
      result.current.begin("codex", {
        device: true,
        reconnect: { account_id: "profile-codex", version: "v2" },
      })
    );
    await waitFor(() => expect(completed).toHaveBeenCalledWith(profile));
    expect(calls).toEqual([
      [
        "models.signIn.loopback",
        {
          workspace: "workspace",
          provider: "codex",
          account: "profile-codex",
          version: "v2",
        },
      ],
    ]);
  });
});
