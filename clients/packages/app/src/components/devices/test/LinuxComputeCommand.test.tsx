import { CoreProvider } from "@comma/core-client";
import { CommaI18nProvider } from "@comma/i18n/react";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { render, fireEvent, screen } from "@comma/test-utils/render";
import { flush } from "@comma/test-utils/fake-clock";
import { expect, it } from "vitest";
import { LinuxComputeCommand } from "../LinuxComputeCommand";

it("creates an installation only after the user chooses Linux and retries the same request", async () => {
  let attempts = 0;
  const core = createScriptedCore({
    calls: () => {
      attempts += 1;
      if (attempts === 1) throw new Error("temporary failure");
      return { command: "linux-install", expiresAt: "2026-10-23T10:00:00Z" };
    },
  });
  render(
    <CommaI18nProvider locale="en">
      <CoreProvider client={core.client}>
        <LinuxComputeCommand workspace="wsp" />
      </CoreProvider>
    </CommaI18nProvider>
  );
  await flush();
  expect(core.sent).toHaveLength(0);
  fireEvent.click(
    screen.getByRole("button", { name: "Install on a Linux arm64 server" })
  );
  await flush();
  expect(screen.getByRole("alert")).toBeTruthy();
  fireEvent.click(
    screen.getByRole("button", { name: "Install on a Linux arm64 server" })
  );
  await flush();
  expect(core.sent).toHaveLength(2);
  expect(core.sent[1]).toEqual(core.sent[0]);
  expect(core.sent[0]).toEqual([
    "computeNode.installCommand",
    { workspaceId: "wsp", requestId: expect.any(String) },
  ]);
  expect(screen.getByText("linux-install")).toBeTruthy();
});
