import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { expect } from "../../../e2e/helpers/native-expect";
import { closeElectronTestApp } from "./close-electron-test-app";
import { _electron as electron, test, type Locator, type Page } from "@playwright/test";
import {
  chatAttachmentUploadMaxBytes,
  type ChatRuntimeSnapshot,
} from "@comma/chat-contract";
import type {
  SessionAbsenceExpectation,
  SessionAuthAttemptRef,
  SessionLifecycleSnapshot,
  SessionProductLease,
} from "@comma/session-contract";
import { Buffer } from "node:buffer";
import {
  access,
  chmod,
  mkdtemp,
  readdir as readDirectory,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { SessionBridge } from "@comma/native-bridge";
import { build } from "vite";
import { getCommaReleaseConfig } from "../src/release-config";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { findElectronWindowByRole } from "../src/test-support/electron-window";
import {
  runtimeAccountA,
  runtimeAccountB,
  startChatRuntimeStub,
  type LateResolutionOutcome,
} from "./chat-runtime-stub";

const clientsRoot = resolve(process.cwd());
const electronAppDir = resolve(clientsRoot, "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const rendererOutDir = resolve(electronAppDir, ".vite/renderer/main_window");
const fixtureRoot = resolve(electronAppDir, "e2e/fixtures/chat-runtime");
const fixtureUrl = "assets://./chat-runtime-fixture.html";
const delayedRetainFixtureUrl = `${fixtureUrl}?defer-first-retain=1`;
const delayedIntakeAckFixtureUrl = `${fixtureUrl}?defer-first-intake-ack=1`;
const stubbedPickFixtureUrl = `${fixtureUrl}?stub-pick-attachments=1`;
const electronProductName = getCommaReleaseConfig().productName;
const onePixelPng = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64"
);
const highResolutionPreviewDimensions = { height: 1_108, width: 1_952 } as const;
const highResolutionPreviewFixture = resolve(
  clientsRoot,
  "packages/ui/src/components/chat-panel/assets/generated-image-preview.png"
);

type CommaSessionState = SessionLifecycleSnapshot & {
  apiBaseUrl: string | undefined;
  email: string | undefined;
  revocationPending: boolean;
  signedIn: boolean;
  userId: string | undefined;
};

type RealChatStreamProbe = {
  activity: HTMLElement | undefined;
  activityRoute: HTMLElement | undefined;
  activitySlot: HTMLElement | undefined;
  activityThread: HTMLElement | undefined;
  activityTurn: HTMLElement | undefined;
  activityTurnKey: string | undefined;
  activityCollapsedSeen: boolean;
  activityCompleteAtFirstDraftCount: number;
  activityCapturedAt: number | undefined;
  activityCompleteSeen: boolean;
  activityDisconnectedAt: number | undefined;
  activityDisconnectedSamples: number;
  activityEmptyReadableSamples: number;
  activityThinkingSeen: boolean;
  activityTransparentSamples: number;
  activityTypingSeen: boolean;
  activityZeroAreaSamples: number;
  article: HTMLElement | undefined;
  articleDisconnectedSamples: number;
  canonicalAt: number | undefined;
  canonicalArticle: HTMLElement | undefined;
  canonicalSeen: boolean;
  commitToNextPaintSamples: number;
  draftMutationCount: number;
  draftNonPrefixSamples: number;
  draftStrictGrowthCount: number;
  draftTextRegressionSamples: number;
  emptyReplySamples: number;
  existingActivities: Set<Element>;
  existingCanonicalMessages: Set<Element>;
  existingFailedRows: Set<Element>;
  firstDraftAt: number | undefined;
  frameSamples: number;
  generationFailed: boolean;
  lastDraftAt: number | undefined;
  lastProjectedDraftText: string;
  lastRenderedDraftText: string;
  longTaskCount: number;
  longTaskObserver: PerformanceObserver | undefined;
  longTaskObserverSupported: boolean;
  markdown: HTMLElement | undefined;
  markdownTransparentSamples: number;
  maxCommitToNextPaintMs: number;
  maxDraftGapMs: number;
  maxLongTaskDurationMs: number;
  mutationObserver: MutationObserver;
  paintRafId: number | undefined;
  rafId: number;
  projectionUnsubscribe: (() => void) | undefined;
  running: boolean;
  sample: () => void;
  startedAt: number;
  stop: () => void;
  transparentReplySamples: number;
  zeroAreaReplySamples: number;
};

test.describe.configure({ timeout: 60_000 });

test("a failed startup session probe recovers the product without a retry click", async () => {
  const stub = await startChatRuntimeStub({ sessionFailureCount: 2 });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });
  try {
    const window = await mainProductWindow(launched.app);
    await expectSignedInShellAs(window, runtimeAccountB.email);
    const probes = stub.requests.filter(
      (request) => request.path === "/v1/comma/auth/session"
    );
    expect(probes.length).toBeGreaterThanOrEqual(3);
    expect(probes.every((request) => request.token === runtimeAccountB.token)).toBe(
      true
    );
  } finally {
    await launched.app.close().catch(() => {});
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("persistent session probe failure stops recovery without exposing product data", async () => {
  const stub = await startChatRuntimeStub({ sessionFailureCount: Infinity });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });
  try {
    const window = await mainProductWindow(launched.app);
    // Reload with a controlled renderer clock before recovery schedules its
    // backoff. Main and the HTTP stub remain real; only the timer waits advance.
    await window.clock.install();
    const probesBeforeReload = stub.requests.length;
    await window.reload();
    await expect(
      window.getByRole("status", { name: "Connecting to Comma…" })
    ).toBeVisible();
    await expect
      .poll(async () => {
        await window.clock.fastForward(30_000);
        return window.getByText("Comma is temporarily unavailable").isVisible();
      })
      .toBe(true);
    expect(await sessionState(window)).toMatchObject({
      phase: "indeterminate",
      signedIn: false,
    });
    expect(
      stub.requests.every((request) => request.path === "/v1/comma/auth/session")
    ).toBe(true);
    // Five attempts for each of the two renderer gates after the reload.
    const recoveryProbes = stub.requests.length - probesBeforeReload;
    expect(recoveryProbes).toBeGreaterThanOrEqual(5);
    expect(recoveryProbes).toBeLessThanOrEqual(10);
  } finally {
    await launched.app.close().catch(() => {});
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("a click-time send intent cannot consume the successor draft after an attachment wait", async () => {
  await ensureChatRuntimeFixtureBuilt();
  const stub = await startChatRuntimeStub();
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    rendererUrl: fixtureUrl,
    token: runtimeAccountB.token,
  });

  try {
    const appWindow = await findElectronWindowByNativeRole(launched.app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await expect(
      appWindow.getByRole("heading", { name: /ownership fixture/i })
    ).toBeVisible();

    const prompt = appWindow.getByRole("textbox", { name: "Prompt" });
    await prompt.fill("message A");
    await expect
      .poll(async () => (await chatState(appWindow)).sessions[0]?.state.draft)
      .toBe("message A");

    await appWindow.getByLabel("Attachment").setInputFiles({
      buffer: Buffer.from("delayed bytes"),
      mimeType: "text/plain",
      name: "delayed-runtime.txt",
    });
    await expect
      .poll(() =>
        appWindow.evaluate(() => window.chatRuntimeFixture.hasDelayedFileRead())
      )
      .toBe(true);

    await appWindow.getByRole("button", { name: "Send immediately" }).click();
    await prompt.fill("message B");
    await appWindow.evaluate(() => window.chatRuntimeFixture.releaseFileRead());
    await expect
      .poll(async () => (await chatState(appWindow)).sessions[0]?.state.draft)
      .toBe("message B");

    // Main rejects with a draft-changed error; the IPC gateway sanitizes
    // handler failures to "Native command failed." Coordinator unit tests
    // cover the exact Main message. This E2E proves the successor draft was
    // not consumed: no canonical send, and the later text remains.
    await expect(appWindow.locator("#send-state")).toContainText(
      /rejected:.*(draft changed|Native command failed)/i
    );
    await expect.poll(() => stub.messageAttempts.length).toBe(0);
    await expect
      .poll(async () => {
        const current = await fixtureSnapshot(appWindow);
        return {
          attachments: current.draftAttachments.map(({ name, status }) => ({
            name,
            status,
          })),
          draft: current.draft,
        };
      })
      .toEqual({
        attachments: [{ name: "delayed-runtime.txt", status: "uploaded" }],
        draft: "message B",
      });
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("a stale exact intake acknowledgement cannot clear a newer picker failure", async () => {
  await ensureChatRuntimeFixtureBuilt();
  const stub = await startChatRuntimeStub();
  const userDataDir = await mkdtemp(
    join(await realpath(tmpdir()), "comma-stale-intake-ack-e2e-")
  );
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    rendererUrl: delayedIntakeAckFixtureUrl,
    token: runtimeAccountB.token,
    userDataDir,
  });
  const firstPath = join(userDataDir, "first-oversized.png");
  const secondPath = join(userDataDir, "second-oversized.png");

  try {
    await Promise.all([
      writeFile(firstPath, Buffer.alloc(chatAttachmentUploadMaxBytes + 1)),
      writeFile(secondPath, Buffer.alloc(chatAttachmentUploadMaxBytes + 1)),
    ]);
    await launched.app.evaluate(
      ({ dialog }, selectedPaths) => {
        let selection = 0;
        dialog.showOpenDialog = async () => ({
          canceled: false,
          filePaths: [selectedPaths[selection++] ?? selectedPaths.at(-1)!],
        });
      },
      [firstPath, secondPath]
    );
    const appWindow = await findElectronWindowByNativeRole(launched.app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await expect(
      appWindow.getByRole("heading", { name: /ownership fixture/i })
    ).toBeVisible();

    const firstPick = appWindow.evaluate(() =>
      window.chatRuntimeFixture.pickLocalThroughNative()
    );
    await expect
      .poll(() =>
        appWindow.evaluate(() => window.chatRuntimeFixture.isFirstIntakeAckPending())
      )
      .toBe(true);

    const secondResult = await appWindow.evaluate(() =>
      window.chatRuntimeFixture.pickLocalAgainThroughNative()
    );
    expect(secondResult.errors).toHaveLength(1);
    const calls = await appWindow.evaluate(() =>
      window.chatRuntimeFixture.bridgeCalls()
    );
    expect(calls.intakeAcks).toHaveLength(1);
    expect(calls.picks).toHaveLength(1);
    expect(calls.intakeAcks[0]?.intakeId).not.toBe(secondResult.intakeId);

    await appWindow.evaluate(() => window.chatRuntimeFixture.releaseFirstIntakeAck());
    await firstPick;

    const failed = (await fixtureSnapshot(appWindow)).draftAttachments.filter(
      ({ status }) => status === "failed"
    );
    const newerFailure = failed.find((attachment) =>
      attachment.id.includes("intake-2")
    );
    expect(newerFailure).toMatchObject({
      name: "second-oversized.png",
      status: "failed",
    });
    const olderFailure = failed.find(
      (attachment) => attachment.id !== newerFailure?.id
    );
    if (olderFailure) {
      await appWindow.evaluate(
        (attachmentId) => window.chatRuntimeFixture.removeAttachment(attachmentId),
        olderFailure.id
      );
    }

    await expect
      .poll(async () =>
        (await fixtureSnapshot(appWindow)).draftAttachments.filter(
          ({ status }) => status === "failed"
        )
      )
      .toMatchObject([
        {
          id: newerFailure!.id,
          name: "second-oversized.png",
          status: "failed",
        },
      ]);

    await expect(
      appWindow.evaluate(() =>
        window.chatRuntimeFixture.sendCurrentAccepted("must remain blocked")
      )
    ).rejects.toThrow(/attachment|intake|selected file|Native command failed/i);
    expect(stub.messageAttempts).toHaveLength(0);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
});

test("local-index selection crosses renderer, native Chat, and canonical send as an opaque ref", async () => {
  await ensureChatRuntimeFixtureBuilt();
  const stub = await startChatRuntimeStub({ deferAccountBMessages: true });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    rendererUrl: stubbedPickFixtureUrl,
    token: runtimeAccountB.token,
  });

  try {
    const appWindow = await findElectronWindowByNativeRole(launched.app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await expect(
      appWindow.getByRole("heading", { name: /ownership fixture/i })
    ).toBeVisible();

    await appWindow
      .getByRole("button", { name: "Pick local-index attachment" })
      .click();
    await expect
      .poll(async () => (await fixtureSnapshot(appWindow)).draftAttachments)
      .toMatchObject([
        {
          name: "fixture-local-index.txt",
          size: 7,
          status: "uploaded",
        },
      ]);

    await appWindow.getByRole("button", { name: "Send immediately" }).click();
    await expect.poll(() => stub.messageAttempts.length).toBe(1);
    expect(stub.messageAttempts[0]?.body).toMatchObject({
      message: {
        content: [
          { type: "text", text: "Send the delayed attachment" },
          {
            type: "local_file",
            local_file_ref: `lfi1_${"e".repeat(43)}`,
            display_name: "fixture-local-index.txt",
            media_type: "text/plain",
            size: 7,
          },
        ],
      },
    });
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("a released exact Chat lease cannot register a file selected by a delayed picker", async () => {
  await ensureChatRuntimeFixtureBuilt();
  const stub = await startChatRuntimeStub();
  const userDataDir = await mkdtemp(
    join(await realpath(tmpdir()), "comma-stale-chat-picker-e2e-")
  );
  await writeFile(
    join(userDataDir, "connector.json.status.json"),
    JSON.stringify({
      connector_run_id: "run_stale_chat_picker",
      device_id: "dev_stale_chat_picker",
      local_file_index_version: 2,
      state: "connected",
    })
  );
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    rendererUrl: fixtureUrl,
    token: runtimeAccountB.token,
    userDataDir,
  });
  const sourcePath = join(launched.userDataDir, "must-not-register.txt");

  try {
    await writeFile(sourcePath, "private local bytes");
    await launched.app.evaluate(({ dialog }, selectedPath) => {
      type PickerGateHost = typeof globalThis & {
        commaStalePickerGate?: { release(): void; started: boolean };
      };
      let release!: () => void;
      const released = new Promise<void>((releasePicker) => {
        release = releasePicker;
      });
      const gate = { release, started: false };
      (globalThis as PickerGateHost).commaStalePickerGate = gate;
      dialog.showOpenDialog = async () => {
        gate.started = true;
        await released;
        return { canceled: false, filePaths: [selectedPath] };
      };
    }, sourcePath);
    const appWindow = await findElectronWindowByNativeRole(launched.app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await expect(
      appWindow.getByRole("heading", { name: /ownership fixture/i })
    ).toBeVisible();

    const picking = appWindow.evaluate(() =>
      window.chatRuntimeFixture.pickLocalThroughNative()
    );
    await expect
      .poll(() =>
        launched.app.evaluate(() => {
          type PickerGateHost = typeof globalThis & {
            commaStalePickerGate?: { started: boolean };
          };
          return (globalThis as PickerGateHost).commaStalePickerGate?.started;
        })
      )
      .toBe(true);

    await appWindow.evaluate(() => window.chatRuntimeFixture.stopChannel());
    await expect
      .poll(() =>
        appWindow.evaluate(() => window.chatRuntimeFixture.completedReleaseCount())
      )
      .toBeGreaterThan(0);
    await launched.app.evaluate(() => {
      type PickerGateHost = typeof globalThis & {
        commaStalePickerGate?: { release(): void };
      };
      (globalThis as PickerGateHost).commaStalePickerGate?.release();
    });

    await expect(picking).rejects.toThrow(/not retained|current/i);
    expect(stub.localFileRegistrations).toHaveLength(0);
    expect(
      stub.requests.filter(
        ({ method, path }) =>
          method === "POST" &&
          path === `/v1/comma/workspaces/${runtimeAccountB.workspaceId}/local-file-refs`
      )
    ).toHaveLength(0);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("Side Chat uploads a native image and previews it through the authenticated workspace read", async () => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");

  await ensureChatRuntimeFixtureBuilt();
  const stub = await startChatRuntimeStub();
  const userDataDir = await mkdtemp(
    join(await realpath(tmpdir()), "comma-side-chat-image-upload-e2e-")
  );
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    rendererUrl: fixtureUrl,
    token: runtimeAccountB.token,
    userDataDir,
  });
  const contents = onePixelPng;
  const sourcePath = join(launched.userDataDir, "side-chat-native.png");

  try {
    await writeFile(sourcePath, contents);
    await launched.app.evaluate(({ dialog }, selectedPath) => {
      dialog.showOpenDialog = async () => ({
        canceled: false,
        filePaths: [selectedPath],
      });
    }, sourcePath);
    const sideChatWindow = await findElectronWindowByNativeRole(
      launched.app,
      "side-chat-window"
    );
    await sideChatWindow.waitForLoadState("domcontentloaded");
    await sideChatWindow.evaluate(() =>
      window.chatRuntimeFixture.startReplacementChannel()
    );

    await sideChatWindow.evaluate(() =>
      window.chatRuntimeFixture.pickLocalThroughNative()
    );
    await expect
      .poll(async () => (await fixtureSnapshot(sideChatWindow)).draftAttachments)
      .toMatchObject([
        {
          name: "side-chat-native.png",
          path: expect.stringMatching(
            /^\/uploads\/[A-Za-z0-9_-]{22}-side-chat-native\.png$/
          ),
          size: contents.byteLength,
          status: "uploaded",
        },
      ]);
    const workspacePath = (await fixtureSnapshot(sideChatWindow)).draftAttachments[0]
      ?.path;
    if (!workspacePath) {
      throw new Error("The picked image did not produce a workspace upload path.");
    }
    const preview = await sideChatWindow.evaluate(
      (path) => window.chatRuntimeFixture.previewLocal(path),
      workspacePath
    );
    expect(preview).toMatchObject({
      height: 1,
      url: expect.stringMatching(/^blob:/),
      width: 1,
    });
    expect(stub.uploads).toHaveLength(1);
    expect(stub.uploads[0]).toMatchObject({
      contentType: "image/png",
      filename: "side-chat-native.png",
      path: workspacePath,
      token: runtimeAccountB.token,
      workspaceId: runtimeAccountB.workspaceId,
    });
    expect(stub.uploads[0]?.bytes).toEqual(contents);
    expect(stub.workspaceFileReads).toEqual([
      {
        path: workspacePath,
        token: runtimeAccountB.token,
        workspaceId: runtimeAccountB.workspaceId,
      },
    ]);
    expect(stub.localFileRegistrations).toHaveLength(0);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("a renderer-selected file over 10 MB uses the local index without uploading bytes", async () => {
  await ensureChatRuntimeFixtureBuilt();
  const stub = await startChatRuntimeStub();
  const userDataDir = await mkdtemp(
    join(await realpath(tmpdir()), "comma-selected-file-e2e-")
  );
  await writeFile(
    join(userDataDir, "connector.json.status.json"),
    JSON.stringify({
      connector_run_id: "run_selected_file",
      device_id: "dev_selected_file",
      local_file_index_version: 2,
      state: "connected",
    })
  );
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    rendererUrl: fixtureUrl,
    token: runtimeAccountB.token,
    userDataDir,
  });
  try {
    const sourcePath = join(userDataDir, "large-report.pdf");
    await writeFile(sourcePath, Buffer.alloc(chatAttachmentUploadMaxBytes + 1));
    const appWindow = await findElectronWindowByNativeRole(launched.app, "main-window");
    await expect(
      appWindow.getByRole("heading", { name: /ownership fixture/i })
    ).toBeVisible();
    await appWindow.getByLabel("Attachment").setInputFiles(sourcePath);
    await expect
      .poll(async () => (await fixtureSnapshot(appWindow)).draftAttachments)
      .toMatchObject([
        {
          name: "large-report.pdf",
          status: "uploaded",
          size: chatAttachmentUploadMaxBytes + 1,
        },
      ]);
    expect(stub.uploads).toHaveLength(0);
    expect(stub.localFileRegistrations).toHaveLength(1);
    await appWindow.getByRole("button", { name: "Send immediately" }).click();
    await expect.poll(() => stub.messageAttempts.length).toBe(1);
    expect(stub.messageAttempts[0]?.body).toMatchObject({
      message: {
        content: [
          { type: "text", text: "Send the delayed attachment" },
          {
            type: "local_file",
            display_name: "large-report.pdf",
            local_file_ref: expect.stringMatching(/^lfi1_[A-Za-z0-9_-]{43}$/),
            size: chatAttachmentUploadMaxBytes + 1,
          },
        ],
      },
    });
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
});

test("an image over 10 MB fails before upload or local-file registration", async () => {
  const stub = await startChatRuntimeStub();
  const userDataDir = await mkdtemp(
    join(await realpath(tmpdir()), "comma-oversized-image-intake-e2e-")
  );
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
    userDataDir,
  });
  const sourcePath = join(launched.userDataDir, "oversized-native.png");

  try {
    await writeFile(sourcePath, Buffer.alloc(chatAttachmentUploadMaxBytes + 1));
    await launched.app.evaluate(({ dialog }, selectedPath) => {
      dialog.showOpenDialog = async () => ({
        canceled: false,
        filePaths: [selectedPath],
      });
    }, sourcePath);
    const appWindow = await productWindow(launched.app);
    const content = appWindow.getByRole("region", { name: "Content" });
    const startedAt = Date.now();
    await content.getByRole("button", { name: "Add attachment" }).click();
    // Upload failures are scoped per composer, so a window with more than one
    // mounted can legitimately show more than one card. Verify the product
    // feedback rather than coupling this intake test to that count.
    const uploadError = appWindow.getByTestId("chat-upload-error").first();
    await expect(uploadError).toContainText("oversized-native.png upload failed");
    await expect(uploadError).toContainText("The selected image is larger than 10 MB.");
    expect(Date.now() - startedAt).toBeLessThan(5_000);
    expect(stub.uploads).toHaveLength(0);
    expect(stub.localFileRegistrations).toHaveLength(0);
    await expect(
      readDirectory(join(launched.userDataDir, "local-file-index", "entries"))
    ).resolves.toEqual([]);
    await expect(
      readDirectory(join(launched.userDataDir, "local-file-index", "objects"))
    ).resolves.toEqual([]);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("a connected legacy index reader cannot register a new V2 local snapshot", async () => {
  await ensureChatRuntimeFixtureBuilt();
  const stub = await startChatRuntimeStub();
  const userDataDir = await mkdtemp(
    join(await realpath(tmpdir()), "comma-local-file-legacy-reader-e2e-")
  );
  await writeFile(
    join(userDataDir, "connector.json.status.json"),
    JSON.stringify({
      device_id: "dev_runtime_legacy_reader",
      state: "connected",
    })
  );
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    rendererUrl: fixtureUrl,
    token: runtimeAccountB.token,
    userDataDir,
  });
  const sourcePath = join(launched.userDataDir, "legacy-reader-private.txt");

  try {
    await writeFile(sourcePath, "ordinary local file");
    await launched.app.evaluate(({ dialog }, selectedPath) => {
      dialog.showOpenDialog = async () => ({
        canceled: false,
        filePaths: [selectedPath],
      });
    }, sourcePath);
    const appWindow = await findElectronWindowByNativeRole(launched.app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await expect(
      appWindow.getByRole("heading", { name: /ownership fixture/i })
    ).toBeVisible();

    const picked = await appWindow.evaluate(
      (workspaceId) => window.chatRuntimeFixture.pickLocalForWorkspace(workspaceId),
      runtimeAccountB.workspaceId
    );

    expect(picked).toMatchObject({
      cancelled: false,
      errors: [{ errorClass: "local_file_unavailable" }],
      files: [],
    });
    expect(stub.localFileRegistrations).toHaveLength(0);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("native images upload, preview in the Composer, and use the sent image group", async () => {
  const stub = await startChatRuntimeStub();
  const userDataDir = await mkdtemp(
    join(await realpath(tmpdir()), "comma-uploaded-image-presentation-e2e-")
  );
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
    userDataDir,
  });
  const selectedImageNames = Array.from(
    { length: 4 },
    (_, index) => `product-image-${index + 1}.png`
  );
  const highResolutionImageName = selectedImageNames[0]!;
  const sourcePaths = selectedImageNames.map((name) =>
    join(launched.userDataDir, name)
  );

  try {
    const highResolutionImageBytes = await readFile(highResolutionPreviewFixture);
    expect(highResolutionImageBytes.byteLength).toBeLessThan(
      chatAttachmentUploadMaxBytes
    );
    // A phone-sized source must keep its own preview instead of a placeholder.
    const phonePhotoBytes = Buffer.from(
      await launched.app.evaluate(
        ({ nativeImage }, base64) =>
          nativeImage
            .createFromDataURL(`data:image/png;base64,${base64}`)
            .resize({ width: 5_712, height: 4_284 })
            .toPNG()
            .toString("base64"),
        onePixelPng.toString("base64")
      ),
      "base64"
    );
    expect(phonePhotoBytes.byteLength).toBeLessThan(chatAttachmentUploadMaxBytes);
    const sourceBytes = selectedImageNames.map((_, index) =>
      index === 0
        ? highResolutionImageBytes
        : index === 1
          ? phonePhotoBytes
          : onePixelPng
    );
    await Promise.all(
      sourcePaths.map((path, index) => writeFile(path, sourceBytes[index]!))
    );
    await launched.app.evaluate(({ dialog }, selectedPaths) => {
      type PickerOwnerHost = typeof globalThis & { commaPickerOwner?: unknown };
      dialog.showOpenDialog = async (...args: unknown[]) => {
        // A sheet passes its parent window before the options.
        (globalThis as PickerOwnerHost).commaPickerOwner =
          args.length > 1 ? args[0] : undefined;
        return { canceled: false, filePaths: selectedPaths };
      };
    }, sourcePaths);

    const appWindow = await productWindow(launched.app);
    const content = appWindow.getByRole("region", { name: "Content" });
    await content.getByRole("button", { name: "Add attachment" }).click();

    await expect.poll(() => stub.uploads.length).toBe(4);
    // The picker opens as a sheet in front of the window whose + was clicked.
    const appBrowserWindow = await launched.app.browserWindow(appWindow);
    expect(
      await appBrowserWindow.evaluate((window) => {
        type PickerOwnerHost = typeof globalThis & { commaPickerOwner?: unknown };
        return (globalThis as PickerOwnerHost).commaPickerOwner === window;
      })
    ).toBe(true);
    expect(stub.localFileRegistrations).toHaveLength(0);
    const uploadsByFilename = new Map(
      stub.uploads.map((upload) => [upload.filename, upload])
    );
    expect(uploadsByFilename.size).toBe(selectedImageNames.length);
    for (const [index, filename] of selectedImageNames.entries()) {
      const upload = uploadsByFilename.get(filename);
      expect(upload).toMatchObject({
        contentType: "image/png",
        filename,
        path: expect.stringMatching(
          new RegExp(`^/uploads/[A-Za-z0-9_-]{22}-${filename.replace(".", "\\.")}$`)
        ),
        token: runtimeAccountB.token,
        workspaceId: runtimeAccountB.workspaceId,
      });
      expect(upload?.bytes).toEqual(sourceBytes[index]);
    }
    const composerImages = content
      .locator(".comma-chat-composer-frame")
      .getByRole("img", { name: /^product-image-\d\.png$/ });
    await expect(composerImages).toHaveCount(4);
    await expect
      .poll(() =>
        composerImages.evaluateAll((images) =>
          images.map((image) => image.getAttribute("alt"))
        )
      )
      .toEqual(selectedImageNames);
    await expect
      .poll(() =>
        composerImages.evaluateAll((images) =>
          images.map((image) => image.getAttribute("src"))
        )
      )
      .toEqual([
        expect.stringMatching(/^blob:/),
        expect.stringMatching(/^blob:/),
        expect.stringMatching(/^blob:/),
        expect.stringMatching(/^blob:/),
      ]);
    // The upload remains full size. Only its decoded preview is reduced.
    await expect
      .poll(() =>
        composerImages.nth(1).evaluate((image: HTMLImageElement) => ({
          height: image.naturalHeight,
          width: image.naturalWidth,
        }))
      )
      .toEqual({ height: 2_142, width: 2_856 });

    await content.getByRole("button", { name: "Send", exact: true }).click();
    await expect.poll(() => stub.messageAttempts.length).toBe(1);

    const sentMessage = content.locator('[data-message-id="runtime-user-message-1"]');
    await expect(sentMessage).toBeVisible();
    const imageGroup = sentMessage.locator(".chat-panel-image-group");
    await expect(imageGroup).toBeVisible();
    const imageGroupToggle = imageGroup.locator(".chat-panel-image-group-toggle");
    await expect(imageGroupToggle).toHaveAccessibleName("4 Images");
    await expect(imageGroupToggle).toHaveAttribute("aria-expanded", "false");
    await expect(imageGroup.locator(".chat-panel-image-group-card")).toHaveCount(4);
    const sentImages = imageGroup.locator(".chat-panel-image-group-card img");
    await expect(sentImages).toHaveCount(3);
    await expect
      .poll(() =>
        sentImages.evaluateAll((images) =>
          images.map((image) => image.getAttribute("alt"))
        )
      )
      .toEqual(selectedImageNames.slice(0, 3));
    const highResolutionCardImage = imageGroup.getByRole("img", {
      name: highResolutionImageName,
    });
    await expect
      .poll(() =>
        highResolutionCardImage.evaluate((image) => {
          const renderedImage = image as HTMLImageElement;
          return {
            height: renderedImage.naturalHeight,
            width: renderedImage.naturalWidth,
          };
        })
      )
      .toEqual(highResolutionPreviewDimensions);
    const cardPresentation = await highResolutionCardImage.evaluate((image) => {
      const renderedImage = image as HTMLImageElement;
      const card = renderedImage.closest<HTMLElement>(".chat-panel-image-group-card");
      if (!card) throw new Error("Expected an image group card.");
      const cardBounds = card.getBoundingClientRect();
      const cardStyle = getComputedStyle(card);
      // The card draws a hairline border around its clipped viewport; the
      // image fills the content box inside it.
      const cardContentWidth =
        cardBounds.width -
        parseFloat(cardStyle.borderLeftWidth) -
        parseFloat(cardStyle.borderRightWidth);
      const cardContentHeight =
        cardBounds.height -
        parseFloat(cardStyle.borderTopWidth) -
        parseFloat(cardStyle.borderBottomWidth);
      const imageBounds = renderedImage.getBoundingClientRect();
      return {
        cardOverflow: cardStyle.overflow,
        fillsCard:
          Math.abs(cardContentWidth - imageBounds.width) < 0.5 &&
          Math.abs(cardContentHeight - imageBounds.height) < 0.5,
        hasEnoughPhysicalPixels:
          renderedImage.naturalWidth >= cardBounds.width * window.devicePixelRatio &&
          renderedImage.naturalHeight >= cardBounds.height * window.devicePixelRatio,
        imageObjectFit: getComputedStyle(renderedImage).objectFit,
      };
    });
    expect(cardPresentation).toEqual({
      cardOverflow: "hidden",
      fillsCard: true,
      hasEnoughPhysicalPixels: true,
      imageObjectFit: "cover",
    });

    const cardSource = await highResolutionCardImage.getAttribute("src");
    await highResolutionCardImage.click();
    const previewDialog = appWindow.getByRole("dialog", { name: "Preview image" });
    await expect(previewDialog).toBeVisible();
    const previewImage = previewDialog.locator(
      `.chat-panel-image-filmstrip-slide[alt="${highResolutionImageName}"]`
    );
    await expect
      .poll(() =>
        previewImage.evaluate((image) => {
          const renderedImage = image as HTMLImageElement;
          return {
            height: renderedImage.naturalHeight,
            objectFit: getComputedStyle(renderedImage).objectFit,
            source: renderedImage.getAttribute("src"),
            width: renderedImage.naturalWidth,
          };
        })
      )
      .toEqual({
        ...highResolutionPreviewDimensions,
        objectFit: "contain",
        source: cardSource,
      });
    await previewDialog.getByRole("button", { name: "Close preview" }).click();
    await expect(previewDialog).toBeHidden();
    await expect(imageGroup.locator('[data-stack-pos="0"]')).toHaveCount(1);
    await expect(imageGroup.locator('[data-stack-pos="hidden-right"] img')).toHaveCount(
      0
    );
    await imageGroupToggle.click();
    await expect(imageGroupToggle).toHaveAttribute("aria-expanded", "true");
    await expect(imageGroupToggle).toHaveAccessibleName("Hide");
    await expect(sentImages).toHaveCount(4);
    await expect
      .poll(() =>
        sentImages.evaluateAll((images) =>
          images.map((image) => image.getAttribute("alt"))
        )
      )
      .toEqual(selectedImageNames);
    await expect(
      sentMessage.locator('[data-testid^="chat-attachment-preview-"]')
    ).toHaveCount(0);
    await expect
      .poll(() => new Set(stub.workspaceFileReads.map((read) => read.path)).size)
      .toBe(4);
    expect(new Set(stub.workspaceFileReads.map((read) => read.path))).toEqual(
      new Set(stub.uploads.map((upload) => upload.path))
    );
    expect(
      stub.workspaceFileReads.every(
        (read) =>
          read.token === runtimeAccountB.token &&
          read.workspaceId === runtimeAccountB.workspaceId
      )
    ).toBe(true);
    expect(stub.localFileRegistrations).toHaveLength(0);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("local image preview rejects an old ref after account replacement", async () => {
  await ensureChatRuntimeFixtureBuilt();
  const stub = await startChatRuntimeStub();
  const userDataDir = await mkdtemp(
    join(await realpath(tmpdir()), "comma-local-preview-owner-e2e-")
  );
  await writeFile(
    join(userDataDir, "connector.json.status.json"),
    JSON.stringify({
      connector_run_id: "run_runtime_preview_owner",
      device_id: "dev_runtime_preview_owner",
      local_file_index_version: 2,
      state: "connected",
    })
  );
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountA.email,
    rendererUrl: fixtureUrl,
    token: runtimeAccountA.token,
    userDataDir,
  });
  const sourcePath = join(launched.userDataDir, "account-a-private.png");

  try {
    await writeFile(sourcePath, onePixelPng);
    await launched.app.evaluate(({ dialog }, selectedPath) => {
      dialog.showOpenDialog = async () => ({
        canceled: false,
        filePaths: [selectedPath],
      });
    }, sourcePath);
    const appWindow = await findElectronWindowByNativeRole(launched.app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await expect(
      appWindow.getByRole("heading", { name: /ownership fixture/i })
    ).toBeVisible();

    const picked = await appWindow.evaluate(
      (workspaceId) => window.chatRuntimeFixture.pickLocalForWorkspace(workspaceId),
      runtimeAccountA.workspaceId
    );
    expect(picked).toMatchObject({
      cancelled: false,
      errors: [],
      files: [
        {
          localFileRef: expect.stringMatching(/^lfi1_[A-Za-z0-9_-]{43}$/),
          mediaType: "image/png",
          name: "account-a-private.png",
          size: onePixelPng.byteLength,
        },
      ],
    });
    const localFileRef = picked.files[0]?.localFileRef;
    if (!localFileRef) throw new Error("Account A did not receive a local ref.");

    await expect(
      appWindow.evaluate(
        (ref) => window.chatRuntimeFixture.previewLocalThroughNative(ref),
        localFileRef
      )
    ).resolves.toMatchObject({
      height: 1,
      status: "ready",
      url: expect.stringMatching(/^blob:/),
      width: 1,
    });

    await appWindow.evaluate(() => window.chatRuntimeFixture.replaceSession());

    await expect(
      appWindow.evaluate(
        (ref) => window.chatRuntimeFixture.previewLocalThroughNative(ref),
        localFileRef
      )
    ).resolves.toEqual({ status: "unavailable" });
    expect(stub.localFileRegistrations).toEqual([
      expect.objectContaining({
        body: expect.objectContaining({
          connector_run_id: "run_runtime_preview_owner",
          local_file_index_version: 2,
          local_file_ref: localFileRef,
          stable_device_id: "dev_runtime_preview_owner",
        }),
        token: runtimeAccountA.token,
      }),
    ]);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("Google login uses the Main-owned auth origin", async () => {
  const trustedStub = await startChatRuntimeStub({ googlePreparationFailures: 1 });
  const rendererTarget = await startChatRuntimeStub();
  const launched = await launchRuntimeApp({
    baseUrl: trustedStub.baseUrl,
    email: runtimeAccountB.email,
    googleIdToken: "runtime-google-id-token",
  });

  try {
    const appWindow = await mainProductWindow(launched.app);
    await appWindow.evaluate((apiBaseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", apiBaseUrl);
    }, rendererTarget.baseUrl);
    await appWindow.reload();
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();

    const rendererAuthBypass = await attemptRendererAuthBypass(appWindow);
    expect(rendererAuthBypass).toEqual({
      body: { error: "not_found" },
      status: 404,
    });
    expect(
      trustedStub.requests.filter(
        (request) =>
          request.method === "POST" && request.path === "/v1/comma/auth/email/verify"
      )
    ).toEqual([]);
    await expect.poll(() => sessionSignedIn(appWindow)).toBe(false);

    await appWindow.getByRole("button", { name: "Sign in with Google" }).click();
    await expect(
      appWindow.getByText(
        "Comma could not complete sign-in. Please try again in a moment."
      )
    ).toBeVisible();
    await expect(
      appWindow.getByRole("button", { name: "Retry Google sign-in" })
    ).toBeEnabled();
    expect(trustedStub.googleAttempts).toEqual([{ platform: "electron" }]);
    await appWindow.getByRole("button", { name: "Retry Google sign-in" }).click();
    await expect.poll(() => sessionSignedIn(appWindow)).toBe(true);

    expect(rendererTarget.requests).toEqual([]);
    await expect
      .poll(() => trustedStub.googleAttempts)
      .toEqual([{ platform: "electron" }, { platform: "electron" }]);
    await expect
      .poll(() => trustedStub.googleCompletions)
      .toEqual([
        expect.objectContaining({
          attempt_id: "runtime-google-attempt",
          authorization_code: "runtime-google-id-token",
          client_kind: "electron",
          client_platform: "macos",
          code_verifier: "runtime-google-code-verifier-01234567890123456789",
          nonce: "runtime-google-nonce",
          redirect_uri: "http://127.0.0.1:43123/oauth2/callback",
        }),
      ]);
    await expect(
      appWindow.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    await expectSignedInShellAs(appWindow, runtimeAccountB.email);

    const rendererSession = await appWindow.evaluate(async () =>
      (
        window as unknown as {
          commaNative: { session: { state: { get: () => Promise<unknown> } } };
        }
      ).commaNative.session.state.get()
    );
    expect(rendererSession).toMatchObject({
      phase: "signed_in",
      principal: { email: runtimeAccountB.email },
      session: { audience: trustedStub.baseUrl },
    });
    expect(JSON.stringify(rendererSession)).not.toContain(runtimeAccountB.token);
    await expect
      .poll(
        () =>
          trustedStub.requests.filter(
            (request) =>
              request.method === "POST" &&
              request.path === "/v1/comma/me/bootstrap" &&
              request.token === runtimeAccountB.token
          ).length
      )
      .toBeGreaterThan(0);
    expect(rendererTarget.requests).toEqual([]);
  } finally {
    await launched.app.close();
    await rendererTarget.close();
    await trustedStub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("a durable auth commit cannot be canceled by an overlapping sign-in", async () => {
  const stub = await startChatRuntimeStub();
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
  });

  try {
    const appWindow = await mainProductWindow(launched.app);
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    await installAuthCommitGate(launched.app, launched.userDataDir);

    const committedSignIn = verifyEmailThroughNative(
      appWindow,
      "runtime-commit-first",
      "111111"
    );
    await expect.poll(() => authCommitGateReached(launched.app)).toBe(true);

    await expect(
      verifyEmailThroughNative(appWindow, "runtime-commit-overlap", "222222")
    ).rejects.toThrow("Native command failed.");

    await releaseAuthCommitGate(launched.app);
    await expect(committedSignIn).resolves.toMatchObject({
      signedIn: true,
      userId: "user-runtime-b",
    });
    await expect.poll(() => sessionSignedIn(appWindow)).toBe(true);

    await expect(signOutThroughNative(appWindow)).resolves.toMatchObject({
      phase: "signed_out",
    });
    await expect.poll(() => sessionSignedIn(appWindow)).toBe(false);

    await expect(
      verifyEmailThroughNative(appWindow, "runtime-commit-replacement", "333333")
    ).resolves.toMatchObject({
      signedIn: true,
      userId: "user-runtime-b",
    });
    await expect.poll(() => sessionSignedIn(appWindow)).toBe(true);
  } finally {
    await releaseAuthCommitGate(launched.app).catch(() => {});
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("a stale A durable commit cannot clear B's replacement credential", async () => {
  const stub = await startChatRuntimeStub();
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountA.email,
  });
  let firstAppClosed = false;
  let restarted: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;

  try {
    const appWindow = await mainProductWindow(launched.app);
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    await installAuthCommitGate(launched.app, launched.userDataDir);

    const accountAChallenge = await requestEmailLoginThroughNative(
      appWindow,
      runtimeAccountA.email
    );
    expect(accountAChallenge).toMatchObject({
      challengeId: "runtime-challenge-a",
      attempt: {
        attemptId: expect.any(String),
        expected: accountAChallenge.expected,
      },
    });
    const accountACommit = verifyEmailAttemptThroughNative(
      appWindow,
      accountAChallenge,
      "111111"
    );
    await expect.poll(() => authCommitGateReached(launched.app)).toBe(true);

    const accountBChallenge = await requestEmailLoginThroughNative(
      appWindow,
      runtimeAccountB.email,
      accountAChallenge.expected
    );
    expect(accountBChallenge).toMatchObject({
      challengeId: "runtime-challenge-b",
      attempt: {
        attemptId: expect.any(String),
        expected: accountAChallenge.expected,
      },
    });
    const accountBCommit = verifyEmailAttemptThroughNative(
      appWindow,
      accountBChallenge,
      "222222"
    );
    await expect
      .poll(() => stub.emailVerifications)
      .toEqual([
        expect.objectContaining({
          challenge_id: "runtime-challenge-a",
          client_kind: "electron",
          client_platform: "macos",
          code: "111111",
        }),
        expect.objectContaining({
          challenge_id: "runtime-challenge-b",
          client_kind: "electron",
          client_platform: "macos",
          code: "222222",
        }),
      ]);

    await releaseAuthCommitGate(launched.app);
    const [accountAResult, accountBResult] = await Promise.all([
      accountACommit,
      accountBCommit,
    ]);
    expect(accountAResult).toMatchObject({
      error: { code: "cancelled" },
      ok: false,
    });
    expect(
      accountBResult.ok ? accountBResult.value.phase : accountBResult.error.code
    ).toBe("signed_in");
    if (!accountBResult.ok) {
      throw new Error("Account B replacement did not commit.");
    }
    expect(accountBResult.value).toMatchObject({
      phase: "signed_in",
      principal: { email: runtimeAccountB.email },
    });
    expect(await sessionState(appWindow)).toMatchObject({
      email: runtimeAccountB.email,
      phase: "signed_in",
      signedIn: true,
    });

    await launched.app.close();
    firstAppClosed = true;
    restarted = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountB.email,
      userDataDir: launched.userDataDir,
    });
    const restartedWindow = await productWindow(restarted.app);
    await expectSignedInShellAs(restartedWindow, runtimeAccountB.email);
    expect(await sessionState(restartedWindow)).toMatchObject({
      email: runtimeAccountB.email,
      phase: "signed_in",
      signedIn: true,
    });
  } finally {
    await releaseAuthCommitGate(launched.app).catch(() => {});
    if (!firstAppClosed) {
      await launched.app.close().catch(() => {});
    }
    await restarted?.app.close().catch(() => {});
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("unsafe quit is vetoed until unresolved issued cleanup becomes durable", async () => {
  const stub = await startChatRuntimeStub({
    hangLogoutTokens: [runtimeAccountA.token],
  });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountA.email,
  });
  const secureSessionFile = join(launched.userDataDir, "secure-session.bin");
  let firstAppClosed = false;
  let fsyncFailureInstalled = false;
  let restarted: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;

  try {
    const appWindow = await mainProductWindow(launched.app);
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    const challenge = await requestEmailLoginThroughNative(
      appWindow,
      runtimeAccountA.email
    );
    await installAuthCommitFsyncFailure(launched.app, secureSessionFile);
    fsyncFailureInstalled = true;

    await expect(
      verifyEmailAttemptThroughNative(appWindow, challenge, "111111")
    ).resolves.toMatchObject({
      error: { code: "credential_mutation_uncertain" },
      ok: false,
    });
    expect(await sessionState(appWindow)).toMatchObject({
      phase: "indeterminate",
      problem: {
        code: "credential_mutation_uncertain",
        operation: "authenticate",
      },
      revocationPending: false,
      signedIn: false,
    });
    expect(await authCommitFsyncFailureCount(launched.app)).toBeGreaterThanOrEqual(2);
    expect(await serverSessionStatus(stub.baseUrl, runtimeAccountA.token)).toBe(200);

    await installShutdownBlockedProbe(launched.app);
    await launched.app.evaluate(({ app }) => app.quit());
    await expect
      .poll(() => shutdownBlockedMessages(launched.app), { timeout: 15_000 })
      .toEqual([
        {
          message: expect.stringContaining(
            "Session credential that could not be safely stored or revoked"
          ),
          title: `${electronProductName} could not quit safely`,
        },
      ]);
    expect(launched.app.process().exitCode).toBeNull();
    expect(await sessionState(appWindow)).toMatchObject({
      phase: "indeterminate",
      revocationPending: false,
      signedIn: false,
    });
    expect(await authCommitFsyncFailureCount(launched.app)).toBeGreaterThanOrEqual(3);
    expect(await serverSessionStatus(stub.baseUrl, runtimeAccountA.token)).toBe(200);

    await restoreAuthCommitFsyncFailure(launched.app);
    fsyncFailureInstalled = false;
    const secondQuit = launched.app.waitForEvent("close");
    await launched.app.evaluate(({ app }) => app.quit());
    await secondQuit;
    firstAppClosed = true;

    restarted = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountA.email,
      userDataDir: launched.userDataDir,
    });
    const restartedWindow = await mainProductWindow(restarted.app);
    await expect(
      restartedWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    expect(await sessionState(restartedWindow)).toMatchObject({
      phase: "signed_out",
      revocationPending: true,
      signedIn: false,
    });
    expect(await serverSessionStatus(stub.baseUrl, runtimeAccountA.token)).toBe(200);

    const envelope = await decryptSessionEnvelope(restarted.app, secureSessionFile);
    expect(envelope).toMatchObject({
      pendingRevocations: [
        {
          audience: stub.baseUrl,
          sessionId: `runtime-session:${runtimeAccountA.email}`,
          token: runtimeAccountA.token,
        },
      ],
      version: 3,
    });
    expect(envelope).not.toHaveProperty("active");
  } finally {
    if (fsyncFailureInstalled) {
      await restoreAuthCommitFsyncFailure(launched.app).catch(() => {});
    }
    if (!firstAppClosed) {
      await launched.app.close().catch(() => {});
    }
    await restarted?.app.close().catch(() => {});
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("pending Google login can reopen after focus and switch to email", async () => {
  let releaseGoogle!: () => void;
  const googleAttemptGate = new Promise<void>((complete) => {
    releaseGoogle = complete;
  });
  const stub = await startChatRuntimeStub({ googleAttemptGate });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    googleIdToken: "runtime-google-id-token",
  });
  try {
    const appWindow = await mainProductWindow(launched.app);
    const google = appWindow.getByRole("button", { name: "Sign in with Google" });
    const email = appWindow.getByRole("textbox", { name: "Email", exact: true });
    await google.click();
    await expect.poll(() => stub.googleAttempts.length).toBe(1);
    await expect(google).toBeDisabled();
    await appWindow.evaluate(() => window.dispatchEvent(new Event("blur")));
    await expect(google).toBeDisabled();
    await expect(email).toBeEnabled();
    await appWindow.evaluate(() => window.dispatchEvent(new Event("focus")));
    await expect(google).toBeEnabled();
    await appWindow.evaluate(() => window.dispatchEvent(new Event("blur")));
    await expect(google).toBeEnabled();
    await google.click();
    await expect.poll(() => stub.googleAttempts.length).toBe(2);
    await expect(google).toBeDisabled();
    await appWindow.evaluate(() => window.dispatchEvent(new Event("blur")));
    await expect(google).toBeDisabled();
    await email.fill(runtimeAccountB.email);
    await appWindow.getByRole("button", { name: "Continue with email" }).click();
    await expect(
      appWindow.getByRole("heading", { name: "Check your email" })
    ).toBeVisible();
    releaseGoogle();
    await appWindow.getByRole("textbox", { name: /verification code/i }).fill("654321");
    await expectSignedInShellAs(appWindow, runtimeAccountB.email);
    expect(stub.googleCompletions).toEqual([]);
    expect(stub.emailVerifications).toHaveLength(1);
  } finally {
    releaseGoogle();
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("conditional Google linking stays signed out until Main verifies the email code", async () => {
  const stub = await startChatRuntimeStub({ googleLinkRequired: true });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    googleIdToken: "runtime-google-link-id-token",
  });

  try {
    const appWindow = await mainProductWindow(launched.app);
    await appWindow.evaluate((apiBaseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", apiBaseUrl);
    }, stub.baseUrl);
    await appWindow.reload();
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();

    await appWindow.getByRole("button", { name: "Sign in with Google" }).click();

    await expect
      .poll(() => stub.googleCompletions)
      .toEqual([
        expect.objectContaining({
          attempt_id: "runtime-google-attempt",
          authorization_code: "runtime-google-link-id-token",
          client_kind: "electron",
          client_platform: "macos",
          code_verifier: "runtime-google-code-verifier-01234567890123456789",
          nonce: "runtime-google-nonce",
          redirect_uri: "http://127.0.0.1:43123/oauth2/callback",
        }),
      ]);
    await expect(
      appWindow.getByRole("heading", { name: "Check your email" })
    ).toBeVisible();
    await expect.poll(() => sessionSignedIn(appWindow)).toBe(false);
    expect(
      stub.requests.filter(
        (request) =>
          request.method === "POST" &&
          request.path === "/v1/comma/me/bootstrap" &&
          request.token === runtimeAccountB.token
      )
    ).toEqual([]);

    await appWindow.getByRole("textbox", { name: /verification code/i }).fill("654321");

    await expect
      .poll(() => stub.googleLinkVerifications)
      .toEqual([
        expect.objectContaining({
          challenge_id: "runtime-google-link-challenge",
          client_kind: "electron",
          client_platform: "macos",
          code: "654321",
        }),
      ]);
    await expect(
      appWindow.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    await expect.poll(() => sessionSignedIn(appWindow)).toBe(true);
    await expect
      .poll(
        () =>
          stub.requests.filter(
            (request) =>
              request.method === "POST" &&
              request.path === "/v1/comma/me/bootstrap" &&
              request.token === runtimeAccountB.token
          ).length
      )
      .toBeGreaterThan(0);

    const rendererVisibleSession = await appWindow.evaluate(async () => {
      const session = await (
        window as unknown as {
          commaNative: { session: { state: { get: () => Promise<unknown> } } };
        }
      ).commaNative.session.state.get();
      const local: Record<string, string | null> = {};
      const temporary: Record<string, string | null> = {};
      for (let index = 0; index < localStorage.length; index += 1) {
        const key = localStorage.key(index);
        if (key) local[key] = localStorage.getItem(key);
      }
      for (let index = 0; index < sessionStorage.length; index += 1) {
        const key = sessionStorage.key(index);
        if (key) temporary[key] = sessionStorage.getItem(key);
      }
      return { local, session, temporary };
    });
    expect(rendererVisibleSession.session).toMatchObject({
      phase: "signed_in",
      principal: { email: runtimeAccountB.email },
    });
    expect(JSON.stringify(rendererVisibleSession)).not.toContain(runtimeAccountB.token);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("local passwordless login keeps the bearer in Main through bootstrap and revocation", async () => {
  test.skip(
    process.env.COMMA_ELECTRON_LOCAL_AUTH_SMOKE !== "1",
    "requires the explicit local Comma backend and Mailpit smoke opt-in"
  );
  test.setTimeout(180_000);

  const apiBaseUrl = normalizedUrl(
    process.env.COMMA_LOCAL_AUTH_API_BASE_URL || "http://127.0.0.1:4200"
  );
  const mailpitBaseUrl = normalizedUrl(
    process.env.COMMA_LOCAL_AUTH_MAILPIT_BASE_URL || "http://127.0.0.1:8025"
  );
  const email = `comma-electron-auth-${Date.now()}-${Math.random()
    .toString(36)
    .slice(2)}@example.com`;

  await requireHealthy(`${apiBaseUrl}/health`, "Comma API");
  await requireHealthy(`${mailpitBaseUrl}/api/v1/messages`, "Mailpit");

  let launched: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;
  let capturedBearer: string | undefined;

  try {
    launched = await launchRuntimeApp({ baseUrl: apiBaseUrl, email });
    const appWindow = await mainProductWindow(launched.app);
    await appWindow.evaluate((nextApiBaseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", nextApiBaseUrl);
    }, apiBaseUrl);
    await appWindow.reload({ waitUntil: "domcontentloaded" });
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();

    await signInWithEmail(appWindow, email, () =>
      waitForMailpitCode(mailpitBaseUrl, email)
    );

    await expect(
      appWindow.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    const signedIn = await sessionState(appWindow);
    expect(signedIn).toMatchObject({ email, signedIn: true });
    capturedBearer = await decryptActiveSessionToken(
      launched.app,
      launched.userDataDir
    );
    expect(await serverSessionStatus(apiBaseUrl, capturedBearer)).toBe(200);

    await expect
      .poll(async () => (await chatState(appWindow)).sessions[0]?.workspaceId)
      .not.toBeUndefined();

    expect(await attemptRendererAuthBypass(appWindow)).toEqual({
      body: { error: "not_found" },
      status: 404,
    });
    expect(await rendererBearerExposure(appWindow)).toEqual({
      dom: false,
      session: false,
      storage: false,
      urls: false,
    });

    await appWindow.reload({ waitUntil: "domcontentloaded" });
    await expect(
      appWindow.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    expect(await sessionState(appWindow)).toMatchObject({
      email,
      signedIn: true,
      userId: signedIn.userId,
    });
    expect(await rendererBearerExposure(appWindow)).toEqual({
      dom: false,
      session: false,
      storage: false,
      urls: false,
    });

    await signOutFromSettings(appWindow);
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    await expect
      .poll(async () => {
        const state = await sessionState(appWindow);
        return {
          revocationPending: state.revocationPending,
          signedIn: state.signedIn,
        };
      })
      .toEqual({ revocationPending: false, signedIn: false });
    expect(await serverSessionStatus(apiBaseUrl, capturedBearer)).toBe(401);
  } finally {
    await launched?.app.close().catch(() => {});
    await bestEffortRevokeServerSession(apiBaseUrl, capturedBearer);
    if (launched) {
      await rm(launched.userDataDir, { force: true, recursive: true });
    }
  }
});

test.describe("real Comma chat streaming smoke", () => {
  test("real provider streams one continuous reply through Electron", async () => {
    test.skip(
      process.env.COMMA_ELECTRON_REAL_CHAT_SMOKE !== "1",
      "requires the explicit real Comma provider and Mailpit smoke opt-in"
    );
    test.setTimeout(300_000);

    const apiBaseUrl = normalizedUrl(
      process.env.COMMA_REAL_CHAT_API_BASE_URL ||
        process.env.COMMA_LOCAL_AUTH_API_BASE_URL ||
        "http://127.0.0.1:4200"
    );
    const mailpitBaseUrl = normalizedUrl(
      process.env.COMMA_REAL_CHAT_MAILPIT_BASE_URL ||
        process.env.COMMA_LOCAL_AUTH_MAILPIT_BASE_URL ||
        "http://127.0.0.1:8025"
    );
    const email = process.env.COMMA_REAL_CHAT_EMAIL || "comma-local@example.com";

    await requireHealthy(`${apiBaseUrl}/health`, "Comma API");
    await requireHealthy(`${mailpitBaseUrl}/api/v1/messages`, "Mailpit");

    let launched: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;
    let appWindow: Page | undefined;
    let capturedBearer: string | undefined;

    try {
      launched = await launchRuntimeApp({ baseUrl: apiBaseUrl, email });
      appWindow = await mainProductWindow(launched.app);
      await appWindow.evaluate((nextApiBaseUrl) => {
        localStorage.setItem("comma.apiBaseUrl", nextApiBaseUrl);
      }, apiBaseUrl);
      await appWindow.reload({ waitUntil: "domcontentloaded" });
      await expect(
        appWindow.getByRole("heading", { name: "Welcome to Comma" })
      ).toBeVisible();

      const loginRequestedAfter = Date.now();
      await signInWithEmail(appWindow, email, () =>
        waitForMailpitCode(mailpitBaseUrl, email, loginRequestedAfter)
      );
      await expect(
        appWindow.getByRole("complementary", { name: "App sidebar" })
      ).toBeVisible();
      capturedBearer = await decryptActiveSessionToken(
        launched.app,
        launched.userDataDir
      );

      await expect
        .poll(async () => {
          const runtime = await chatState(appWindow!);
          return Boolean(
            runtime.sessions[0]?.workspaceId && runtime.sessions[0]?.conversationId
          );
        })
        .toBe(true);

      const content = appWindow.getByRole("region", { name: "Content" });
      const composer = content.getByRole("textbox", { name: "AI prompt" });
      await expect(composer).toBeVisible();
      await appWindow.bringToFront();
      await expect
        .poll(() =>
          appWindow!.evaluate(() => ({
            focused: document.hasFocus(),
            visibility: document.visibilityState,
          }))
        )
        .toEqual({ focused: true, visibility: "visible" });
      await installRealChatStreamProbe(appWindow, await currentProductLease(appWindow));

      await composer.fill(
        "Respond with one Markdown heading, twelve short numbered items, and one concluding sentence. Do not use tools."
      );
      await content.getByRole("button", { name: /^Send(?: message)?$/ }).click();

      await waitForRealChatStreamTerminal(appWindow, 240_000);
      try {
        await expect
          .poll(() => realChatStreamTerminalState(appWindow!), { timeout: 10_000 })
          .toMatchObject({
            activityCollapsed: true,
            activityComplete: true,
            canonicalSeen: true,
            generationFailed: false,
          });
      } catch (error) {
        const diagnostics = await realChatStreamTerminalState(appWindow);
        throw new Error(
          `Real chat activity did not settle: ${JSON.stringify(diagnostics)}`,
          { cause: error }
        );
      }

      const evidence = await finishRealChatStreamProbe(appWindow);
      await test.info().attach("real-chat-stream-metrics.json", {
        body: Buffer.from(JSON.stringify(evidence, null, 2)),
        contentType: "application/json",
      });

      expect(evidence).toMatchObject({
        activityCollapsedSeen: true,
        activityCompleteAtFirstDraftCount: 1,
        activityCompleteSeen: true,
        activityDisconnectedSamples: 0,
        activityEmptyReadableSamples: 0,
        activityIdentityPreserved: true,
        activityThinkingSeen: true,
        activityTransparentSamples: 0,
        activityTypingSeen: false,
        activityZeroAreaSamples: 0,
        articleDisconnectedSamples: 0,
        canonicalSeen: true,
        draftNonPrefixSamples: 0,
        draftTextRegressionSamples: 0,
        emptyReplySamples: 0,
        finalCanonicalVisible: true,
        finalResponseCount: 1,
        generationFailed: false,
        longTaskCount: 0,
        longTaskObserverSupported: true,
        markdownTransparentSamples: 0,
        transparentReplySamples: 0,
        zeroAreaReplySamples: 0,
      });
      expect(evidence.draftStrictGrowthCount).toBeGreaterThanOrEqual(5);
      expect(evidence.commitToNextPaintSamples).toBeGreaterThan(0);
      expect(evidence.maxCommitToNextPaintMs).toBeLessThanOrEqual(100);
      expect(evidence.frameSamples).toBeGreaterThan(0);

      await signOutFromSettings(appWindow);
      await expect(
        appWindow.getByRole("heading", { name: "Welcome to Comma" })
      ).toBeVisible();
    } finally {
      if (appWindow) {
        await discardRealChatStreamProbe(appWindow).catch(() => {});
      }
      await launched?.app.close().catch(() => {});
      await bestEffortRevokeServerSession(apiBaseUrl, capturedBearer);
      if (launched) {
        await rm(launched.userDataDir, { force: true, recursive: true });
      }
    }
  });
});

test("a durable sign-out failure becomes indeterminate until restart follows the durable account", async () => {
  test.skip(process.platform === "win32", "POSIX permissions drive this failure");
  const stub = await startChatRuntimeStub();
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });
  let firstAppClosed = false;
  let permissionsRestricted = false;
  let restarted: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;
  const secureSessionFile = join(launched.userDataDir, "secure-session.bin");

  try {
    const appWindow = await productWindow(launched.app);
    const staleLease = await currentProductLease(appWindow);
    await expect(chatStateForLease(appWindow, staleLease)).resolves.toMatchObject({
      session: staleLease,
    });

    await chmod(secureSessionFile, 0o400);
    await chmod(launched.userDataDir, 0o500);
    permissionsRestricted = true;
    await signOutFromSettings(appWindow);

    await expect
      .poll(() => sessionState(appWindow))
      .toMatchObject({
        phase: "indeterminate",
        principal: null,
        problem: {
          code: "credential_mutation_uncertain",
          operation: "sign_out",
        },
        session: null,
        signedIn: false,
      });
    await expect(
      appWindow.getByRole("heading", { name: "Comma can’t continue" })
    ).toBeVisible();
    await expect(
      appWindow.getByRole("complementary", { name: "App sidebar" })
    ).not.toBeVisible();
    await expect(chatStateForLease(appWindow, staleLease)).rejects.toThrow(
      "Native command Session lease is missing or stale."
    );

    await chmod(launched.userDataDir, 0o700);
    await chmod(secureSessionFile, 0o600);
    permissionsRestricted = false;
    await launched.app.close();
    firstAppClosed = true;

    restarted = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountB.email,
      userDataDir: launched.userDataDir,
    });
    const restartedWindow = await productWindow(restarted.app);
    await expectSignedInShellAs(restartedWindow, runtimeAccountB.email);
    await expect.poll(() => sessionSignedIn(restartedWindow)).toBe(true);
  } finally {
    if (permissionsRestricted) {
      await chmod(launched.userDataDir, 0o700).catch(() => {});
      await chmod(secureSessionFile, 0o600).catch(() => {});
    }
    if (!firstAppClosed) {
      await launched.app.close().catch(() => {});
    }
    await restarted?.app.close().catch(() => {});
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("sign-out cannot resurrect an encrypted session after OS encryption becomes unavailable", async () => {
  const stub = await startChatRuntimeStub();
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });
  let firstAppClosed = false;
  let restarted: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;

  try {
    const appWindow = await productWindow(launched.app);
    await expect.poll(() => sessionSignedIn(appWindow)).toBe(true);
    const secureSessionFile = join(launched.userDataDir, "secure-session.bin");
    await expect.poll(() => fileExists(secureSessionFile)).toBe(true);

    const availability = await launched.app.evaluate(({ safeStorage }) => {
      const before = safeStorage.isEncryptionAvailable();
      Object.defineProperty(safeStorage, "isEncryptionAvailable", {
        configurable: true,
        value: () => false,
      });
      return { after: safeStorage.isEncryptionAvailable(), before };
    });
    expect(availability).toEqual({ after: false, before: true });

    await signOutFromSettings(appWindow);
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    await expect.poll(() => sessionSignedIn(appWindow)).toBe(false);
    await expect.poll(() => fileExists(secureSessionFile)).toBe(false);

    await launched.app.close();
    firstAppClosed = true;
    restarted = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountB.email,
      userDataDir: launched.userDataDir,
    });
    const restartedWindow = await mainProductWindow(restarted.app);
    await expect(
      restartedWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    await expect.poll(() => sessionSignedIn(restartedWindow)).toBe(false);
  } finally {
    if (!firstAppClosed) {
      await launched.app.close().catch(() => {});
    }
    await restarted?.app.close().catch(() => {});
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

for (const existingFile of [false, true]) {
  test(`unavailable OS encryption permits a memory-only login without restoring it after restart (existing file: ${existingFile})`, async () => {
    const stub = await startChatRuntimeStub();
    const launched = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountB.email,
    });
    let firstAppClosed = false;
    let restarted: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;
    const secureSessionFile = join(launched.userDataDir, "secure-session.bin");
    try {
      const appWindow = await mainProductWindow(launched.app);
      await expect(
        appWindow.getByRole("heading", { name: "Welcome to Comma" })
      ).toBeVisible();
      await launched.app.evaluate(({ safeStorage }) => {
        Object.defineProperty(safeStorage, "isEncryptionAvailable", {
          configurable: true,
          value: () => false,
        });
      });
      if (existingFile)
        await writeFile(secureSessionFile, Buffer.from("unreadable previous session"));
      await signInAsAccountB(appWindow);
      await expectSignedInShellAs(appWindow, runtimeAccountB.email);
      expect(await fileExists(secureSessionFile)).toBe(false);
      await appWindow.reload();
      await expectSignedInShellAs(appWindow, runtimeAccountB.email);
      await launched.app.close();
      firstAppClosed = true;
      restarted = await launchRuntimeApp({
        baseUrl: stub.baseUrl,
        email: runtimeAccountB.email,
        userDataDir: launched.userDataDir,
      });
      const restartedWindow = await mainProductWindow(restarted.app);
      await expect(
        restartedWindow.getByRole("heading", { name: "Welcome to Comma" })
      ).toBeVisible();
      expect(await sessionSignedIn(restartedWindow)).toBe(false);
    } finally {
      if (!firstAppClosed) await launched.app.close().catch(() => {});
      await restarted?.app.close().catch(() => {});
      await stub.close();
      await rm(launched.userDataDir, { force: true, recursive: true });
    }
  });
}

test("a legacy envelope remains quarantined when its durable hard cut fails", async () => {
  test.skip(process.platform === "win32", "POSIX permissions drive this failure");
  const stub = await startChatRuntimeStub();
  const secureSessionDir = await mkdtemp(join(tmpdir(), "comma-secure-session-e2e-"));
  const secureSessionFile = join(secureSessionDir, "secure-session.bin");
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    secureSessionFilePath: secureSessionFile,
  });
  let firstAppClosed = false;
  let permissionsRestricted = false;
  let restarted: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;

  try {
    const appWindow = await mainProductWindow(launched.app);
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    const legacyEnvelope = await launched.app.evaluate(
      ({ safeStorage }, envelope) =>
        safeStorage.encryptString(JSON.stringify(envelope)).toString("base64"),
      {
        apiBaseUrl: stub.baseUrl,
        email: runtimeAccountA.email,
        token: runtimeAccountA.token,
        userId: "usr_runtime_a",
      }
    );
    await launched.app.close();
    firstAppClosed = true;
    await writeFile(secureSessionFile, Buffer.from(legacyEnvelope, "base64"));
    const bytesBeforeLogin = await readFile(secureSessionFile);
    await chmod(secureSessionFile, 0o400);
    await chmod(secureSessionDir, 0o500);
    permissionsRestricted = true;

    restarted = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountB.email,
      googleIdToken: "runtime-google-id-token",
      secureSessionFilePath: secureSessionFile,
      userDataDir: launched.userDataDir,
    });
    const restartedWindow = await mainProductWindow(restarted.app);
    await expect(
      restartedWindow.getByRole("heading", { name: "Comma can’t continue" })
    ).toBeVisible();
    expect(await sessionState(restartedWindow)).toMatchObject({
      cleanup: { revocation: "unknown" },
      phase: "indeterminate",
      principal: null,
      problem: { code: "credential_store_unreadable" },
      session: null,
      signedIn: false,
    });
    await expect(
      restartedWindow.getByRole("button", { name: "Sign in with Google" })
    ).not.toBeVisible();
    await expect(
      restartedWindow.getByRole("textbox", { name: "Email" })
    ).not.toBeVisible();
    expect(stub.googleAttempts).toEqual([]);
    expect(await readFile(secureSessionFile)).toEqual(bytesBeforeLogin);
  } finally {
    if (permissionsRestricted) {
      await chmod(secureSessionDir, 0o700).catch(() => {});
      await chmod(secureSessionFile, 0o600).catch(() => {});
    }
    if (!firstAppClosed) {
      await launched.app.close().catch(() => {});
    }
    await restarted?.app.close().catch(() => {});
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
    await rm(secureSessionDir, { force: true, recursive: true });
  }
});

test("a terminal 401 retry remains queued until a writable startup persists cleanup", async () => {
  test.skip(process.platform === "win32", "POSIX permissions drive this failure");
  const stub = await startChatRuntimeStub();
  const secureSessionDir = await mkdtemp(join(tmpdir(), "comma-secure-session-e2e-"));
  const secureSessionFile = join(secureSessionDir, "secure-session.bin");
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    secureSessionFilePath: secureSessionFile,
  });
  let firstAppClosed = false;
  let permissionsRestricted = false;
  let restarted: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;
  let recovered: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;

  try {
    const appWindow = await mainProductWindow(launched.app);
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    const pendingEnvelope = await launched.app.evaluate(
      ({ safeStorage }, envelope) =>
        safeStorage.encryptString(JSON.stringify(envelope)).toString("base64"),
      {
        pendingRevocations: [
          { audience: stub.baseUrl, token: "already-revoked-runtime-token" },
        ],
        vaultRevision: 1,
        version: 3,
      }
    );
    await launched.app.close();
    firstAppClosed = true;
    await writeFile(secureSessionFile, Buffer.from(pendingEnvelope, "base64"));
    const bytesBeforeRetry = await readFile(secureSessionFile);
    await chmod(secureSessionFile, 0o400);
    await chmod(secureSessionDir, 0o500);
    permissionsRestricted = true;

    restarted = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountB.email,
      secureSessionFilePath: secureSessionFile,
      userDataDir: launched.userDataDir,
    });
    const restartedWindow = await mainProductWindow(restarted.app);
    await expect(
      restartedWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    const firstChallenge = await requestEmailLoginThroughNative(
      restartedWindow,
      runtimeAccountB.email
    );
    expect(firstChallenge).toMatchObject({
      challengeId: "runtime-challenge-b",
      attempt: {
        attemptId: expect.any(String),
        expected: firstChallenge.expected,
      },
    });
    expect(await sessionState(restartedWindow)).toMatchObject({
      revocationPending: true,
      signedIn: false,
    });
    expect(await readFile(secureSessionFile)).toEqual(bytesBeforeRetry);
    const retriesWhilePersistenceBlocked = stub.requests.filter(
      (request) =>
        request.method === "POST" &&
        request.path === "/v1/comma/auth/logout" &&
        request.token === "already-revoked-runtime-token"
    );
    expect(retriesWhilePersistenceBlocked.length).toBeGreaterThanOrEqual(1);

    await chmod(secureSessionDir, 0o700);
    await chmod(secureSessionFile, 0o600);
    permissionsRestricted = false;

    await restarted.app.close();
    restarted = undefined;
    recovered = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountB.email,
      secureSessionFilePath: secureSessionFile,
      userDataDir: launched.userDataDir,
    });
    const recoveredWindow = await mainProductWindow(recovered.app);
    await expect(
      recoveredWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    await expect
      .poll(async () => {
        const state = await sessionState(recoveredWindow);
        return {
          revocationPending: state.revocationPending,
          signedIn: state.signedIn,
        };
      })
      .toEqual({ revocationPending: false, signedIn: false });
    const cleanedEnvelopeBytes = await readFile(secureSessionFile);
    expect(cleanedEnvelopeBytes).not.toEqual(bytesBeforeRetry);
    const cleanedEnvelope = await recovered.app.evaluate(
      ({ safeStorage }, encoded) =>
        JSON.parse(
          safeStorage.decryptString(globalThis.Buffer.from(encoded, "base64"))
        ) as unknown,
      cleanedEnvelopeBytes.toString("base64")
    );
    expect(cleanedEnvelope).toMatchObject({
      pendingRevocations: [],
      vaultRevision: expect.any(Number),
      version: 3,
    });
    expect(JSON.stringify(cleanedEnvelope)).not.toContain(
      "already-revoked-runtime-token"
    );

    const replacementChallenge = await requestEmailLoginThroughNative(
      recoveredWindow,
      runtimeAccountB.email
    );
    expect(replacementChallenge).toMatchObject({
      challengeId: "runtime-challenge-b",
      attempt: {
        attemptId: expect.any(String),
        expected: replacementChallenge.expected,
      },
      expected: replacementChallenge.expected,
    });
    const completedRetries = stub.requests.filter(
      (request) =>
        request.method === "POST" &&
        request.path === "/v1/comma/auth/logout" &&
        request.token === "already-revoked-runtime-token"
    );
    expect(completedRetries).toHaveLength(retriesWhilePersistenceBlocked.length + 1);
  } finally {
    if (permissionsRestricted) {
      await chmod(secureSessionDir, 0o700).catch(() => {});
      await chmod(secureSessionFile, 0o600).catch(() => {});
    }
    if (!firstAppClosed) {
      await launched.app.close().catch(() => {});
    }
    await restarted?.app.close().catch(() => {});
    await recovered?.app.close().catch(() => {});
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
    await rm(secureSessionDir, { force: true, recursive: true });
  }
});

test("a hung server revocation is bounded before the next renderer login challenge", async () => {
  const hangingToken = "hanging-runtime-revocation";
  const stub = await startChatRuntimeStub({
    hangLogoutTokens: [hangingToken],
  });
  const secureSessionDir = await mkdtemp(join(tmpdir(), "comma-secure-session-e2e-"));
  const secureSessionFile = join(secureSessionDir, "secure-session.bin");
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    secureSessionFilePath: secureSessionFile,
  });
  let firstAppClosed = false;
  let restarted: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;

  try {
    const appWindow = await mainProductWindow(launched.app);
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    const pendingEnvelope = await launched.app.evaluate(
      ({ safeStorage }, envelope) =>
        safeStorage.encryptString(JSON.stringify(envelope)).toString("base64"),
      {
        pendingRevocations: [{ audience: stub.baseUrl, token: hangingToken }],
        vaultRevision: 1,
        version: 3,
      }
    );
    await launched.app.close();
    firstAppClosed = true;
    await writeFile(secureSessionFile, Buffer.from(pendingEnvelope, "base64"));
    const bytesBeforeRetry = await readFile(secureSessionFile);

    restarted = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountB.email,
      secureSessionFilePath: secureSessionFile,
      userDataDir: launched.userDataDir,
    });
    const restartedWindow = await mainProductWindow(restarted.app);
    await expect(
      restartedWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();

    const login = requestEmailLoginThroughNative(
      restartedWindow,
      runtimeAccountB.email
    );

    await expect
      .poll(() =>
        stub.requests.some(
          (request) =>
            request.method === "POST" &&
            request.path === "/v1/comma/auth/logout" &&
            request.token === hangingToken
        )
      )
      .toBe(true);
    const challenge = await login;
    expect(challenge).toMatchObject({
      challengeId: "runtime-challenge-b",
      attempt: {
        attemptId: expect.any(String),
        expected: challenge.expected,
      },
    });

    const logoutIndex = stub.requests.findIndex(
      (request) =>
        request.method === "POST" &&
        request.path === "/v1/comma/auth/logout" &&
        request.token === hangingToken
    );
    const loginIndex = stub.requests.findIndex(
      (request) =>
        request.method === "POST" && request.path === "/v1/comma/auth/email/login"
    );
    expect(logoutIndex).toBeGreaterThanOrEqual(0);
    expect(loginIndex).toBeGreaterThan(logoutIndex);
    expect(await sessionState(restartedWindow)).toMatchObject({
      revocationPending: true,
      signedIn: false,
    });
    expect(await readFile(secureSessionFile)).toEqual(bytesBeforeRetry);
  } finally {
    if (!firstAppClosed) {
      await launched.app.close().catch(() => {});
    }
    await restarted?.app.close().catch(() => {});
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
    await rm(secureSessionDir, { force: true, recursive: true });
  }
});

for (const cleanupFails of [false, true]) {
  test(`switching backend permits login in the same profile (cleanup failure: ${cleanupFails})`, async () => {
    test.skip(
      cleanupFails && process.platform === "win32",
      "POSIX permissions drive the cleanup failure"
    );
    const secureSessionDir = await mkdtemp(
      join(tmpdir(), "comma-environment-credentials-")
    );
    const secureSessionFile = join(secureSessionDir, "secure-session.bin");
    const oldBackend = await startChatRuntimeStub();
    const newBackend = await startChatRuntimeStub();
    const launched = await launchRuntimeApp({
      baseUrl: oldBackend.baseUrl,
      email: runtimeAccountA.email,
      token: runtimeAccountA.token,
      secureSessionFilePath: secureSessionFile,
    });
    let firstAppClosed = false;
    let restarted: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;
    const unrelatedFile = join(launched.userDataDir, "keep-local-data.txt");
    try {
      const firstWindow = await productWindow(launched.app);
      await expectSignedInShellAs(firstWindow, runtimeAccountA.email);
      await writeFile(unrelatedFile, "preserve local data");
      await launched.app.close();
      firstAppClosed = true;
      const oldRequests = oldBackend.requests.length;
      if (cleanupFails) await chmod(secureSessionDir, 0o500);

      restarted = await launchRuntimeApp({
        baseUrl: newBackend.baseUrl,
        email: runtimeAccountB.email,
        userDataDir: launched.userDataDir,
        secureSessionFilePath: secureSessionFile,
      });
      const window = await mainProductWindow(restarted.app);
      if (cleanupFails) {
        await expect(
          window.getByRole("heading", { name: "Comma can’t continue" })
        ).toBeVisible();
        expect(await sessionState(window)).toMatchObject({
          problem: { code: "credential_mutation_uncertain" },
        });
        expect(newBackend.requests).toEqual([]);
        await chmod(secureSessionDir, 0o700);
        await window.getByRole("button", { name: "Try again" }).click();
      }
      await expect(
        window.getByRole("heading", { name: "Welcome to Comma" })
      ).toBeVisible();
      const envelope = await decryptSessionEnvelope(restarted.app, secureSessionFile);
      expect(envelope).not.toHaveProperty("active");
      expect(envelope.pendingRevocations).toEqual([]);
      expect(newBackend.requests).toEqual([]);
      expect(oldBackend.requests).toHaveLength(oldRequests);
      expect(await readFile(unrelatedFile, "utf8")).toBe("preserve local data");

      await signInAsAccountB(window);
      await expectSignedInShellAs(window, runtimeAccountB.email);
      expect(await sessionState(window)).toMatchObject({
        session: { audience: newBackend.baseUrl },
        signedIn: true,
      });
      expect(
        newBackend.requests.some((request) => request.token === runtimeAccountA.token)
      ).toBe(false);
      expect(oldBackend.requests).toHaveLength(oldRequests);
    } finally {
      await chmod(secureSessionDir, 0o700).catch(() => {});
      if (!firstAppClosed) await launched.app.close().catch(() => {});
      await restarted?.app.close().catch(() => {});
      await oldBackend.close();
      await newBackend.close();
      await rm(launched.userDataDir, { force: true, recursive: true });
      await rm(secureSessionDir, { force: true, recursive: true });
    }
  });
}

test("an unreadable encrypted envelope is removed before a new login", async () => {
  const stub = await startChatRuntimeStub();
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountA.email,
    token: runtimeAccountA.token,
  });
  let firstAppClosed = false;
  let restarted: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;
  const secureSessionFile = join(launched.userDataDir, "secure-session.bin");

  try {
    await expect.poll(() => fileExists(secureSessionFile)).toBe(true);
    const unreadableEnvelope = await launched.app.evaluate(
      ({ safeStorage }, envelope) =>
        safeStorage.encryptString(JSON.stringify(envelope)).toString("base64"),
      {
        active: {
          audience: stub.baseUrl,
          email: runtimeAccountA.email,
          token: runtimeAccountA.token,
          userId: "usr_runtime_a",
        },
        pendingRevocations: [
          { audience: stub.baseUrl, token: "pending-revocation" },
          { audience: "", token: "invalid-revocation" },
        ],
        vaultRevision: 1,
        version: 3,
      }
    );

    await launched.app.close();
    firstAppClosed = true;
    await writeFile(secureSessionFile, Buffer.from(unreadableEnvelope, "base64"));

    restarted = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountB.email,
      googleIdToken: "runtime-google-id-token",
      userDataDir: launched.userDataDir,
    });
    const restartedWindow = await mainProductWindow(restarted.app);
    await expect(
      restartedWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    expect(await sessionSignedIn(restartedWindow)).toBe(false);
    expect(await fileExists(secureSessionFile)).toBe(false);
    expect(stub.googleAttempts).toEqual([]);
    await signInAsAccountB(restartedWindow);
    await expectSignedInShellAs(restartedWindow, runtimeAccountB.email);
    expect(await fileExists(secureSessionFile)).toBe(true);
  } finally {
    if (!firstAppClosed) {
      await launched.app.close().catch(() => {});
    }
    await restarted?.app.close().catch(() => {});
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

let chatRuntimeFixtureBuild: Promise<void> | undefined;

function ensureChatRuntimeFixtureBuilt() {
  chatRuntimeFixtureBuild ??= build({
    base: "./",
    build: {
      emptyOutDir: false,
      outDir: rendererOutDir,
      rolldownOptions: {
        input: resolve(fixtureRoot, "chat-runtime-fixture.html"),
      },
    },
    configFile: false,
    define: {
      "process.env.NODE_ENV": JSON.stringify("test"),
    },
    logLevel: "error",
    resolve: {
      alias: {
        "@comma/chat-contract": resolve(
          clientsRoot,
          "packages/chat-contract/src/index.ts"
        ),
        "@comma/native-bridge": resolve(
          clientsRoot,
          "packages/native-bridge/src/index.ts"
        ),
      },
    },
    root: fixtureRoot,
  }).then(() => undefined);
  return chatRuntimeFixtureBuild;
}

for (const endpoint of ["bootstrap", "ensure"] as const) {
  for (const failureStatus of [401, 403, 404] as const) {
    test(`current ${endpoint} ${failureStatus} ${
      failureStatus === 401 ? "signs out" : "does not sign out"
    } the active Electron session`, async () => {
      const observeSideChatInvalidation =
        endpoint === "ensure" && failureStatus === 401 && process.platform === "darwin";
      const stub = await startChatRuntimeStub(
        endpoint === "bootstrap"
          ? { bootstrapFailureStatus: failureStatus }
          : observeSideChatInvalidation
            ? { deferAccountBResolution: true }
            : { ensureFailureStatus: failureStatus }
      );
      const launched = await launchRuntimeApp({
        baseUrl: stub.baseUrl,
        email: runtimeAccountB.email,
        token: runtimeAccountB.token,
      });

      try {
        const appWindow = await mainProductWindow(launched.app);
        const sideChatRendererFailures: string[] = [];
        const sideChatWindow = observeSideChatInvalidation
          ? await findElectronWindowByNativeRole(launched.app, "side-chat-window")
          : undefined;
        if (sideChatWindow) {
          await sideChatWindow.waitForLoadState("domcontentloaded");
          sideChatWindow.on("console", (message) => {
            if (message.type() === "error") {
              sideChatRendererFailures.push(message.text());
            }
          });
          sideChatWindow.on("pageerror", (error) => {
            sideChatRendererFailures.push(error.message);
          });
          await stub.bResolutionStarted;
          stub.settleBResolution(401);
        }
        const requestPath =
          endpoint === "bootstrap"
            ? "/v1/comma/me/bootstrap"
            : `/v1/comma/groups/${runtimeAccountB.groupId}/assistant-chat`;
        await expect
          .poll(
            () =>
              stub.requests.filter(
                (request) =>
                  request.method === "POST" &&
                  request.path === requestPath &&
                  request.token === runtimeAccountB.token
              ).length
          )
          .toBeGreaterThan(0);
        await settleRendererWork(appWindow);

        if (failureStatus === 401) {
          await expect.poll(() => sessionSignedIn(appWindow)).toBe(false);
          await expect(
            appWindow.getByRole("heading", { name: "Welcome to Comma" })
          ).toBeVisible();
          if (sideChatWindow) {
            await settleRendererWork(sideChatWindow);
            expect(
              sideChatRendererFailures.filter((message) =>
                /session(?:\.|:|-).*sign.?out|forbidden|unhandled/i.test(message)
              )
            ).toEqual([]);
          }
        } else {
          expect(await sessionState(appWindow)).toMatchObject({
            apiBaseUrl: stub.baseUrl,
            email: runtimeAccountB.email,
            signedIn: true,
          });
          await expect(
            appWindow.getByRole("heading", { name: "Welcome to Comma" })
          ).not.toBeVisible();
        }
      } finally {
        await launched.app.close();
        await stub.close();
        await rm(launched.userDataDir, { force: true, recursive: true });
      }
    });
  }
}

test("an assets response body admitted for A cannot settle into the renderer after B becomes current", async () => {
  const stub = await startChatRuntimeStub();
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountA.email,
    token: runtimeAccountA.token,
  });

  try {
    const appWindow = await productWindow(launched.app);
    await appWindow.evaluate(async () => {
      const lifecycle = await (
        window as unknown as {
          commaNative: { session: SessionBridge };
        }
      ).commaNative.session.state.get();
      if (lifecycle.phase !== "signed_in") {
        throw new Error("The delayed request requires account A.");
      }
      const scope = window as unknown as {
        commaDelayedAccountABody?: {
          headersReceived: boolean;
          outcome:
            | { kind: "pending" }
            | { body: unknown; kind: "delivered" }
            | { kind: "rejected"; message: string };
        };
      };
      const record: NonNullable<typeof scope.commaDelayedAccountABody> = {
        headersReceived: false,
        outcome: { kind: "pending" as const },
      };
      scope.commaDelayedAccountABody = record;
      const expected = JSON.stringify({
        authorityInstanceId: lifecycle.authority.authorityInstanceId,
        expectedAudience: lifecycle.session.audience,
        expectedSessionId: lifecycle.session.sessionId,
        generation: lifecycle.generation,
      });
      void fetch("assets://./v1/e2e/delayed-body", {
        headers: {
          "x-comma-main-session-expectation": expected,
        },
      })
        .then(async (response) => {
          record.headersReceived = true;
          const body: unknown = await response.json();
          record.outcome = { body, kind: "delivered" };
        })
        .catch((error: unknown) => {
          record.outcome = {
            kind: "rejected",
            message: error instanceof Error ? error.message : String(error),
          };
        });
    });

    await stub.accountABodyHeadersSent;
    await expect
      .poll(() =>
        appWindow.evaluate(
          () =>
            (
              window as unknown as {
                commaDelayedAccountABody?: { headersReceived: boolean };
              }
            ).commaDelayedAccountABody?.headersReceived
        )
      )
      .toBe(true);

    await signOutFromSettings(appWindow);
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    await signInAsAccountB(appWindow);
    await expectSignedInShellAs(appWindow, runtimeAccountB.email);
    expect(await sessionState(appWindow)).toMatchObject({
      email: runtimeAccountB.email,
      signedIn: true,
    });

    stub.settleAccountADelayedBody();
    await expect
      .poll(() =>
        appWindow.evaluate(
          () =>
            (
              window as unknown as {
                commaDelayedAccountABody?: {
                  outcome: { body?: unknown; kind: string; message?: string };
                };
              }
            ).commaDelayedAccountABody?.outcome
        )
      )
      .toMatchObject({ kind: "rejected" });
    const rendererOutcome = await appWindow.evaluate(
      () =>
        (
          window as unknown as {
            commaDelayedAccountABody?: {
              outcome: { body?: unknown; kind: string; message?: string };
            };
          }
        ).commaDelayedAccountABody?.outcome
    );
    expect(JSON.stringify(rendererOutcome)).not.toContain("account-a-delayed-body");
    expect(await sessionState(appWindow)).toMatchObject({
      email: runtimeAccountB.email,
      signedIn: true,
    });
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("blocked Electron quit reports cleanup failure and releases the process", async () => {
  const stub = await startChatRuntimeStub();
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });
  const child = launched.app.process();
  let watchdog: ReturnType<typeof setTimeout> | undefined;
  try {
    await launched.app.evaluate(({ app }) => {
      app.on("before-quit", (event) => event.preventDefault());
    });
    const result = await Promise.race([
      closeElectronTestApp(launched.app, 500).then(
        () => "unexpected success",
        (error: unknown) => (error instanceof Error ? error.message : String(error))
      ),
      new Promise<string>((finish) => {
        watchdog = setTimeout(() => finish("cleanup remained pending"), 5_000);
      }),
    ]);
    expect(result).toContain("Electron test app did not exit within 500ms");
    expect(child.exitCode !== null || child.signalCode !== null).toBe(true);
  } finally {
    clearTimeout(watchdog);
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

for (const outcome of [
  "success",
  "unauthorized",
  "forbidden",
  "not_found",
  "error",
] as const) {
  test(`account A late ${outcome} resolution cannot re-enter account B runtime`, async () => {
    const stub = await startChatRuntimeStub();
    const launched = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountA.email,
      token: runtimeAccountA.token,
    });

    try {
      const appWindow = await productWindow(launched.app);
      const content = appWindow.getByRole("region", { name: "Content" });
      const startupComposer = content.getByRole("textbox", { name: "AI prompt" });
      await expect(startupComposer).toBeVisible();
      await startupComposer.fill(`Account A startup ${outcome}`);
      await content.getByRole("button", { name: "Send", exact: true }).click();
      await stub.aResolutionStarted;

      await signOutFromSettings(appWindow);
      await expect(
        appWindow.getByRole("heading", { name: "Welcome to Comma" })
      ).toBeVisible();
      await expect.poll(() => sessionSignedIn(appWindow)).toBe(false);

      await signInAsAccountB(appWindow);
      await expectSignedInShellAs(appWindow, runtimeAccountB.email);
      await expect(content.locator('input[type="file"]')).toBeAttached();

      stub.settleAResolution(outcome satisfies LateResolutionOutcome);
      await settleRendererWork(appWindow);
      expect(await sessionState(appWindow)).toMatchObject({
        apiBaseUrl: stub.baseUrl,
        email: runtimeAccountB.email,
        signedIn: true,
      });

      const accountBPrompt = `Account B remains writable after A ${outcome}`;
      const accountBComposer = content.getByRole("textbox", { name: "AI prompt" });
      await accountBComposer.fill(accountBPrompt);
      await accountBComposer.press("Enter");

      await expect
        .poll(
          () =>
            stub.messageAttempts.filter(
              (attempt) => attempt.token === runtimeAccountB.token
            ).length
        )
        .toBe(1);
      expect(
        stub.messageAttempts.filter(
          (attempt) => attempt.token === runtimeAccountA.token
        )
      ).toEqual([]);
      expect(
        stub.requests.filter((request) =>
          request.path.includes(`/conversations/${runtimeAccountA.conversationId}`)
        )
      ).toEqual([]);

      const state = await chatState(appWindow);
      expect(state.sessions.map((session) => session.key)).toEqual([
        `${runtimeAccountB.groupId}/${runtimeAccountB.conversationId}`,
      ]);
      expect(state.sessions[0]).toMatchObject({
        conversationId: runtimeAccountB.conversationId,
        groupId: runtimeAccountB.groupId,
        workspaceId: runtimeAccountB.workspaceId,
      });
    } finally {
      try {
        await test.step("close the account-switch Electron process", () =>
          closeElectronTestApp(launched.app));
      } finally {
        await stub.close();
        await rm(launched.userDataDir, { force: true, recursive: true });
      }
    }
  });
}

test("account replacement revokes account A in every product window", async () => {
  const stub = await startChatRuntimeStub();
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountA.email,
    token: runtimeAccountA.token,
  });

  try {
    const firstWindow = await productWindow(launched.app);
    const secondWindow = await openSecondProductWindow(launched.app, firstWindow);
    const secondContent = secondWindow.getByRole("region", { name: "Content" });
    await expectSignedInShellAs(firstWindow, runtimeAccountA.email);
    await expectSignedInShellAs(secondWindow, runtimeAccountA.email);

    const accountAStartup = "Account A second-window startup";
    const secondStartupComposer = secondContent.getByRole("textbox", {
      name: "AI prompt",
    });
    await secondStartupComposer.fill(accountAStartup);
    await secondContent.getByRole("button", { name: "Send", exact: true }).click();
    await stub.aResolutionStarted;
    stub.settleAResolution("success");

    await expect
      .poll(
        () =>
          stub.messageAttempts.filter(
            (attempt) => attempt.token === runtimeAccountA.token
          ).length
      )
      .toBe(1);
    await expect(secondContent.locator('input[type="file"]')).toBeAttached();

    const accountAPrivateDraft = "Account A private draft must be revoked";
    await secondContent
      .getByRole("textbox", { name: "AI prompt" })
      .fill(accountAPrivateDraft);

    await signOutFromSettings(firstWindow);
    await expect(
      firstWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    await expect.poll(() => sessionSignedIn(firstWindow)).toBe(false);

    // Main broadcasts the signed-out snapshot to every product renderer. The
    // second window must revoke A before it can issue another bridge command.
    await expect(
      secondWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();

    await signInAsAccountB(firstWindow);
    await expectSignedInShellAs(firstWindow, runtimeAccountB.email);
    await expectSignedInShellAs(secondWindow, runtimeAccountB.email);
    await expect.poll(() => sessionSignedIn(secondWindow)).toBe(true);

    const accountBPrompt = "Account B remains writable in the second window";
    const accountBComposer = secondContent.getByRole("textbox", {
      name: "AI prompt",
    });
    await expectRichComposerEmpty(accountBComposer);
    await accountBComposer.fill(accountBPrompt);
    await accountBComposer.press("Enter");

    await expect
      .poll(
        () =>
          stub.messageAttempts.filter(
            (attempt) => attempt.token === runtimeAccountB.token
          ).length
      )
      .toBe(1);
    expect(
      stub.requests.filter(
        (request) =>
          request.token === runtimeAccountB.token &&
          request.path.includes(`/conversations/${runtimeAccountA.conversationId}`)
      )
    ).toEqual([]);
    expect(
      stub.messageAttempts.some((attempt) =>
        attempt.body.message?.text?.includes(accountAPrivateDraft)
      )
    ).toBe(false);

    const state = await chatState(secondWindow);
    expect(state.sessions.map((session) => session.key)).toEqual([
      `${runtimeAccountB.groupId}/${runtimeAccountB.conversationId}`,
    ]);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

for (const status of [500, 402] as const) {
  test(`Main preserves one retryable send after a real ${status}`, async () => {
    const stub = await startChatRuntimeStub({
      deferAccountBResolution: true,
      messageFailureStatus: status,
    });
    const launched = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountB.email,
      token: runtimeAccountB.token,
    });

    try {
      const appWindow = await productWindow(launched.app);
      const content = appWindow.getByRole("region", { name: "Content" });
      const composer = content.getByRole("textbox", { name: "AI prompt" });
      const prompt = `Runtime ${status} failed send`;
      await expect(composer).toBeVisible();
      await expect(content.locator('input[type="file"]')).toHaveCount(0);
      await composer.fill(prompt);
      await content.getByRole("button", { name: "Send", exact: true }).click();
      await stub.bResolutionStarted;
      await expect(composer).toBeDisabled();
      await expect(composer).toHaveText("");
      stub.settleBResolution();

      const failedRow = content.getByTestId("chat-failed-row");
      await expect(failedRow).toHaveCount(1);
      if (status === 402) {
        await expect(failedRow).toContainText(
          "Send failed · Billing is temporarily unavailable. Try again later."
        );
        await expect(failedRow).not.toContainText("billing_unavailable");
      } else {
        await expect(failedRow).toContainText("Send failed");
        await expect(failedRow).not.toContainText("runtime_message_500");
      }
      await expect(failedRow.getByRole("button", { name: "Retry" })).toBeVisible();

      await failedRow.getByRole("button", { name: "Retry" }).click();
      await expect.poll(() => stub.messageAttempts.length).toBe(2);
      expect(stub.messageAttempts[0]?.body.client_request_id).toBeTruthy();
      expect(stub.messageAttempts[1]?.body.client_request_id).toBe(
        stub.messageAttempts[0]?.body.client_request_id
      );
    } finally {
      await launched.app.close();
      await stub.close();
      await rm(launched.userDataDir, { force: true, recursive: true });
    }
  });
}

test("a send refused for insufficient credits shows the out-of-credits card and retries", async () => {
  const stub = await startChatRuntimeStub({
    messageFailureReason: "insufficient_credits",
    messageFailureStatuses: [402],
  });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });

  try {
    const appWindow = await productWindow(launched.app);
    const content = appWindow.getByRole("region", { name: "Content" });
    const composer = content.getByRole("textbox", { name: "AI prompt" });
    await composer.fill("Send this once credits are back");
    await content.getByRole("button", { name: "Send", exact: true }).click();

    const card = content.getByTestId("chat-out-of-credits");
    await expect(card).toHaveCount(1);
    await expect(card).toContainText("Out of usage credits");
    await expect(card).not.toContainText("insufficient_credits");
    await expect(content.getByTestId("chat-failed-row")).toHaveCount(0);

    await card.getByRole("button", { name: "Retry" }).click();
    await expect.poll(() => stub.messageAttempts.length).toBe(2);
    expect(stub.messageAttempts[1]?.body.client_request_id).toBe(
      stub.messageAttempts[0]?.body.client_request_id
    );
    await expect(card).toHaveCount(0);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("a new Electron send shows Thinking beside an older failed turn", async () => {
  const stub = await startChatRuntimeStub({
    deferAccountBMessages: true,
    messageFailureStatuses: [500],
  });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });

  try {
    const appWindow = await productWindow(launched.app);
    const content = appWindow.getByRole("region", { name: "Content" });
    const composer = content.getByRole("textbox", { name: "AI prompt" });

    await composer.fill("Keep this failed turn for retry");
    await content.getByRole("button", { name: "Send", exact: true }).click();
    await expect(content.getByTestId("chat-failed-row")).toHaveCount(1);

    await composer.fill("Start a clean successor turn");
    await content.getByRole("button", { name: "Send message", exact: true }).click();
    await expect.poll(() => stub.messageAttempts.length).toBe(2);
    await expect(
      content.getByText("Start a clean successor turn", { exact: true })
    ).toBeVisible();

    const participantStatus = content.getByTestId("participant-status-slot");
    await expect(participantStatus).toHaveAttribute("data-state", "active");
    await expect(participantStatus).toHaveAttribute("data-active", "true");
    await expect(participantStatus).toContainText("Thinking");
    await expect(content.getByTestId("chat-assistant-draft")).toHaveCount(0);

    stub.settleNextAccountBMessage();
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("an active participant still sends the next Electron message directly", async () => {
  const stub = await startChatRuntimeStub({ controlledAccountBEvents: true });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });
  const activeSource = runtimeMessage(
    "runtime-direct-send-active-source",
    "user",
    "Keep working while I send another message"
  );

  try {
    const appWindow = await productWindow(launched.app);
    const content = appWindow.getByRole("region", { name: "Content" });
    const composer = content.getByRole("textbox", { name: "AI prompt" });
    await expect(composer).toBeVisible();
    await expect.poll(() => stub.accountBEventClientCount).toBe(1);

    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      messages: [activeSource],
      status: "open",
      type: "snapshot",
      group_id: runtimeAccountB.groupId,
    });
    stub.emitAccountBEvent("participant_status", {
      conversation_id: runtimeAccountB.conversationId,
      participant_id: "runtime-router-participant",
      state: "active",
      status: "is executing a tool...",
      type: "participant_status",
      updated_at: 1,
    });
    const participantStatus = content.getByTestId("participant-status-slot");
    await expect(participantStatus).toHaveAttribute("data-active", "true");
    await expect(participantStatus).toContainText("Thinking");

    const nextMessage = "Send while the participant is active";
    await composer.fill(nextMessage);
    await content.getByRole("button", { name: "Send message", exact: true }).click();

    await expect.poll(() => stub.messageAttempts.length).toBe(1);
    expect(stub.messageAttempts[0]?.body.message?.text).toBe(nextMessage);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("Participant status resubscribes and reaches stopped after reconnect", async () => {
  const stub = await startChatRuntimeStub({ controlledAccountBEvents: true });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });
  const source = runtimeMessage(
    "runtime-reconnect-baseline-source",
    "user",
    "Reconnect the Participant status"
  );
  const participantId = "runtime-reconnect-participant";

  try {
    const appWindow = await productWindow(launched.app);
    const content = appWindow.getByRole("region", { name: "Content" });
    await expect(content.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
    await expect.poll(() => stub.accountBEventClientCount).toBe(1);

    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      messages: [source],
      status: "open",
      type: "snapshot",
      group_id: runtimeAccountB.groupId,
    });
    stub.emitAccountBEvent("participant_status", {
      conversation_id: runtimeAccountB.conversationId,
      participant_id: participantId,
      state: "active",
      status: "is thinking before reconnect...",
      type: "participant_status",
      updated_at: 1,
    });

    const participantStatus = content.getByTestId("participant-status-slot");
    await expect(participantStatus).toHaveAttribute("data-state", "active");
    await expect(participantStatus).toContainText("Thinking");

    const firstStreamCount = stub.accountBEventStreamCount;
    stub.disconnectAccountBEvents();
    await expect
      .poll(() => stub.accountBEventStreamCount, { timeout: 15_000 })
      .toBeGreaterThan(firstStreamCount);
    await expect.poll(() => stub.accountBEventClientCount).toBe(1);

    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      messages: [source],
      status: "open",
      type: "snapshot",
      group_id: runtimeAccountB.groupId,
    });
    stub.emitAccountBEvent("participant_status", {
      conversation_id: runtimeAccountB.conversationId,
      participant_id: participantId,
      state: "active",
      status: "is executing after reconnect...",
      type: "participant_status",
      updated_at: 2,
    });
    await expect(participantStatus).toContainText("Thinking");

    stub.emitAccountBEvent("participant_status", {
      conversation_id: runtimeAccountB.conversationId,
      participant_id: participantId,
      state: "stopped",
      status: "",
      type: "participant_status",
      updated_at: 3,
    });
    await expect(participantStatus).toHaveAttribute("data-state", "stopped");
    await expect(participantStatus).toHaveAttribute("data-active", "false");
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("Participant draft survives a mismatched cancel and settles into the next Message", async () => {
  const stub = await startChatRuntimeStub({ controlledAccountBEvents: true });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });
  const responseKey = "runtime-response-transient";
  const participantId = "runtime-visible-reply-participant";
  const sourceOne = runtimeMessage(
    "runtime-visible-source-1",
    "user",
    "First exact source"
  );
  const sourceTwo = runtimeMessage(
    "runtime-visible-source-2",
    "user",
    "Second exact source"
  );
  const sourceIds = [sourceOne.message_id, sourceTwo.message_id];
  const wrongSourceIds = [sourceTwo.message_id, sourceOne.message_id];
  const unrelatedAssistant = runtimeMessage(
    "runtime-unrelated-assistant",
    "assistant",
    "Ordinary unrelated assistant"
  );
  const finalAssistant = runtimeMessage(
    "runtime-final-assistant",
    "assistant",
    "Canonical transcript answer"
  );

  try {
    const appWindow = await productWindow(launched.app);
    const content = appWindow.getByRole("region", { name: "Content" });
    await expect(content.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
    await expect.poll(() => stub.accountBEventClientCount).toBe(1);

    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      group_id: runtimeAccountB.groupId,
      messages: [sourceOne, sourceTwo],
      status: "open",
      type: "snapshot",
    });
    await expect(
      content.getByText("Second exact source", { exact: true })
    ).toBeVisible();

    stub.emitAccountBEvent("participant_status", {
      conversation_id: runtimeAccountB.conversationId,
      participant_id: participantId,
      state: "active",
      status: "is composing the exact reply...",
      type: "participant_status",
      updated_at: 1,
    });

    stub.emitAccountBEvent("message_draft_started", {
      conversation_id: runtimeAccountB.conversationId,
      draft_id: "runtime-visible-draft",
      response_key: responseKey,
      revision: 0,
      source_message_ids: sourceIds,
      status: "started",
      text: "Streaming answer",
      type: "message_draft_started",
    });
    stub.emitAccountBEvent("message_draft_delta", {
      conversation_id: runtimeAccountB.conversationId,
      delta: " keeps growing",
      draft_id: "runtime-visible-draft",
      response_key: responseKey,
      revision: 1,
      source_message_ids: sourceIds,
      status: "delta",
      text: "Streaming answer keeps growing",
      type: "message_draft_delta",
    });

    const draft = content.getByTestId("chat-assistant-draft");
    await expect(draft).toContainText("Streaming answer keeps growing");

    stub.emitAccountBEvent("message_draft_cancelled", {
      conversation_id: runtimeAccountB.conversationId,
      draft_id: "runtime-wrong-scope-cancel",
      response_key: responseKey,
      revision: 1,
      source_message_ids: wrongSourceIds,
      status: "cancelled",
      text: "",
      type: "message_draft_cancelled",
    });
    await settleRendererWork(appWindow);
    await expect(draft).toContainText("Streaming answer keeps growing");

    // One Participant can own only one draft. Its next canonical assistant
    // Message settles that transient row without reply-correlation metadata.
    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      group_id: runtimeAccountB.groupId,
      messages: [sourceOne, sourceTwo, unrelatedAssistant],
      status: "open",
      type: "snapshot",
    });
    await expect(
      content.getByText("Ordinary unrelated assistant", { exact: true })
    ).toBeVisible();
    await expect(draft).toHaveCount(0);

    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      group_id: runtimeAccountB.groupId,
      messages: [sourceOne, sourceTwo, unrelatedAssistant, finalAssistant],
      status: "open",
      type: "snapshot",
    });
    await expect(
      content.getByText("Canonical transcript answer", { exact: true })
    ).toBeVisible();
    await expect(content.getByTestId("chat-assistant-draft")).toHaveCount(0);

    // A readable first snapshot carries the current Participant draft together
    // with canonical history. Main must publish that handoff without removing
    // the renderer's already visible answer between the two SSE chunks.
    stub.emitAccountBEvent("message_draft_started", {
      conversation_id: runtimeAccountB.conversationId,
      draft_id: "runtime-reconnect-draft",
      response_key: "runtime-reconnect-response",
      revision: 0,
      source_message_ids: [sourceTwo.message_id],
      status: "started",
      text: "Before reconnect",
      type: "message_draft_started",
    });
    await expect(content.getByTestId("chat-assistant-draft")).toContainText(
      "Before reconnect"
    );

    const reconnectProbe = await content
      .getByTestId("chat-assistant-draft")
      .evaluateHandle((original) => {
        const turn = original.closest('[data-testid="chat-current-turn"]')!;
        const counts = { samples: 0, detached: 0, missing: 0, moved: 0 };
        const top = original.getBoundingClientRect().top;
        let raf = 0;
        const sample = () => {
          counts.samples++;
          if (!original.isConnected) counts.detached++;
          const current = turn.querySelector('[data-testid="chat-assistant-draft"]');
          if (!current?.getClientRects().length) counts.missing++;
          if (current && current.getBoundingClientRect().top !== top) counts.moved++;
        };
        const observer = new MutationObserver(sample);
        observer.observe(turn, { childList: true, subtree: true });
        const frame = () => {
          sample();
          raf = requestAnimationFrame(frame);
        };
        frame();
        return {
          sampleCount() {
            return counts.samples;
          },
          stop() {
            sample();
            observer.disconnect();
            cancelAnimationFrame(raf);
            return counts;
          },
        };
      });
    const streamsBeforeInvalidation = stub.accountBEventStreamCount;
    stub.emitAccountBEventBatch([
      {
        data: {
          conversation_id: runtimeAccountB.conversationId,
          type: "conversation_invalidated",
        },
        event: "conversation_invalidated",
      },
      {
        data: {
          conversation_id: runtimeAccountB.conversationId,
          delta: " OLD CALLBACK",
          draft_id: "runtime-reconnect-draft",
          response_key: "runtime-reconnect-response",
          revision: 1,
          source_message_ids: [sourceTwo.message_id],
          status: "delta",
          text: "Before reconnect OLD CALLBACK",
          type: "message_draft_delta",
        },
        event: "message_draft_delta",
      },
    ]);
    await expect
      .poll(() => stub.accountBEventStreamCount)
      .toBeGreaterThan(streamsBeforeInvalidation);
    await expect.poll(() => stub.accountBEventClientCount).toBe(1);
    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      group_id: runtimeAccountB.groupId,
      messages: [sourceOne, sourceTwo, unrelatedAssistant, finalAssistant],
      participant_draft: {
        conversation_id: runtimeAccountB.conversationId,
        draft_id: "runtime-reconnect-replay",
        response_key: "runtime-reconnect-response",
        revision: 0,
        source_message_ids: [sourceTwo.message_id],
        status: "started",
        text: "Before reconnect",
        type: "message_draft_started",
      },
      status: "open",
      type: "snapshot",
    });
    // Keep a real gap before subsequent owner frames so final-state checks
    // cannot accidentally hide a clear/replay flash across Main and renderer.
    await appWindow.waitForTimeout(180);
    await expect(content.getByTestId("chat-assistant-draft")).toContainText(
      "Before reconnect"
    );

    stub.emitAccountBEvent("message_draft_started", {
      conversation_id: runtimeAccountB.conversationId,
      draft_id: "runtime-reconnect-replay",
      response_key: "runtime-reconnect-response",
      revision: 0,
      source_message_ids: [sourceTwo.message_id],
      status: "started",
      text: "Before reconnect",
      type: "message_draft_started",
    });
    await expect(content.getByTestId("chat-assistant-draft")).toContainText(
      "Before reconnect"
    );
    // A wall-clock gap does not guarantee animation frames on a busy runner.
    // Keep observing until the probe has enough samples; do not weaken the
    // continuity assertions or discard failures recorded during reconnect.
    await expect
      .poll(() => reconnectProbe.evaluate(({ sampleCount }) => sampleCount()))
      .toBeGreaterThan(5);
    const reconnectCounts = await reconnectProbe.evaluate(({ stop }) => stop());
    expect(reconnectCounts.samples).toBeGreaterThan(5);
    expect(reconnectCounts).toMatchObject({ detached: 0, missing: 0, moved: 0 });
    await test.info().attach("native-reconnect-continuity", {
      body: JSON.stringify(reconnectCounts),
      contentType: "application/json",
    });
    await reconnectProbe.dispose();

    stub.emitAccountBEvent("message_draft_cancelled", {
      conversation_id: runtimeAccountB.conversationId,
      draft_id: "runtime-reconnect-replay",
      response_key: "runtime-reconnect-response",
      revision: 0,
      source_message_ids: [sourceTwo.message_id],
      status: "cancelled",
      text: "",
      type: "message_draft_cancelled",
    });
    await expect(content.getByTestId("chat-assistant-draft")).toContainText(
      "Before reconnect"
    );
    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      group_id: runtimeAccountB.groupId,
      messages: [sourceOne, sourceTwo, unrelatedAssistant, finalAssistant],
      participant_draft: null,
      participant_status: {
        conversation_id: runtimeAccountB.conversationId,
        participant_id: participantId,
        state: "stopped",
        status: "",
        updated_at: 2,
      },
      status: "open",
      type: "snapshot",
    });
    await expect(content.getByTestId("chat-assistant-draft")).toHaveCount(0);
    // Main must publish the stopped owner with the canonical reply. Waiting
    // for the next SSE frame would briefly show Working after the draft ends.
    const participantStatus = content.getByTestId("participant-status-slot");
    await expect(participantStatus).toHaveAttribute("data-state", "stopped");
    await expect(participantStatus).toHaveAttribute("data-active", "false");

    stub.emitAccountBEvent("participant_status", {
      conversation_id: runtimeAccountB.conversationId,
      participant_id: participantId,
      state: "stopped",
      status: "",
      type: "participant_status",
      updated_at: 2,
    });
    await expect(participantStatus).toHaveAttribute("data-state", "stopped");
    await expect(participantStatus).toHaveAttribute("data-active", "false");
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("renderer refresh restores retained canonical conversation history", async () => {
  const stub = await startChatRuntimeStub({ controlledAccountBEvents: true });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });
  const source = runtimeMessage(
    "runtime-refresh-history-user",
    "user",
    "Keep this question after refresh"
  );
  const answer = runtimeMessage(
    "runtime-refresh-history-assistant",
    "assistant",
    "Keep this answer after refresh"
  );

  try {
    const appWindow = await productWindow(launched.app);
    let content = appWindow.getByRole("region", { name: "Content" });
    await expect(content.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
    await expect.poll(() => stub.accountBEventClientCount).toBe(1);

    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      group_id: runtimeAccountB.groupId,
      messages: [source, answer],
      status: "open",
      type: "snapshot",
    });
    await expect(
      content.getByText("Keep this question after refresh", { exact: true })
    ).toBeVisible();
    await expect(
      content.getByText("Keep this answer after refresh", { exact: true })
    ).toBeVisible();

    await appWindow.reload({ waitUntil: "domcontentloaded" });
    content = appWindow.getByRole("region", { name: "Content" });
    await expect(content.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
    await expect(
      content.getByText("Keep this question after refresh", { exact: true })
    ).toBeVisible();
    await expect(
      content.getByText("Keep this answer after refresh", { exact: true })
    ).toBeVisible();
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("another window mirrors a typed draft without a runtime republish per keystroke", async () => {
  const stub = await startChatRuntimeStub({ controlledAccountBEvents: true });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });
  const draft = "mirrored across windows";

  try {
    const firstWindow = await productWindow(launched.app);
    const firstContent = firstWindow.getByRole("region", { name: "Content" });
    const firstPrompt = firstContent.getByRole("textbox", { name: "AI prompt" });
    await expect(firstPrompt).toBeVisible();
    await expect.poll(() => stub.accountBEventClientCount).toBe(1);
    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      group_id: runtimeAccountB.groupId,
      messages: [
        runtimeMessage("runtime-mirror-user", "user", "A retained question"),
        runtimeMessage("runtime-mirror-assistant", "assistant", "A retained answer"),
      ],
      status: "open",
      type: "snapshot",
    });
    await expect(
      firstContent.getByText("A retained answer", { exact: true })
    ).toBeVisible();

    const secondWindow = await openSecondProductWindow(launched.app, firstWindow);
    const secondPrompt = secondWindow
      .getByRole("region", { name: "Content" })
      .getByRole("textbox", { name: "AI prompt" });
    await expect(secondPrompt).toBeVisible();
    const lease = await currentProductLease(secondWindow);
    await secondWindow.evaluate((session) => {
      const probe = { publishes: 0 };
      (window as unknown as { chatStatePublishes: typeof probe }).chatStatePublishes =
        probe;
      (
        window as unknown as {
          commaNative: {
            chat: {
              state: {
                subscribe(
                  listener: () => void,
                  input: { session: SessionProductLease }
                ): () => void;
              };
            };
          };
        }
      ).commaNative.chat.state.subscribe(
        () => {
          probe.publishes += 1;
        },
        { session }
      );
    }, lease);
    await settleRendererWork(secondWindow);
    const readPublishes = () =>
      secondWindow.evaluate(
        () =>
          (window as unknown as { chatStatePublishes: { publishes: number } })
            .chatStatePublishes.publishes
      );
    const publishesBefore = await readPublishes();

    await firstPrompt.click();
    await firstWindow.keyboard.type(draft);
    await expect(secondPrompt).toHaveText(draft);
    await expect
      .poll(async () => (await chatState(firstWindow)).sessions[0]?.state.draft)
      .toBe(draft);
    // Each keystroke used to republish every retained transcript to every
    // window; the draft now travels alone.
    expect((await readPublishes()) - publishesBefore).toBeLessThan(3);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("Main cold start and restart restore canonical conversation history", async () => {
  const stub = await startChatRuntimeStub();
  const seeded = await fetch(
    `${stub.baseUrl}/v1/comma/groups/${runtimeAccountB.groupId}/conversations/${runtimeAccountB.conversationId}/messages`,
    {
      body: JSON.stringify({
        client_request_id: "runtime-cold-history-request",
        message: {
          content: [{ text: "History loaded from Salix", type: "text" }],
          type: "message",
        },
      }),
      headers: {
        authorization: `Bearer ${runtimeAccountB.token}`,
        "content-type": "application/json",
      },
      method: "POST",
    }
  );
  expect(seeded.ok).toBe(true);

  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    token: runtimeAccountB.token,
  });
  let firstAppClosed = false;
  let restarted: Awaited<ReturnType<typeof launchRuntimeApp>> | undefined;

  try {
    const appWindow = await productWindow(launched.app);
    let content = appWindow.getByRole("region", { name: "Content" });
    await expect(
      content.getByText("History loaded from Salix", { exact: true })
    ).toBeVisible();

    await test.step("close Electron before restoring persisted history", () =>
      closeElectronTestApp(launched.app));
    firstAppClosed = true;
    restarted = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountB.email,
      userDataDir: launched.userDataDir,
    });
    const restartedWindow = await productWindow(restarted.app);
    content = restartedWindow.getByRole("region", { name: "Content" });
    await expect(
      content.getByText("History loaded from Salix", { exact: true })
    ).toBeVisible();
  } finally {
    try {
      if (!firstAppClosed) {
        await closeElectronTestApp(launched.app);
      }
    } finally {
      try {
        const restartedApp = restarted?.app;
        if (restartedApp) {
          await test.step("close the restarted history app", () =>
            closeElectronTestApp(restartedApp));
        }
      } finally {
        await stub.close();
        await rm(launched.userDataDir, { force: true, recursive: true });
      }
    }
  }
});

test("Side Chat Clear stays subscriber-local across late responses and renderer recovery", async () => {
  await ensureChatRuntimeFixtureBuilt();
  const stub = await startChatRuntimeStub({
    controlledAccountBEvents: true,
    deferAccountBMessages: true,
  });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountB.email,
    rendererUrl: fixtureUrl,
    token: runtimeAccountB.token,
  });
  const d1User = runtimeMessage("runtime-d1-user", "user", "D1 question");
  const d1Final = runtimeMessage("runtime-d1-final", "assistant", "D1 late final");
  const d2Final = runtimeMessage("runtime-d2-final", "assistant", "D2 final");

  try {
    const mainWindow = await findElectronWindowByNativeRole(
      launched.app,
      "main-window"
    );
    const sideChatWindow = await findElectronWindowByNativeRole(
      launched.app,
      "side-chat-window"
    );
    await Promise.all([
      mainWindow.waitForLoadState("domcontentloaded"),
      sideChatWindow.waitForLoadState("domcontentloaded"),
    ]);
    await expect(
      mainWindow.getByRole("heading", { name: /ownership fixture/i })
    ).toBeVisible();

    // The production Side Chat window loads the same small fixture, but starts
    // its channel only when this scenario asks for the second exact subscriber.
    await sideChatWindow.evaluate(() =>
      window.chatRuntimeFixture.startReplacementChannel()
    );
    await expect
      .poll(async () => (await chatState(mainWindow)).sessions[0]?.refs)
      .toBe(2);
    await expect.poll(() => stub.accountBEventClientCount).toBe(1);

    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      messages: [d1User],
      status: "open",
      type: "snapshot",
      group_id: runtimeAccountB.groupId,
    });
    stub.emitAccountBEvent("message_draft_started", {
      conversation_id: runtimeAccountB.conversationId,
      draft_id: "runtime-draft-d1",
      response_key: "runtime-response-d1",
      source_message_ids: ["runtime-d1-user"],
      status: "started",
      text: "D1 old draft",
      type: "message_draft_started",
    });
    await expect
      .poll(async () => {
        const [main, side] = await Promise.all([
          fixtureSnapshot(mainWindow),
          fixtureSnapshot(sideChatWindow),
        ]);
        return {
          mainDraft: main.assistantDraft?.text,
          mainMessages: main.messages.map((message) => message.text),
          sideDraft: side.assistantDraft?.text,
          sideMessages: side.messages.map((message) => message.text),
        };
      })
      .toEqual({
        mainDraft: "D1 old draft",
        mainMessages: ["D1 question"],
        sideDraft: "D1 old draft",
        sideMessages: ["D1 question"],
      });

    await sideChatWindow.evaluate(() => window.chatRuntimeFixture.clearPresentation());
    await expect
      .poll(async () => {
        const [main, side, runtime] = await Promise.all([
          fixtureSnapshot(mainWindow),
          fixtureSnapshot(sideChatWindow),
          chatState(mainWindow),
        ]);
        const session = runtime.sessions[0];
        const sideProjection = session?.surfaceProjections?.find(
          (projection) =>
            projection.subscriberId ===
            `win_side_chat:${runtimeAccountB.groupId}/${runtimeAccountB.conversationId}`
        );
        return {
          canonicalDraft: session?.state.assistantDraft?.text,
          canonicalMessages: session?.state.messages.map((message) => message.text),
          mainDraft: main.assistantDraft?.text,
          mainMessages: main.messages.map((message) => message.text),
          projectionGeneration: sideProjection?.generation,
          projectedDraft: sideProjection?.state.assistantDraft?.text,
          projectedMessages: sideProjection?.state.messages.map(
            (message) => message.text
          ),
          sideDraft: side.assistantDraft?.text,
          sideMessages: side.messages.map((message) => message.text),
        };
      })
      .toEqual({
        canonicalDraft: "D1 old draft",
        canonicalMessages: ["D1 question"],
        mainDraft: "D1 old draft",
        mainMessages: ["D1 question"],
        projectionGeneration: 1,
        projectedDraft: undefined,
        projectedMessages: [],
        sideDraft: undefined,
        sideMessages: [],
      });

    // Releasing the renderer lease must not erase its subscriber projection.
    await sideChatWindow.evaluate(() => window.chatRuntimeFixture.stopChannel());
    await expect
      .poll(async () => (await chatState(mainWindow)).sessions[0]?.refs)
      .toBe(1);
    await sideChatWindow.evaluate(() =>
      window.chatRuntimeFixture.startReplacementChannel()
    );
    await expect
      .poll(async () => {
        const [runtime, side] = await Promise.all([
          chatState(mainWindow),
          fixtureSnapshot(sideChatWindow),
        ]);
        return {
          refs: runtime.sessions[0]?.refs,
          sideDraft: side.assistantDraft?.text,
          sideMessages: side.messages.map((message) => message.text),
        };
      })
      .toEqual({ refs: 2, sideDraft: undefined, sideMessages: [] });

    stub.emitAccountBEvent("message_draft_delta", {
      conversation_id: runtimeAccountB.conversationId,
      draft_id: "runtime-draft-d1",
      response_key: "runtime-response-d1",
      source_message_ids: ["runtime-d1-user"],
      status: "delta",
      text: "D1 old draft, now late",
      type: "message_draft_delta",
    });
    await expect
      .poll(async () => {
        const [main, side] = await Promise.all([
          fixtureSnapshot(mainWindow),
          fixtureSnapshot(sideChatWindow),
        ]);
        return {
          mainDraft: main.assistantDraft?.text,
          sideDraft: side.assistantDraft?.text,
        };
      })
      .toEqual({ mainDraft: "D1 old draft, now late", sideDraft: undefined });

    stub.emitAccountBEvent("message_draft_completed", {
      conversation_id: runtimeAccountB.conversationId,
      draft_id: "runtime-draft-d1",
      response_key: "runtime-response-d1",
      source_message_ids: ["runtime-d1-user"],
      status: "completed",
      text: "D1 old draft, now late",
      type: "message_draft_completed",
    });
    stub.emitAccountBEvent("message_created", {
      conversation_id: runtimeAccountB.conversationId,
      message_id: d1Final.message_id,
      role: "assistant",
      type: "message_created",
    });
    await expect.poll(() => stub.accountBEventStreamCount).toBeGreaterThanOrEqual(2);
    await expect.poll(() => stub.accountBEventClientCount).toBe(1);
    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      messages: [d1User, d1Final],
      status: "open",
      type: "snapshot",
      group_id: runtimeAccountB.groupId,
    });
    await expect
      .poll(async () => {
        const [main, side] = await Promise.all([
          fixtureSnapshot(mainWindow),
          fixtureSnapshot(sideChatWindow),
        ]);
        return {
          mainMessages: main.messages.map((message) => message.text),
          sideMessages: side.messages.map((message) => message.text),
        };
      })
      .toEqual({
        mainMessages: ["D1 question", "D1 late final"],
        sideMessages: ["D1 late final"],
      });

    await sideChatWindow.evaluate(() =>
      window.chatRuntimeFixture.sendCurrentAccepted("D2 accepted")
    );
    await expect.poll(() => stub.messageAttempts.length).toBe(1);
    await expect
      .poll(async () => {
        const [main, side] = await Promise.all([
          fixtureSnapshot(mainWindow),
          fixtureSnapshot(sideChatWindow),
        ]);
        return {
          mainMessages: main.messages.map((message) => message.text),
          sideMessages: side.messages.map((message) => message.text),
          sidePending: side.pending.map((pending) => pending.text),
        };
      })
      .toEqual({
        mainMessages: ["D1 question", "D1 late final", "D2 accepted"],
        sideMessages: ["D1 late final", "D2 accepted"],
        sidePending: ["D2 accepted"],
      });

    stub.settleNextAccountBMessage();
    await expect
      .poll(async () => (await fixtureSnapshot(sideChatWindow)).pending)
      .toEqual([]);
    const d2User = runtimeMessage(
      "runtime-user-message-1",
      "user",
      "D2 accepted",
      stub.messageAttempts[0]?.body.client_request_id
    );
    stub.emitAccountBEvent("message_draft_started", {
      conversation_id: runtimeAccountB.conversationId,
      draft_id: "runtime-draft-d2",
      response_key: "runtime-response-d2",
      source_message_ids: ["runtime-user-message-1"],
      status: "started",
      text: "D2 draft",
      type: "message_draft_started",
    });
    await expect
      .poll(async () => {
        const side = await fixtureSnapshot(sideChatWindow);
        return {
          draft: side.assistantDraft?.text,
          messages: side.messages.map((message) => message.text),
        };
      })
      .toEqual({
        draft: "D2 draft",
        messages: ["D1 late final", "D2 accepted"],
      });

    stub.emitAccountBEvent("message_draft_completed", {
      conversation_id: runtimeAccountB.conversationId,
      draft_id: "runtime-draft-d2",
      response_key: "runtime-response-d2",
      source_message_ids: ["runtime-user-message-1"],
      status: "completed",
      text: "D2 draft",
      type: "message_draft_completed",
    });
    stub.emitAccountBEvent("message_created", {
      conversation_id: runtimeAccountB.conversationId,
      message_id: d2Final.message_id,
      role: "assistant",
      type: "message_created",
    });
    await expect.poll(() => stub.accountBEventStreamCount).toBeGreaterThanOrEqual(3);
    await expect.poll(() => stub.accountBEventClientCount).toBe(1);
    stub.emitAccountBEvent("snapshot", {
      conversation_id: runtimeAccountB.conversationId,
      messages: [d1User, d1Final, d2User, d2Final],
      status: "open",
      type: "snapshot",
      group_id: runtimeAccountB.groupId,
    });
    await expect
      .poll(async () => {
        const [main, side, runtime] = await Promise.all([
          fixtureSnapshot(mainWindow),
          fixtureSnapshot(sideChatWindow),
          chatState(mainWindow),
        ]);
        return {
          canonicalMessages: runtime.sessions[0]?.state.messages.map(
            (message) => message.text
          ),
          mainMessages: main.messages.map((message) => message.text),
          sideMessages: side.messages.map((message) => message.text),
          sideServerMessages: side.serverMessages.map((message) => message.text),
        };
      })
      .toEqual({
        canonicalMessages: ["D1 question", "D1 late final", "D2 accepted", "D2 final"],
        mainMessages: ["D1 question", "D1 late final", "D2 accepted", "D2 final"],
        sideMessages: ["D1 late final", "D2 accepted", "D2 final"],
        sideServerMessages: ["D1 late final", "D2 accepted", "D2 final"],
      });

    const sideCalls = await sideChatWindow.evaluate(() =>
      window.chatRuntimeFixture.bridgeCalls()
    );
    expect(sideCalls.clearPresentations).toEqual([
      expect.objectContaining({
        leaseId: sideCalls.retains[0]?.leaseId,
        subscriberId: `win_side_chat:${runtimeAccountB.groupId}/${runtimeAccountB.conversationId}`,
      }),
    ]);
    expect(sideCalls.retains).toHaveLength(2);
    expect(sideCalls.retains[1]).toMatchObject({
      subscriberId: sideCalls.retains[0]?.subscriberId,
    });
    expect(sideCalls.releases).toEqual([
      expect.objectContaining({
        leaseId: sideCalls.retains[0]?.leaseId,
        subscriberId: sideCalls.retains[0]?.subscriberId,
      }),
    ]);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test("a delayed renderer retain receipt cannot mutate or release its replacement Main lease", async () => {
  await ensureChatRuntimeFixtureBuilt();
  // The fixture starts its synthetic BridgeConversationChannel only in the
  // main-window role. Keep the always-on native Side Chat target resolution
  // pending so this race observes only the renderer lease exercised here.
  const stub = await startChatRuntimeStub({ deferAccountBResolution: true });
  const launched = await launchRuntimeApp({
    baseUrl: stub.baseUrl,
    email: runtimeAccountA.email,
    rendererUrl: delayedRetainFixtureUrl,
    token: runtimeAccountA.token,
  });

  try {
    const appWindow = await findElectronWindowByNativeRole(launched.app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await expect(
      appWindow.getByRole("heading", { name: /ownership fixture/i })
    ).toBeVisible();

    // The fixture delays only the first renderer-facing receipt, after the
    // generated preload has already delivered retain to the real coordinator.
    await expect
      .poll(() =>
        appWindow.evaluate(() =>
          window.chatRuntimeFixture.isFirstRetainAcceptedByMain()
        )
      )
      .toBe(true);
    await expect
      .poll(async () => (await chatState(appWindow)).sessions[0]?.refs)
      .toBe(1);

    await appWindow.evaluate(async () => {
      window.chatRuntimeFixture.queueStaleDraftAndStop();
      await window.chatRuntimeFixture.replaceSession();
      window.chatRuntimeFixture.startReplacementChannel();
    });
    await expect
      .poll(async () => {
        const session = (await chatState(appWindow)).sessions[0];
        return { draft: session?.state.draft, refs: session?.refs };
      })
      .toEqual({ draft: "", refs: 1 });

    await appWindow.evaluate(() =>
      window.chatRuntimeFixture.releaseFirstRetainReceipt()
    );
    await expect
      .poll(() =>
        appWindow.evaluate(() => window.chatRuntimeFixture.staleDraftOutcome())
      )
      .toBe("rejected");

    await expect
      .poll(async () => {
        const session = (await chatState(appWindow)).sessions[0];
        return { draft: session?.state.draft, refs: session?.refs };
      })
      .toEqual({ draft: "", refs: 1 });

    const bridgeCalls = await appWindow.evaluate(() =>
      window.chatRuntimeFixture.bridgeCalls()
    );
    expect(bridgeCalls.retains).toHaveLength(2);
    expect(bridgeCalls.retains[0]).toMatchObject({
      leaseId: expect.any(String),
      subscriberId: `win_main:${runtimeAccountB.groupId}/${runtimeAccountB.conversationId}`,
    });
    expect(bridgeCalls.retains[1]).toMatchObject({
      leaseId: expect.any(String),
      subscriberId: bridgeCalls.retains[0]?.subscriberId,
    });
    expect(bridgeCalls.retains[1]?.leaseId).not.toBe(bridgeCalls.retains[0]?.leaseId);
    expect(bridgeCalls.setDrafts).toEqual([]);
    expect(bridgeCalls.releases).toEqual([
      expect.objectContaining({
        leaseId: bridgeCalls.retains[0]?.leaseId,
        subscriberId: bridgeCalls.retains[0]?.subscriberId,
      }),
    ]);

    await appWindow.evaluate(() =>
      window.chatRuntimeFixture.sendCurrent("replacement lifecycle remains writable")
    );
    await expect.poll(() => stub.messageAttempts.length).toBe(1);
    expect(stub.messageAttempts[0]).toMatchObject({ token: runtimeAccountB.token });
    await expect
      .poll(async () => (await chatState(appWindow)).sessions[0]?.refs)
      .toBe(1);
  } finally {
    await launched.app.close();
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

async function launchRuntimeApp({
  baseUrl,
  email,
  googleIdToken,
  rendererUrl,
  secureSessionFilePath,
  token,
  userDataDir: requestedUserDataDir,
}: {
  baseUrl: string;
  email: string;
  googleIdToken?: string;
  rendererUrl?: string;
  secureSessionFilePath?: string;
  token?: string;
  userDataDir?: string;
}) {
  const userDataDir =
    requestedUserDataDir ??
    (await mkdtemp(join(await realpath(tmpdir()), "comma-chat-runtime-e2e-")));
  // Either stub account may sign in, now or later in the test.
  recordElectronOnboardingCompleted(userDataDir, [
    runtimeAccountA.userId,
    runtimeAccountB.userId,
  ]);
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...env } = process.env;
  const app = await electron.launch({
    args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...env,
      COMMA_API_BASE_URL: baseUrl,
      COMMA_ELECTRON_STARTUP_SESSION_EMAIL: email,
      ...(googleIdToken ? { COMMA_ELECTRON_E2E_GOOGLE_ID_TOKEN: googleIdToken } : {}),
      ...(secureSessionFilePath
        ? { COMMA_ELECTRON_E2E_SECURE_SESSION_FILE_PATH: secureSessionFilePath }
        : {}),
      ...(token ? { COMMA_ELECTRON_STARTUP_SESSION_TOKEN: token } : {}),
      ...(rendererUrl ? { COMMA_ELECTRON_RENDERER_URL: rendererUrl } : {}),
      NODE_ENV: "test",
    },
  });
  return { app, userDataDir };
}

async function expectRichComposerEmpty(composer: Locator) {
  await expect(composer).toHaveAttribute("contenteditable", "true");
  await expect(composer).toHaveText("");
  await expect(composer).toHaveAttribute("data-empty", "true");
}

async function productWindow(app: Awaited<ReturnType<typeof electron.launch>>) {
  const appWindow = await findElectronWindowByRole(app, "complementary", {
    name: "App sidebar",
  });
  await appWindow.waitForLoadState("domcontentloaded");
  return appWindow;
}

async function mainProductWindow(app: Awaited<ReturnType<typeof electron.launch>>) {
  const appWindow = await findElectronWindowByNativeRole(app, "main-window");
  await appWindow.waitForLoadState("domcontentloaded");
  return appWindow;
}

async function openSecondProductWindow(
  app: Awaited<ReturnType<typeof electron.launch>>,
  firstWindow: Page
) {
  const [secondWindow] = await Promise.all([
    app.waitForEvent("window"),
    firstWindow.evaluate(() =>
      (
        window as unknown as {
          commaNative: {
            windows: { create: (input: { route: string }) => Promise<unknown> };
          };
        }
      ).commaNative.windows.create({ route: "/" })
    ),
  ]);
  await secondWindow.waitForLoadState("domcontentloaded");
  await expect(
    secondWindow.getByRole("complementary", { name: "App sidebar" })
  ).toBeVisible();
  return secondWindow;
}

async function signInAsAccountB(appWindow: Page) {
  await signInWithEmail(appWindow, runtimeAccountB.email, async () => "654321");
}

function signOutThroughNative(appWindow: Page) {
  return appWindow.evaluate(async () => {
    const session = (
      window as unknown as {
        commaNative: { session: SessionBridge };
      }
    ).commaNative.session;
    const lifecycle = await session.state.get();
    if (lifecycle.phase !== "signed_in") {
      throw new Error("Sign-out requires a proven signed-in Session.");
    }
    const result = await session.signOut({
      expected: {
        authorityInstanceId: lifecycle.authority.authorityInstanceId,
        expectedAudience: lifecycle.session.audience,
        expectedSessionId: lifecycle.session.sessionId,
        generation: lifecycle.generation,
      },
    });
    if (!result.ok) {
      throw new Error(`Native sign-out failed: ${result.error.code}`);
    }
    return result.value;
  });
}

function requestEmailLoginThroughNative(
  appWindow: Page,
  email: string,
  expected?: SessionAbsenceExpectation
) {
  return appWindow.evaluate(
    async ({ email: inputEmail, expected: capturedExpectation }) => {
      const session = (
        window as unknown as {
          commaNative: { session: SessionBridge };
        }
      ).commaNative.session;
      const lifecycle = await session.state.get();
      const exactExpectation =
        capturedExpectation ??
        (lifecycle.phase === "signed_out"
          ? {
              authorityInstanceId: lifecycle.authority.authorityInstanceId,
              expectedSessionId: null,
              generation: lifecycle.generation,
            }
          : undefined);
      if (!exactExpectation) {
        throw new Error(
          "Email sign-in requires a proven signed-out Session or its exact auth-attempt expectation."
        );
      }
      const result = await session.requestEmailLogin({
        email: inputEmail,
        expected: exactExpectation,
      });
      if (!result.ok) {
        throw new Error(`Native email login failed: ${result.error.code}`);
      }
      return {
        ...result.value,
        expected: exactExpectation,
      };
    },
    { email, expected }
  );
}

function verifyEmailAttemptThroughNative(
  appWindow: Page,
  challenge: {
    attempt: SessionAuthAttemptRef;
    challengeId: string;
  },
  code: string
) {
  return appWindow.evaluate(
    async ({ attempt, challengeId, code: inputCode }) =>
      (
        window as unknown as {
          commaNative: { session: SessionBridge };
        }
      ).commaNative.session.verifyEmailLogin({
        attempt,
        challengeId,
        code: inputCode,
      }),
    {
      attempt: challenge.attempt,
      challengeId: challenge.challengeId,
      code,
    }
  );
}

async function signInWithEmail(
  appWindow: Page,
  email: string,
  resolveCode: () => Promise<string>
) {
  await appWindow.getByRole("textbox", { name: "Email" }).fill(email);
  await appWindow.getByRole("button", { name: "Continue with email" }).click();
  await expect(
    appWindow.getByRole("heading", { name: "Check your email" })
  ).toBeVisible();
  await appWindow
    .getByRole("textbox", { name: /verification code/i })
    .fill(await resolveCode());
}

function verifyEmailThroughNative(appWindow: Page, _challengeId: string, code: string) {
  return appWindow.evaluate(
    async ({ code: inputCode, email }) => {
      const session = (
        window as unknown as {
          commaNative: { session: SessionBridge };
        }
      ).commaNative.session;
      const lifecycle = await session.state.get();
      if (lifecycle.phase !== "signed_out") {
        throw new Error("Native command failed.");
      }
      const challenge = await session.requestEmailLogin({
        email,
        expected: {
          authorityInstanceId: lifecycle.authority.authorityInstanceId,
          expectedSessionId: null,
          generation: lifecycle.generation,
        },
      });
      if (!challenge.ok) {
        throw new Error("Native command failed.");
      }
      const verified = await session.verifyEmailLogin({
        attempt: challenge.value.attempt,
        challengeId: challenge.value.challengeId,
        code: inputCode,
      });
      if (!verified.ok) {
        throw new Error("Native command failed.");
      }
      return {
        apiBaseUrl: verified.value.session.audience,
        email: verified.value.principal.email,
        signedIn: true,
        userId: verified.value.principal.userId,
      };
    },
    { code, email: runtimeAccountB.email }
  );
}

async function installAuthCommitGate(
  app: Awaited<ReturnType<typeof electron.launch>>,
  userDataDir: string
) {
  await app.evaluate(async (_electron, targetDirectory) => {
    const fsPromises = process.getBuiltinModule("node:fs/promises") as {
      open: typeof import("node:fs/promises").open;
    };
    const originalOpen = fsPromises.open;
    let release!: () => void;
    const released = new Promise<void>((releaseGate) => {
      release = releaseGate;
    });
    const gate = {
      originalOpen,
      reached: false,
      release,
      released,
    };
    (
      globalThis as unknown as {
        commaAuthCommitGate?: typeof gate;
      }
    ).commaAuthCommitGate = gate;

    fsPromises.open = async (path, flags, mode) => {
      const handle = await originalOpen(path, flags, mode);
      if (String(path) === targetDirectory && flags === "r") {
        const sync = handle.sync.bind(handle);
        handle.sync = async () => {
          gate.reached = true;
          await gate.released;
          await sync();
        };
      }
      return handle;
    };
  }, userDataDir);
}

function authCommitGateReached(app: Awaited<ReturnType<typeof electron.launch>>) {
  return app.evaluate(() => {
    const gate = (
      globalThis as unknown as {
        commaAuthCommitGate?: { reached: boolean };
      }
    ).commaAuthCommitGate;
    return gate?.reached ?? false;
  });
}

async function releaseAuthCommitGate(app: Awaited<ReturnType<typeof electron.launch>>) {
  await app.evaluate(() => {
    const scope = globalThis as unknown as {
      commaAuthCommitGate?: {
        originalOpen: typeof import("node:fs/promises").open;
        release: () => void;
      };
    };
    const gate = scope.commaAuthCommitGate;
    if (!gate) return;

    const fsPromises = process.getBuiltinModule("node:fs/promises") as {
      open: typeof import("node:fs/promises").open;
    };
    fsPromises.open = gate.originalOpen;
    gate.release();
    delete scope.commaAuthCommitGate;
  });
}

async function installAuthCommitFsyncFailure(
  app: Awaited<ReturnType<typeof electron.launch>>,
  secureSessionFile: string
) {
  await app.evaluate(async (_electron, targetFile) => {
    const fsPromises = process.getBuiltinModule("node:fs/promises") as {
      open: typeof import("node:fs/promises").open;
    };
    const path = process.getBuiltinModule("node:path") as typeof import("node:path");
    const originalOpen = fsPromises.open;
    const fault = {
      failures: 0,
      originalOpen,
    };
    (
      globalThis as unknown as {
        commaAuthCommitFsyncFailure?: typeof fault;
      }
    ).commaAuthCommitFsyncFailure = fault;

    fsPromises.open = async (filePath, flags, mode) => {
      const handle = await originalOpen(filePath, flags, mode);
      const name = path.basename(String(filePath));
      const isTargetTemporaryFile =
        flags === "wx" &&
        path.dirname(String(filePath)) === path.dirname(targetFile) &&
        name.startsWith(`.${path.basename(targetFile)}.`) &&
        name.endsWith(".tmp");
      if (isTargetTemporaryFile) {
        handle.sync = async () => {
          fault.failures += 1;
          const error = new Error(
            "Injected Electron Session temporary-file fsync failure."
          ) as NodeJS.ErrnoException;
          error.code = "EIO";
          throw error;
        };
      }
      return handle;
    };
  }, secureSessionFile);
}

function authCommitFsyncFailureCount(app: Awaited<ReturnType<typeof electron.launch>>) {
  return app.evaluate(
    () =>
      (
        globalThis as unknown as {
          commaAuthCommitFsyncFailure?: { failures: number };
        }
      ).commaAuthCommitFsyncFailure?.failures ?? 0
  );
}

async function restoreAuthCommitFsyncFailure(
  app: Awaited<ReturnType<typeof electron.launch>>
) {
  await app.evaluate(() => {
    const scope = globalThis as unknown as {
      commaAuthCommitFsyncFailure?: {
        originalOpen: typeof import("node:fs/promises").open;
      };
    };
    const fault = scope.commaAuthCommitFsyncFailure;
    if (!fault) return;
    const fsPromises = process.getBuiltinModule("node:fs/promises") as {
      open: typeof import("node:fs/promises").open;
    };
    fsPromises.open = fault.originalOpen;
    delete scope.commaAuthCommitFsyncFailure;
  });
}

async function installShutdownBlockedProbe(
  app: Awaited<ReturnType<typeof electron.launch>>
) {
  await app.evaluate(({ dialog }) => {
    const messages: { message: string; title: string }[] = [];
    (
      globalThis as unknown as {
        commaShutdownBlockedMessages?: typeof messages;
      }
    ).commaShutdownBlockedMessages = messages;
    dialog.showErrorBox = (title, message) => {
      messages.push({ message, title });
    };
  });
}

function shutdownBlockedMessages(app: Awaited<ReturnType<typeof electron.launch>>) {
  return app.evaluate(
    () =>
      (
        globalThis as unknown as {
          commaShutdownBlockedMessages?: { message: string; title: string }[];
        }
      ).commaShutdownBlockedMessages ?? []
  );
}

function sessionState(appWindow: Page): Promise<CommaSessionState> {
  return appWindow.evaluate(async () => {
    const lifecycle = await (
      window as unknown as {
        commaNative: {
          session: SessionBridge;
        };
      }
    ).commaNative.session.state.get();
    return {
      ...lifecycle,
      apiBaseUrl:
        lifecycle.phase === "signed_in" ? lifecycle.session.audience : undefined,
      email: lifecycle.principal?.email,
      revocationPending: lifecycle.cleanup.revocation === "pending",
      signedIn: lifecycle.phase === "signed_in",
      userId: lifecycle.principal?.userId,
    };
  });
}

function currentProductLease(appWindow: Page): Promise<SessionProductLease> {
  return appWindow.evaluate(async () => {
    const lifecycle = await (
      window as unknown as {
        commaNative: { session: SessionBridge };
      }
    ).commaNative.session.state.get();
    if (lifecycle.phase !== "signed_in") {
      throw new Error("A product lease requires a signed-in Session.");
    }
    return {
      audience: lifecycle.session.audience,
      authorityInstanceId: lifecycle.authority.authorityInstanceId,
      generation: lifecycle.generation,
      sessionId: lifecycle.session.sessionId,
    };
  });
}

function chatStateForLease(appWindow: Page, session: SessionProductLease) {
  return appWindow.evaluate(
    async (inputSession) =>
      (
        window as unknown as {
          commaNative: {
            chat: {
              state: (input: { session: SessionProductLease }) => Promise<{
                session: SessionProductLease;
                snapshot: ChatRuntimeSnapshot;
              }>;
            };
          };
        }
      ).commaNative.chat.state({ session: inputSession }),
    session
  );
}

async function settleRendererWork(appWindow: Page) {
  await appWindow.evaluate(
    () =>
      new Promise<void>((done) => {
        window.requestAnimationFrame(() => {
          window.requestAnimationFrame(() => window.setTimeout(done, 100));
        });
      })
  );
}

function attemptRendererAuthBypass(appWindow: Page) {
  return appWindow.evaluate(async () => {
    const response = await fetch("assets://./v1/comma/auth/email/verify", {
      body: JSON.stringify({ challenge_id: "renderer-bypass", code: "123456" }),
      headers: { "content-type": "application/json" },
      method: "POST",
    });
    const body = await response.json().catch(() => null);
    return { body, status: response.status };
  });
}

function rendererBearerExposure(appWindow: Page) {
  return appWindow.evaluate(async () => {
    const session = await (
      window as unknown as {
        commaNative: { session: { state: { get: () => Promise<unknown> } } };
      }
    ).commaNative.session.state.get();
    const storageEntries = [localStorage, sessionStorage].flatMap((area) =>
      Array.from({ length: area.length }, (_, index) => {
        const key = area.key(index);
        return { key, value: key ? area.getItem(key) : null };
      })
    );

    const urls = [
      location.href,
      ...performance.getEntriesByType("resource").map((entry) => entry.name),
    ];
    const bearerPattern = /comma_sess_[A-Za-z0-9_-]+/;

    return {
      dom: bearerPattern.test(JSON.stringify(document.documentElement.outerHTML)),
      session: bearerPattern.test(JSON.stringify(session)),
      storage: bearerPattern.test(JSON.stringify(storageEntries)),
      urls: bearerPattern.test(JSON.stringify(urls)),
    };
  });
}

async function decryptActiveSessionToken(
  app: Awaited<ReturnType<typeof electron.launch>>,
  userDataDir: string
) {
  const encrypted = await readFile(join(userDataDir, "secure-session.bin"));
  const token = await app.evaluate(({ safeStorage }, encryptedBase64) => {
    const envelope = JSON.parse(
      safeStorage.decryptString(globalThis.Buffer.from(encryptedBase64, "base64"))
    ) as { active?: { token?: unknown } };
    return typeof envelope.active?.token === "string"
      ? envelope.active.token
      : undefined;
  }, encrypted.toString("base64"));

  if (!token) {
    throw new Error("Encrypted Electron session does not contain an active bearer.");
  }
  return token;
}

async function decryptSessionEnvelope(
  app: Awaited<ReturnType<typeof electron.launch>>,
  secureSessionFile: string
) {
  const encrypted = await readFile(secureSessionFile);
  return app.evaluate(({ safeStorage }, encryptedBase64) => {
    return JSON.parse(
      safeStorage.decryptString(globalThis.Buffer.from(encryptedBase64, "base64"))
    ) as Record<string, unknown>;
  }, encrypted.toString("base64"));
}

async function serverSessionStatus(apiBaseUrl: string, bearer: string) {
  const response = await fetch(`${apiBaseUrl}/v1/comma/auth/session`, {
    headers: {
      accept: "application/json",
      authorization: `Bearer ${bearer}`,
    },
    signal: AbortSignal.timeout(5_000),
  });
  await response.arrayBuffer();
  return response.status;
}

async function bestEffortRevokeServerSession(
  apiBaseUrl: string,
  bearer: string | undefined
) {
  if (!bearer) return;

  try {
    const response = await fetch(`${apiBaseUrl}/v1/comma/auth/logout`, {
      body: "{}",
      headers: {
        accept: "application/json",
        authorization: `Bearer ${bearer}`,
        "content-type": "application/json",
      },
      method: "POST",
      signal: AbortSignal.timeout(5_000),
    });
    await response.arrayBuffer();
  } catch {
    // Best effort only: the primary assertion reports revocation failures.
  }
}

async function requireHealthy(url: string, label: string) {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(5_000) });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
  } catch (error) {
    throw new Error(
      `${label} is unavailable at ${url}: ${
        error instanceof Error ? error.message : String(error)
      }`,
      { cause: error }
    );
  }
}

async function waitForMailpitCode(
  mailpitBaseUrl: string,
  recipient: string,
  notBeforeEpochMs?: number
) {
  let lastError: unknown;

  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      const response = await fetch(`${mailpitBaseUrl}/api/v1/messages`, {
        signal: AbortSignal.timeout(5_000),
      });
      if (!response.ok) {
        throw new Error(`Mailpit returned HTTP ${response.status}`);
      }
      const mailbox = (await response.json()) as {
        messages?: {
          Created?: string;
          Snippet?: string;
          Subject?: string;
          To?: { Address?: string }[];
        }[];
      };
      const message = mailbox.messages?.find(
        (candidate) =>
          candidate.Subject === "Your Comma login code" &&
          candidate.To?.some((address) => address.Address === recipient) &&
          (notBeforeEpochMs === undefined ||
            (candidate.Created !== undefined &&
              Date.parse(candidate.Created) >= notBeforeEpochMs - 2_000))
      );
      const code = message?.Snippet?.match(/\b\d{6}\b/)?.[0];

      if (code) return code;
    } catch (error) {
      lastError = error;
    }

    await new Promise((done) => setTimeout(done, 250));
  }

  throw new Error(
    `Mailpit did not receive a Comma code for ${recipient}${
      lastError instanceof Error ? `: ${lastError.message}` : ""
    }`
  );
}

function normalizedUrl(value: string) {
  return value.replace(/\/+$/, "");
}

// The rail shows no account any more: a signed-in product shell is the rail
// with its Settings item, and the account behind it is read from Main.
async function expectSignedInShellAs(appWindow: Page, email: string) {
  await expect(
    appWindow.getByRole("button", { exact: true, name: "Settings" })
  ).toBeVisible();
  await expect
    .poll(() => sessionState(appWindow).then((state) => state.email))
    .toBe(email);
}

// Sign out lives on Settings -> Profile (the account menu is gone). Settings
// is a location, so that detour would leave the next sign-in on /settings;
// once the signed-in shell has gone the helper puts the hash back where the
// test was, so a re-login lands on the surface it did when sign-out was one
// click away from Home.
async function signOutFromSettings(appWindow: Page) {
  const previousHash = await appWindow.evaluate(() => window.location.hash);
  await appWindow.getByRole("button", { exact: true, name: "Settings" }).click();
  await appWindow.getByRole("button", { exact: true, name: "Profile" }).click();
  await appWindow.getByRole("button", { exact: true, name: "Sign out" }).click();
  await expect(
    appWindow.getByRole("complementary", { name: "App sidebar" })
  ).toBeHidden();
  await appWindow.evaluate((hash) => {
    window.location.hash = hash || "#/";
  }, previousHash);
}

function sessionSignedIn(appWindow: Page) {
  return sessionState(appWindow).then((state) => state.signedIn);
}

async function fileExists(filePath: string) {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}

function chatState(appWindow: Page) {
  return appWindow.evaluate(async (): Promise<ChatRuntimeSnapshot> => {
    const bridge = (
      window as unknown as {
        commaNative: {
          chat: {
            state: {
              get: (input: { session: SessionProductLease }) => Promise<{
                session: SessionProductLease;
                snapshot: ChatRuntimeSnapshot;
              }>;
            };
          };
          session: SessionBridge;
        };
      }
    ).commaNative;
    let lifecycle = await bridge.session.state.get();
    if (lifecycle.phase !== "signed_in") {
      const reconciled = await bridge.session.reconcile({ reason: "startup" });
      if (reconciled.ok) {
        lifecycle = reconciled.value;
      }
    }
    if (lifecycle.phase !== "signed_in") {
      throw new Error("Chat state requires a signed-in Session.");
    }
    const session: SessionProductLease = {
      audience: lifecycle.session.audience,
      authorityInstanceId: lifecycle.authority.authorityInstanceId,
      generation: lifecycle.generation,
      sessionId: lifecycle.session.sessionId,
    };
    return (await bridge.chat.state.get({ session })).snapshot;
  });
}

function fixtureSnapshot(appWindow: Page) {
  return appWindow.evaluate(() => window.chatRuntimeFixture.getSnapshot());
}

function installRealChatStreamProbe(
  appWindow: Page,
  productLease: SessionProductLease
) {
  return appWindow.evaluate((session) => {
    const scope = window as typeof window & {
      commaRealChatStreamProbe?: RealChatStreamProbe;
    };
    if (scope.commaRealChatStreamProbe) {
      throw new Error("Real chat stream probe is already installed.");
    }

    const probe: RealChatStreamProbe = {
      activity: undefined,
      activityRoute: undefined,
      activitySlot: undefined,
      activityThread: undefined,
      activityTurn: undefined,
      activityTurnKey: undefined,
      activityCollapsedSeen: false,
      activityCompleteAtFirstDraftCount: 0,
      activityCapturedAt: undefined,
      activityCompleteSeen: false,
      activityDisconnectedAt: undefined,
      activityDisconnectedSamples: 0,
      activityEmptyReadableSamples: 0,
      activityThinkingSeen: false,
      activityTransparentSamples: 0,
      activityTypingSeen: false,
      activityZeroAreaSamples: 0,
      article: undefined,
      articleDisconnectedSamples: 0,
      canonicalAt: undefined,
      canonicalArticle: undefined,
      canonicalSeen: false,
      commitToNextPaintSamples: 0,
      draftMutationCount: 0,
      draftNonPrefixSamples: 0,
      draftStrictGrowthCount: 0,
      draftTextRegressionSamples: 0,
      emptyReplySamples: 0,
      existingActivities: new Set(
        document.querySelectorAll('[data-slot="ai-activity"]')
      ),
      existingCanonicalMessages: new Set(
        document.querySelectorAll(
          'article[data-slot="chat-assistant-output"][data-message-id]'
        )
      ),
      existingFailedRows: new Set(
        document.querySelectorAll('[data-testid="chat-failed-row"]')
      ),
      firstDraftAt: undefined,
      frameSamples: 0,
      generationFailed: false,
      lastDraftAt: undefined,
      lastProjectedDraftText: "",
      lastRenderedDraftText: "",
      longTaskCount: 0,
      longTaskObserver: undefined,
      longTaskObserverSupported: false,
      markdown: undefined,
      markdownTransparentSamples: 0,
      maxCommitToNextPaintMs: 0,
      maxDraftGapMs: 0,
      maxLongTaskDurationMs: 0,
      mutationObserver: undefined as unknown as MutationObserver,
      paintRafId: undefined,
      rafId: 0,
      projectionUnsubscribe: undefined,
      running: true,
      sample: () => {},
      startedAt: performance.now(),
      stop: () => {},
      transparentReplySamples: 0,
      zeroAreaReplySamples: 0,
    };

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
    const isTransparent = (element: HTMLElement) => {
      const style = window.getComputedStyle(element);
      return (
        style.display === "none" ||
        style.visibility === "hidden" ||
        Number(style.opacity) <= 0.001
      );
    };
    // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
    const hasZeroArea = (element: HTMLElement) => {
      const rect = element.getBoundingClientRect();
      return rect.width <= 0 || rect.height <= 0;
    };
    const sampleDraftText = () => {
      if (
        !probe.article ||
        !probe.markdown ||
        probe.article.getAttribute("data-testid") !== "chat-assistant-draft"
      ) {
        return false;
      }
      const nextText = probe.markdown.innerText.trim();
      const previousText = probe.lastRenderedDraftText;
      if (!nextText || nextText === previousText) return false;

      const now = performance.now();
      probe.draftMutationCount += 1;
      if (probe.lastDraftAt !== undefined) {
        probe.maxDraftGapMs = Math.max(probe.maxDraftGapMs, now - probe.lastDraftAt);
      }
      probe.lastDraftAt = now;
      probe.lastRenderedDraftText = nextText;
      return (
        previousText.length === 0 ||
        (nextText.length > previousText.length && nextText.startsWith(previousText))
      );
    };
    const captureReply = () => {
      if (probe.article) return;
      const candidate = document.querySelector<HTMLElement>(
        'article[data-testid="chat-assistant-draft"]'
      );
      const markdown = candidate?.querySelector<HTMLElement>(".markdown-stream");
      if (!candidate || !markdown || markdown.innerText.trim().length === 0) return;

      probe.article = candidate;
      probe.markdown = markdown;
      probe.firstDraftAt = performance.now();
      const currentActivity = Array.from(
        document.querySelectorAll<HTMLElement>(
          '.comma-chat-activity-slot[data-active="true"] [data-slot="ai-activity"]'
        )
      ).at(-1);
      const disclosure = currentActivity?.querySelector<HTMLElement>(
        ".comma-ai-activity-summary"
      );
      if (
        currentActivity?.dataset.phase === "thinking" &&
        currentActivity.dataset.status === "complete" &&
        disclosure?.getAttribute("aria-expanded") === "false" &&
        (probe.activity === undefined || probe.activity === currentActivity)
      ) {
        probe.activityCompleteAtFirstDraftCount += 1;
      }
    };
    const sampleActivity = () => {
      if (!probe.activity) {
        const candidate = Array.from(
          document.querySelectorAll<HTMLElement>('[data-slot="ai-activity"]')
        ).find(
          (activity) =>
            !probe.existingActivities.has(activity) ||
            activity.dataset.status === "running" ||
            activity.dataset.status === "failed"
        );
        if (candidate) {
          probe.activity = candidate;
          probe.activityCapturedAt = performance.now();
          probe.activityRoute =
            candidate.closest<HTMLElement>(".comma-chat-route") ?? undefined;
          probe.activitySlot =
            candidate.closest<HTMLElement>(".comma-chat-activity-slot") ?? undefined;
          probe.activityThread =
            candidate.closest<HTMLElement>(".comma-chat-thread-zone") ?? undefined;
          probe.activityTurn =
            candidate.closest<HTMLElement>("[data-turn-key]") ?? undefined;
          probe.activityTurnKey = probe.activityTurn?.dataset.turnKey;
        }
      }
      const activity = probe.activity;
      if (!activity) return;
      if (!activity.isConnected) {
        probe.activityDisconnectedAt ??= performance.now();
        probe.activityDisconnectedSamples += 1;
        return;
      }

      const phase = activity.dataset.phase;
      const status = activity.dataset.status;
      if (status === "failed") probe.generationFailed = true;
      if (phase === "thinking" && status === "running") {
        probe.activityThinkingSeen = true;
      }
      if (phase === "messaging" && status === "running") {
        probe.activityTypingSeen = true;
      }
      if (status === "complete") {
        probe.activityCompleteSeen = true;
        const disclosure = activity.querySelector<HTMLElement>(
          ".comma-ai-activity-summary"
        );
        if (disclosure?.getAttribute("aria-expanded") === "false") {
          probe.activityCollapsedSeen = true;
        }
      }

      const readableLayers = Array.from(
        activity.querySelectorAll<HTMLElement>(".comma-ai-activity-text-layer")
      ).filter((layer) => layer.innerText.trim().length > 0);
      if (readableLayers.some((layer) => /\bTyping\b/.test(layer.innerText))) {
        // Keep the real-provider artifact content-free: only retain this boolean.
        probe.activityTypingSeen = true;
      }
      if (readableLayers.length === 0) {
        probe.activityEmptyReadableSamples += 1;
      } else if (
        isTransparent(activity) ||
        readableLayers.every((layer) => isTransparent(layer))
      ) {
        probe.activityTransparentSamples += 1;
      }
      if (hasZeroArea(activity)) probe.activityZeroAreaSamples += 1;
    };

    probe.sample = () => {
      captureReply();
      sampleActivity();

      const canonicalArticle = Array.from(
        document.querySelectorAll<HTMLElement>(
          'article[data-slot="chat-assistant-output"][data-message-id]'
        )
      ).find((candidate) => !probe.existingCanonicalMessages.has(candidate));
      if (canonicalArticle) {
        probe.canonicalArticle = canonicalArticle;
        probe.canonicalSeen = true;
        probe.canonicalAt ??= performance.now();
      }

      if (
        Array.from(document.querySelectorAll('[data-testid="chat-failed-row"]')).some(
          (row) => !probe.existingFailedRows.has(row)
        )
      ) {
        probe.generationFailed = true;
      }

      const article = probe.article;
      const markdown = probe.markdown;
      if (!article || !markdown) return;
      probe.frameSamples += 1;
      if (!article.isConnected || !markdown.isConnected) {
        if (!probe.canonicalSeen) {
          probe.articleDisconnectedSamples += 1;
        }
        return;
      }

      if (markdown.innerText.trim().length === 0) probe.emptyReplySamples += 1;
      if (isTransparent(article)) probe.transparentReplySamples += 1;
      if (isTransparent(markdown)) probe.markdownTransparentSamples += 1;
      if (hasZeroArea(article) || hasZeroArea(markdown)) {
        probe.zeroAreaReplySamples += 1;
      }
    };

    const scheduleCommitToPaintSample = () => {
      if (
        probe.paintRafId !== undefined ||
        document.visibilityState !== "visible" ||
        !document.hasFocus()
      ) {
        return;
      }
      const committedAt = performance.now();
      probe.paintRafId = window.requestAnimationFrame(() => {
        probe.paintRafId = undefined;
        if (document.visibilityState !== "visible" || !document.hasFocus()) {
          return;
        }
        // rAF is the next visible frame boundary; the callback itself precedes paint.
        probe.commitToNextPaintSamples += 1;
        probe.maxCommitToNextPaintMs = Math.max(
          probe.maxCommitToNextPaintMs,
          performance.now() - committedAt
        );
      });
    };
    probe.mutationObserver = new MutationObserver((records) => {
      probe.sample();
      const activeDraft = probe.article;
      const markdown = probe.markdown;
      const hasDraftTextCommit = Boolean(
        activeDraft?.getAttribute("data-testid") === "chat-assistant-draft" &&
        markdown &&
        records.some(({ target }) => target === markdown || markdown.contains(target))
      );
      if (hasDraftTextCommit && sampleDraftText()) {
        scheduleCommitToPaintSample();
      }
    });
    probe.mutationObserver.observe(document.body, {
      attributes: true,
      characterData: true,
      childList: true,
      subtree: true,
    });

    if (
      typeof PerformanceObserver !== "undefined" &&
      PerformanceObserver.supportedEntryTypes.includes("longtask")
    ) {
      probe.longTaskObserver = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (
            probe.firstDraftAt === undefined ||
            entry.startTime + entry.duration < probe.firstDraftAt
          ) {
            continue;
          }
          probe.longTaskCount += 1;
          probe.maxLongTaskDurationMs = Math.max(
            probe.maxLongTaskDurationMs,
            entry.duration
          );
        }
      });
      probe.longTaskObserver.observe({ entryTypes: ["longtask"] });
      probe.longTaskObserverSupported = true;
    }

    const bridge = (
      window as unknown as {
        commaNative: {
          chat: {
            state: {
              subscribe: (
                listener: (envelope: { snapshot: ChatRuntimeSnapshot }) => void,
                input: { session: SessionProductLease }
              ) => () => void;
            };
          };
        };
      }
    ).commaNative;
    probe.projectionUnsubscribe = bridge.chat.state.subscribe(
      ({ snapshot }) => {
        const draft = snapshot.sessions
          .flatMap((runtimeSession) => [
            runtimeSession.state.assistantDraft,
            ...(runtimeSession.surfaceProjections ?? []).map(
              (surface) => surface.state.assistantDraft
            ),
          ])
          .find((candidate) => candidate !== undefined);
        const nextText = draft?.text ?? "";
        if (!nextText || nextText === probe.lastProjectedDraftText) return;
        const previousText = probe.lastProjectedDraftText;
        if (previousText) {
          if (
            nextText.length > previousText.length &&
            nextText.startsWith(previousText)
          ) {
            probe.draftStrictGrowthCount += 1;
          } else if (nextText.length < previousText.length) {
            probe.draftTextRegressionSamples += 1;
          } else {
            probe.draftNonPrefixSamples += 1;
          }
        }
        probe.lastProjectedDraftText = nextText;
      },
      { session }
    );

    const sampleFrame = () => {
      probe.sample();
      if (probe.running) probe.rafId = window.requestAnimationFrame(sampleFrame);
    };
    probe.rafId = window.requestAnimationFrame(sampleFrame);
    probe.stop = () => {
      if (!probe.running) return;
      probe.running = false;
      window.cancelAnimationFrame(probe.rafId);
      if (probe.paintRafId !== undefined) {
        window.cancelAnimationFrame(probe.paintRafId);
        probe.paintRafId = undefined;
      }
      probe.mutationObserver.disconnect();
      probe.longTaskObserver?.disconnect();
      probe.projectionUnsubscribe?.();
      probe.projectionUnsubscribe = undefined;
      probe.lastProjectedDraftText = "";
      probe.lastRenderedDraftText = "";
    };
    scope.commaRealChatStreamProbe = probe;
  }, productLease);
}

function realChatStreamTerminalState(appWindow: Page) {
  return appWindow.evaluate(() => {
    const probe = (
      window as typeof window & { commaRealChatStreamProbe?: RealChatStreamProbe }
    ).commaRealChatStreamProbe;
    if (!probe) throw new Error("Real chat stream probe was not installed.");
    probe.sample();
    const activeSurfaces = Array.from(
      document.querySelectorAll<HTMLElement>(
        '.comma-chat-activity-slot[data-active="true"] [data-slot="ai-activity"]'
      )
    );
    const currentActivity = activeSurfaces.at(-1);
    const currentDisclosure = currentActivity?.querySelector<HTMLElement>(
      ".comma-ai-activity-summary"
    );
    const probeSlot = probe.activitySlot;
    const currentSlot = currentActivity?.closest<HTMLElement>(
      ".comma-chat-activity-slot"
    );
    const probeTurn = probe.activityTurn;
    const currentTurn = currentActivity?.closest<HTMLElement>("[data-turn-key]");
    const currentThread = currentActivity?.closest<HTMLElement>(
      ".comma-chat-thread-zone"
    );
    const currentRoute = currentActivity?.closest<HTMLElement>(".comma-chat-route");
    return {
      activityCollapsed: probe.activityCollapsedSeen,
      activityComplete: probe.activityCompleteSeen,
      canonicalSeen: probe.canonicalSeen,
      currentActivityCollapsed:
        currentDisclosure?.getAttribute("aria-expanded") === "false",
      currentActivityCount: activeSurfaces.length,
      currentActivityPhase: currentActivity?.dataset.phase,
      currentActivityStatus: currentActivity?.dataset.status,
      disconnectBeforeCanonical:
        probe.activityDisconnectedAt !== undefined &&
        (probe.canonicalAt === undefined ||
          probe.activityDisconnectedAt < probe.canonicalAt),
      disconnectBeforeFirstDraft:
        probe.activityDisconnectedAt !== undefined &&
        (probe.firstDraftAt === undefined ||
          probe.activityDisconnectedAt < probe.firstDraftAt),
      generationFailed: probe.generationFailed,
      probeActivityConnected: probe.activity?.isConnected ?? false,
      probeMatchesCurrent: probe.activity === currentActivity,
      probeRouteConnected: probe.activityRoute?.isConnected ?? false,
      probeRouteMatchesCurrent: probe.activityRoute === currentRoute,
      probeSlotConnected: probeSlot?.isConnected ?? false,
      probeSlotMatchesCurrent: probeSlot === currentSlot,
      probeThreadConnected: probe.activityThread?.isConnected ?? false,
      probeThreadMatchesCurrent: probe.activityThread === currentThread,
      probeTurnConnected: probeTurn?.isConnected ?? false,
      probeTurnKeyMatchesCurrent:
        probe.activityTurnKey !== undefined &&
        probe.activityTurnKey === currentTurn?.dataset.turnKey,
      probeTurnMatchesCurrent: probeTurn === currentTurn,
    };
  });
}

async function waitForRealChatStreamTerminal(appWindow: Page, timeout: number) {
  await appWindow.waitForFunction(
    () => {
      const probe = (
        window as typeof window & { commaRealChatStreamProbe?: RealChatStreamProbe }
      ).commaRealChatStreamProbe;
      probe?.sample();
      return Boolean(probe?.canonicalSeen || probe?.generationFailed);
    },
    undefined,
    { polling: 100, timeout }
  );
  const terminal = await realChatStreamTerminalState(appWindow);
  if (terminal.generationFailed) {
    throw new Error(
      "Real Comma generation failed before a canonical reply; inspect sanitized provider/server telemetry."
    );
  }
}

function finishRealChatStreamProbe(appWindow: Page) {
  return appWindow.evaluate(() => {
    const scope = window as typeof window & {
      commaRealChatStreamProbe?: RealChatStreamProbe;
    };
    const probe = scope.commaRealChatStreamProbe;
    if (!probe) throw new Error("Real chat stream probe was not installed.");
    probe.sample();
    probe.stop();
    delete scope.commaRealChatStreamProbe;

    const canonicalMessages = Array.from(
      document.querySelectorAll<HTMLElement>(
        'article[data-slot="chat-assistant-output"][data-message-id]'
      )
    ).filter((candidate) => !probe.existingCanonicalMessages.has(candidate));
    const finalArticle = canonicalMessages.find(
      (candidate) => candidate === probe.canonicalArticle
    );
    const currentActivity = document.querySelector<HTMLElement>(
      '[data-slot="ai-activity"]'
    );
    // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
    const rounded = (value: number) => Math.round(value * 10) / 10;

    return {
      activityCollapsedSeen: probe.activityCollapsedSeen,
      activityCompleteAtFirstDraftCount: probe.activityCompleteAtFirstDraftCount,
      activityCompleteSeen: probe.activityCompleteSeen,
      activityDisconnectedSamples: probe.activityDisconnectedSamples,
      activityEmptyReadableSamples: probe.activityEmptyReadableSamples,
      activityIdentityPreserved: currentActivity === probe.activity,
      activityThinkingSeen: probe.activityThinkingSeen,
      activityTransparentSamples: probe.activityTransparentSamples,
      activityTypingSeen: probe.activityTypingSeen,
      activityZeroAreaSamples: probe.activityZeroAreaSamples,
      articleDisconnectedSamples: probe.articleDisconnectedSamples,
      canonicalSeen: probe.canonicalSeen,
      commitToNextPaintSamples: probe.commitToNextPaintSamples,
      draftMutationCount: probe.draftMutationCount,
      draftNonPrefixSamples: probe.draftNonPrefixSamples,
      draftStrictGrowthCount: probe.draftStrictGrowthCount,
      draftTextRegressionSamples: probe.draftTextRegressionSamples,
      draftToCanonicalMs:
        probe.firstDraftAt !== undefined && probe.canonicalAt !== undefined
          ? rounded(probe.canonicalAt - probe.firstDraftAt)
          : null,
      emptyReplySamples: probe.emptyReplySamples,
      finalResponseCount: canonicalMessages.length,
      firstDraftLatencyMs:
        probe.firstDraftAt === undefined
          ? null
          : rounded(probe.firstDraftAt - probe.startedAt),
      frameSamples: probe.frameSamples,
      generationFailed: probe.generationFailed,
      longTaskCount: probe.longTaskCount,
      longTaskObserverSupported: probe.longTaskObserverSupported,
      markdownTransparentSamples: probe.markdownTransparentSamples,
      maxCommitToNextPaintMs: rounded(probe.maxCommitToNextPaintMs),
      maxDraftGapMs: rounded(probe.maxDraftGapMs),
      maxLongTaskDurationMs: rounded(probe.maxLongTaskDurationMs),
      finalCanonicalVisible: Boolean(finalArticle?.isConnected),
      transparentReplySamples: probe.transparentReplySamples,
      zeroAreaReplySamples: probe.zeroAreaReplySamples,
    };
  });
}

function discardRealChatStreamProbe(appWindow: Page) {
  return appWindow.evaluate(() => {
    const scope = window as typeof window & {
      commaRealChatStreamProbe?: RealChatStreamProbe;
    };
    scope.commaRealChatStreamProbe?.stop();
    delete scope.commaRealChatStreamProbe;
  });
}

function runtimeMessage(
  messageId: string,
  role: "assistant" | "user",
  text: string,
  clientRequestId?: string
) {
  return {
    actor_type: role === "assistant" ? "agent" : "user",
    ...(clientRequestId ? { client_request_id: clientRequestId } : {}),
    content: [{ type: "text", text }],
    created_at: 1_720_000_000,
    kind: "message",
    message_id: messageId,
  };
}
