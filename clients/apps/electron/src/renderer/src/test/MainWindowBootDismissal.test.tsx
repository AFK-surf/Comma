import type { CoreClient } from "@comma/core-client";
import type { SessionLifecycleSnapshot } from "@comma/session-contract";
import { act, render, screen } from "@comma/test-utils/render";
import { afterEach, expect, it, vi } from "vitest";
import {
  CommaAuthGate,
  CommaSessionHostProvider,
  createCoreSessionHostController,
} from "@comma/app";
import { MainWindowBootDismissal } from "../MainWindowBootDismissal";
import { dismissMainWindowBoot, showMainWindowBoot } from "../mainWindowBoot";

afterEach(() => {
  vi.unstubAllGlobals();
  dismissMainWindowBoot();
});

it("keeps the main window boot until the core answers with session truth", async () => {
  vi.stubGlobal("commaNative", { self: { role: "main-window", windowId: "win_main" } });
  vi.stubGlobal("matchMedia", () => ({ matches: false }));
  showMainWindowBoot();
  let answer!: (snapshot: SessionLifecycleSnapshot) => void;
  const core = {
    call: async () => null,
    subscribe: (_topic: unknown, onValue: (value: unknown) => void) => {
      answer = (lifecycle) => onValue({ phase: "signed_out", lifecycle });
      return () => {};
    },
  } as unknown as CoreClient;
  const controller = createCoreSessionHostController({
    apiBaseUrl: "assets://.",
    core,
    host: "electron",
  });

  render(
    <CommaSessionHostProvider controller={controller}>
      <MainWindowBootDismissal />
      <CommaAuthGate signedOutFallback={<p>Signed out</p>}>
        <p>Product</p>
      </CommaAuthGate>
    </CommaSessionHostProvider>
  );

  expect(document.getElementById("comma-main-window-boot")).not.toBeNull();
  act(() =>
    answer({
      authority: { authorityInstanceId: "main-authority", kind: "electron_main" },
      cleanup: { revocation: "idle" },
      contractVersion: 1,
      generation: 0,
      phase: "signed_out",
      principal: null,
      reason: "no_session",
      revision: 1,
      session: null,
    })
  );
  expect(await screen.findByText("Signed out")).toBeVisible();
  expect(document.getElementById("comma-main-window-boot")).toBeNull();
  controller.dispose?.();
});
