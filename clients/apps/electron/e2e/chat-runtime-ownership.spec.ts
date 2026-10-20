import type { Server } from "node:http";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { expect } from "../../../e2e/helpers/native-expect";
import { closeElectronTestApp } from "./close-electron-test-app";
import { type Locator, type Page } from "@playwright/test";
import {
  electron,
  loadedMainWindow,
  openedWindow,
  test,
  type SharedElectronApp,
} from "./electron-test";
import { quitElectronApp } from "./electron-operations";
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
import { chmod, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { crc32, deflateSync } from "node:zlib";
import type { SessionBridge } from "@comma/native-bridge";
import { build } from "vite";
import { getCommaReleaseConfig } from "../src/release-config";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { findElectronWindowByRole } from "../src/test-support/electron-window";
import {
  runtimeAccountA,
  runtimeAccountB,
  startChatRuntimeStub,
} from "./chat-runtime-stub";

const clientsRoot = resolve(process.cwd());
const electronAppDir = resolve(clientsRoot, "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const rendererOutDir = resolve(electronAppDir, ".vite/renderer/main_window");
const fixtureRoot = resolve(electronAppDir, "e2e/fixtures/chat-runtime");
const fixtureUrl = "assets://./chat-runtime-fixture.html";
const electronProductName = getCommaReleaseConfig().productName;
const onePixelPng = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64"
);
/**
 * A solid grey 8-bit PNG of `width`×`height`, encoded in the test process. Encoding a phone-sized image in Main
 * (nativeImage) allocated enough to collect the promise the evaluate awaited ("Promise was collected").
 */
function solidGreyPng(width: number, height: number): Buffer {
  const row = Buffer.alloc(1 + width, 0x80);
  row[0] = 0; // no filter
  const raw = Buffer.alloc(row.length * height);
  for (let y = 0; y < height; y++) row.copy(raw, y * row.length);
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8; // bit depth
  header[9] = 0; // greyscale
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", header),
    pngChunk("IDAT", deflateSync(raw)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}
/** A PNG chunk: its length, type, data and CRC. */
function pngChunk(type: string, data: Buffer): Buffer {
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, crc]);
}
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
    await closeElectronTestApp(launched.app);
    await stub.close();
    await rm(userDataDir, { force: true, recursive: true });
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
    await closeElectronTestApp(launched.app);
    await stub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test(
  "native images upload, preview in the Composer, and use the sent image group",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const stub = await startChatRuntimeStub();
    const sourceDirectory = await mkdtemp(
      join(await realpath(tmpdir()), "comma-uploaded-image-presentation-e2e-")
    );
    const launched = await signInShared(sharedElectron, stub.server, runtimeAccountB);
    const selectedImageNames = Array.from(
      { length: 4 },
      (_, index) => `product-image-${index + 1}.png`
    );
    const highResolutionImageName = selectedImageNames[0]!;
    const sourcePaths = selectedImageNames.map((name) => join(sourceDirectory, name));

    try {
      const highResolutionImageBytes = await readFile(highResolutionPreviewFixture);
      expect(highResolutionImageBytes.byteLength).toBeLessThan(
        chatAttachmentUploadMaxBytes
      );
      // A phone-sized source must keep its own preview instead of a placeholder.
      const phonePhotoBytes = solidGreyPng(5_712, 4_284);
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
      // Main's file picker is the test's until it ends (`restorePicker`).
      await launched.app.evaluate(({ dialog }, selectedPaths) => {
        type PickerOwnerHost = typeof globalThis & {
          commaPickerOwner?: unknown;
          commaRestorePicker?: () => void;
        };
        const { showOpenDialog } = dialog;
        (globalThis as PickerOwnerHost).commaRestorePicker = () => {
          Reflect.deleteProperty(dialog, "showOpenDialog");
          if (dialog.showOpenDialog !== showOpenDialog)
            dialog.showOpenDialog = showOpenDialog;
          delete (globalThis as PickerOwnerHost).commaPickerOwner;
          delete (globalThis as PickerOwnerHost).commaRestorePicker;
        };
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
      // The picker opens as a sheet in front of the window whose + was clicked. Asked of Main once it has drawn the
      // previews: an evaluate in Main while it decodes a phone-sized image can lose its promise to the collector
      // ("Promise was collected").
      const appBrowserWindow = await launched.app.browserWindow(appWindow);
      expect(
        await appBrowserWindow.evaluate((window) => {
          type PickerOwnerHost = typeof globalThis & { commaPickerOwner?: unknown };
          return (globalThis as PickerOwnerHost).commaPickerOwner === window;
        })
      ).toBe(true);

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
      await expect(
        imageGroup.locator('[data-stack-pos="hidden-right"] img')
      ).toHaveCount(0);
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
      await restorePicker(launched.app);
      await stub.close();
      await rm(sourceDirectory, { force: true, recursive: true });
    }
  }
);

test("Google login uses the Main-owned auth origin", { tag: "@mac" }, async () => {
  const trustedStub = await startChatRuntimeStub();
  const rendererTarget = await startChatRuntimeStub();
  const launched = await launchRuntimeApp({
    baseUrl: trustedStub.baseUrl,
    email: runtimeAccountB.email,
    googleIdToken: "runtime-google-id-token",
  });

  try {
    const appWindow = await loadedMainWindow(launched.app);
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

    // A failed Google start and its retry are the core's (electron-session.test.ts) and the login screen's
    // (LoginScreen.test.tsx); here the sign-in goes through Main's origin only.
    await appWindow.getByRole("button", { name: "Sign in with Google" }).click();
    await expect.poll(() => sessionSignedIn(appWindow)).toBe(true);

    expect(rendererTarget.requests).toEqual([]);
    await expect
      .poll(() => trustedStub.googleAttempts)
      .toEqual([{ platform: "electron" }]);
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
    await closeElectronTestApp(launched.app);
    await rendererTarget.close();
    await trustedStub.close();
    await rm(launched.userDataDir, { force: true, recursive: true });
  }
});

test(
  "unsafe quit is vetoed until unresolved issued cleanup becomes durable",
  { tag: "@mac" },
  async () => {
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
      const appWindow = await loadedMainWindow(launched.app);
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
      await quitElectronApp(launched.app);
      await expect
        .poll(() => shutdownBlockedMessages(launched.app))
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
      await quitElectronApp(launched.app);
      await secondQuit;
      firstAppClosed = true;

      restarted = await launchRuntimeApp({
        baseUrl: stub.baseUrl,
        email: runtimeAccountA.email,
        userDataDir: launched.userDataDir,
      });
      const restartedWindow = await loadedMainWindow(restarted.app);
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
        await closeElectronTestApp(launched.app).catch(() => {});
      }
      if (restarted) await closeElectronTestApp(restarted.app).catch(() => {});
      await stub.close();
      await rm(launched.userDataDir, { force: true, recursive: true });
    }
  }
);

test(
  "local passwordless login keeps the bearer in Main through bootstrap and revocation",
  { tag: "@mac" },
  async () => {
    test.skip(
      process.env.COMMA_ELECTRON_LOCAL_AUTH_SMOKE !== "1",
      "requires the explicit local Comma backend and Mailpit smoke opt-in"
    );

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
      const appWindow = await loadedMainWindow(launched.app);
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
      if (launched) await closeElectronTestApp(launched.app).catch(() => {});
      await bestEffortRevokeServerSession(apiBaseUrl, capturedBearer);
      if (launched) {
        await rm(launched.userDataDir, { force: true, recursive: true });
      }
    }
  }
);

test.describe("real Comma chat streaming smoke", () => {
  test("real provider streams one continuous reply through Electron", async () => {
    test.skip(
      process.env.COMMA_ELECTRON_REAL_CHAT_SMOKE !== "1",
      "requires the explicit real Comma provider and Mailpit smoke opt-in"
    );

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
      appWindow = await loadedMainWindow(launched.app);
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
          .poll(() => realChatStreamTerminalState(appWindow!))
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
      if (launched) await closeElectronTestApp(launched.app).catch(() => {});
      await bestEffortRevokeServerSession(apiBaseUrl, capturedBearer);
      if (launched) {
        await rm(launched.userDataDir, { force: true, recursive: true });
      }
    }
  });
});

test(
  "a durable sign-out failure becomes indeterminate until restart follows the durable account",
  { tag: "@mac" },
  async () => {
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
      // The client core shows no conversation of a session it no longer works for.
      await expect(chatStateForLease(appWindow, staleLease)).rejects.toThrow(
        "The chat session lease is missing or stale."
      );

      await chmod(launched.userDataDir, 0o700);
      await chmod(secureSessionFile, 0o600);
      permissionsRestricted = false;
      await closeElectronTestApp(launched.app);
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
        await closeElectronTestApp(launched.app).catch(() => {});
      }
      if (restarted) await closeElectronTestApp(restarted.app).catch(() => {});
      await stub.close();
      await rm(launched.userDataDir, { force: true, recursive: true });
    }
  }
);

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

// protocol.test.ts and electron-session.test.ts cover each endpoint and status on controlled inputs.
// This case keeps the real Main -> utility core -> window handoff.
test(
  "current ensure 401 signs out the active Electron session",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const stub = await startChatRuntimeStub({ ensureFailureStatus: 401 });
    const launched = await signInShared(sharedElectron, stub.server, runtimeAccountB);

    try {
      const appWindow = await loadedMainWindow(launched.app);
      await expect
        .poll(
          () =>
            stub.requests.filter(
              (request) =>
                request.method === "POST" &&
                request.path ===
                  `/v1/comma/groups/${runtimeAccountB.groupId}/assistant-chat` &&
                request.token === runtimeAccountB.token
            ).length
        )
        .toBeGreaterThan(0);
      await expect.poll(() => sessionSignedIn(appWindow)).toBe(false);
      await expect(
        appWindow.getByRole("heading", { name: "Welcome to Comma" })
      ).toBeVisible();
    } finally {
      await stub.close();
    }
  }
);

for (const blockedPhase of ["quit", "window cleanup"] as const) {
  test(`blocked Electron ${blockedPhase} reports cleanup failure and releases the process`, async () => {
    const stub = await startChatRuntimeStub();
    const launched = await launchRuntimeApp({
      baseUrl: stub.baseUrl,
      email: runtimeAccountB.email,
      token: runtimeAccountB.token,
    });
    const child = launched.app.process();
    let watchdog: ReturnType<typeof setTimeout> | undefined;
    try {
      if (blockedPhase === "quit") {
        await launched.app.evaluate(({ app }) => {
          app.on("before-quit", (event) => event.preventDefault());
        });
      }
      const beforeClose =
        blockedPhase === "window cleanup"
          ? () => launched.app.evaluate(() => new Promise<void>(() => {}))
          : undefined;
      // The hung-Main diagnostics are not under test: on macOS `sample` alone
      // takes three seconds, which outlasts the watchdog below.
      const result = await Promise.race([
        closeElectronTestApp(launched.app, 500, beforeClose, () => undefined).then(
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
      // SIGKILL stops only the browser process. Its Chromium helpers notice that
      // later and can still write into the profile, so the removal below would
      // race them. Playwright starts Electron as a process-group leader, and
      // the helpers stay in that group: remove the profile once it is empty.
      await expect
        .poll(() => {
          try {
            process.kill(-child.pid!, 0);
            return false;
          } catch (error) {
            return (error as NodeJS.ErrnoException).code === "ESRCH";
          }
        })
        .toBe(true);
      await rm(launched.userDataDir, { force: true, recursive: true });
    }
  });
}

test(
  "account replacement revokes account A in every product window",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const stub = await startChatRuntimeStub();
    const launched = await signInShared(sharedElectron, stub.server, runtimeAccountA);

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
      await stub.close();
    }
  }
);

// recovery.test.ts and ConversationRuntime.test.tsx cover failures and reconnects on fake clocks.
// Keep a failed write, explicit retry, and server EOF across the real process boundary.
test(
  "Main preserves one retryable send after a real 500 and propagates stream reconnects",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const stub = await startChatRuntimeStub({
      controlledAccountBEvents: true,
      deferAccountBResolution: true,
      messageFailureStatus: 500,
    });
    const launched = await signInShared(sharedElectron, stub.server, runtimeAccountB);

    try {
      const appWindow = await productWindow(launched.app);
      const content = appWindow.getByRole("region", { name: "Content" });
      const composer = content.getByRole("textbox", { name: "AI prompt" });
      const prompt = "Runtime 500 failed send";
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
      await expect(failedRow).toContainText("Send failed");
      await expect(failedRow).not.toContainText("runtime_message_500");
      await expect(failedRow.getByRole("button", { name: "Retry" })).toBeVisible();

      await failedRow.getByRole("button", { name: "Retry" }).click();
      await expect.poll(() => stub.messageAttempts.length).toBe(2);
      expect(stub.messageAttempts[0]?.body.client_request_id).toBeTruthy();
      expect(stub.messageAttempts[1]?.body.client_request_id).toBe(
        stub.messageAttempts[0]?.body.client_request_id
      );

      // Main must carry an upstream EOF to the utility process, then deliver the new stream.
      await expect.poll(() => stub.accountBEventClientCount).toBe(1);
      const snapshot = {
        conversation_id: runtimeAccountB.conversationId,
        group_id: runtimeAccountB.groupId,
        messages: [
          runtimeMessage("runtime-reconnect-source", "user", "Reconnect the reply"),
        ],
        status: "open",
        type: "snapshot",
      };
      const participant = {
        conversation_id: runtimeAccountB.conversationId,
        participant_id: "runtime-reconnect-participant",
        state: "active",
        status: "is thinking...",
        type: "participant_status",
        updated_at: 1,
      };
      stub.emitAccountBEvent("snapshot", snapshot);
      stub.emitAccountBEvent("participant_status", participant);
      const participantStatus = content.getByTestId("participant-status-slot");
      await expect(participantStatus).toHaveAttribute("data-state", "active");
      const streamCount = stub.accountBEventStreamCount;
      stub.disconnectAccountBEvents();
      await expect
        .poll(() => stub.accountBEventStreamCount)
        .toBeGreaterThan(streamCount);
      await expect.poll(() => stub.accountBEventClientCount).toBe(1);
      stub.emitAccountBEvent("snapshot", snapshot);
      stub.emitAccountBEvent("participant_status", {
        ...participant,
        state: "stopped",
        status: "",
        updated_at: 2,
      });
      await expect(participantStatus).toHaveAttribute("data-state", "stopped");
      await expect(participantStatus).toHaveAttribute("data-active", "false");
    } finally {
      await stub.close();
    }
  }
);

// Its own app: on the worker's shared app, signed in after launch, a second event stream to the stub stayed open
// after `conversation_invalidated` in 2 of 5 local suite runs under heavy load (not yet explained).
test(
  "Participant draft survives a mismatched cancel and settles into the next Message",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const stub = await startChatRuntimeStub({ controlledAccountBEvents: true });
    const launched = await signInShared(sharedElectron, stub.server, runtimeAccountB);
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

      const streamsBeforeCancel = stub.accountBEventStreamCount;
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
      // The mismatched cancel makes the conversation listen again; the snapshot goes to the stream it opens (the
      // client core's goes through Main, so it is open a moment later than one Main held itself). The stream before
      // can still be counted while it closes: wait for the new one, and for it alone.
      await expect
        .poll(() => stub.accountBEventStreamCount)
        .toBeGreaterThan(streamsBeforeCancel);
      await expect.poll(() => stub.accountBEventClientCount).toBe(1);
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
      await stub.close();
    }
  }
);

test(
  "renderer refresh restores retained canonical conversation history",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const stub = await startChatRuntimeStub({ controlledAccountBEvents: true });
    const launched = await signInShared(sharedElectron, stub.server, runtimeAccountB);
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
      await stub.close();
    }
  }
);

test(
  "Main cold start and restart restore canonical conversation history",
  { tag: "@mac" },
  async () => {
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
  }
);

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

/**
 * The worker's shared app (`sharedElectron`) on the stub's `server`, signed in as `account` through its email sign-in: the stub
 * answers it with the account's bearer.
 */
async function signInShared(
  shared: SharedElectronApp,
  server: Server,
  account: typeof runtimeAccountA | typeof runtimeAccountB
) {
  shared.useApi(server);
  await shared.signIn({ email: account.email, userId: account.userId });
  return { app: shared.app };
}

/** Puts back Main's file picker a test replaced, with what the replacement kept. */
async function restorePicker(app: Awaited<ReturnType<typeof electron.launch>>) {
  await app.evaluate(() =>
    (
      globalThis as typeof globalThis & { commaRestorePicker?: () => void }
    ).commaRestorePicker?.()
  );
}

async function openSecondProductWindow(
  app: Awaited<ReturnType<typeof electron.launch>>,
  firstWindow: Page
) {
  const secondWindow = await openedWindow(app, () =>
    firstWindow.evaluate(() =>
      (
        window as unknown as {
          commaNative: {
            windows: { create: (input: { route: string }) => Promise<unknown> };
          };
        }
      ).commaNative.windows.create({ route: "/" })
    )
  );
  await expect(
    secondWindow.getByRole("complementary", { name: "App sidebar" })
  ).toBeVisible();
  return secondWindow;
}

async function signInAsAccountB(appWindow: Page) {
  await signInWithEmail(appWindow, runtimeAccountB.email, async () => "654321");
}

function requestEmailLoginThroughNative(
  appWindow: Page,
  email: string,
  expected?: SessionAbsenceExpectation
) {
  return appWindow.evaluate(
    async ({ email: inputEmail, expected: capturedExpectation }) => {
      const host = window as unknown as {
        commaCore: { call: (name: string, params: unknown) => Promise<unknown> };
        commaNative: { session: SessionBridge };
      };
      const lifecycle = await host.commaNative.session.state.get();
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
      // The client core runs the sign-in; Main keeps the bearer it issues.
      const result = (await host.commaCore.call("session.email.request", {
        email: inputEmail,
        expected: exactExpectation,
      })) as
        | { ok: true; value: { attempt: SessionAuthAttemptRef; challengeId: string } }
        | { ok: false; error: { code: string } };
      if (!result.ok) {
        throw new Error(`Core email login failed: ${result.error.code}`);
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
          commaCore: { call: (name: string, params: unknown) => Promise<unknown> };
        }
      ).commaCore.call("session.email.verify", {
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

/** The core's chat as this window sees it now, if it is of `session` (refused otherwise, as a window's read is). */
function chatStateForLease(appWindow: Page, session: SessionProductLease) {
  return appWindow.evaluate(async (inputSession) => {
    const value = await new Promise<{
      session: { sessionId: string; audience: string } | null;
      snapshot: ChatRuntimeSnapshot;
    }>((settle, fail) => {
      // The core's chat as this window sees it, once (its value of the `chat` topic).
      const scope = window as unknown as {
        commaCore: {
          subscribe(
            topic: object,
            onValue: (value: unknown) => void,
            onError: (error: unknown) => void
          ): () => void;
        };
        commaNative: { self: { windowId: string } };
      };
      const stop = scope.commaCore.subscribe(
        { topic: "chat", surface: scope.commaNative.self.windowId },
        (shown) => {
          settle(shown as never);
          queueMicrotask(() => stop());
        },
        fail
      );
    });
    if (
      value.session?.sessionId !== inputSession.sessionId ||
      value.session.audience !== inputSession.audience
    )
      throw new Error("The chat session lease is missing or stale.");
    return { session: inputSession, snapshot: value.snapshot };
  }, session);
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

function chatState(appWindow: Page) {
  return appWindow.evaluate(async (): Promise<ChatRuntimeSnapshot> => {
    const host = window as unknown as {
      commaNative: { session: SessionBridge };
    };
    const bridge = { session: host.commaNative.session };
    // The core's startup probe confirms the seeded session; Main's gate follows it.
    const now = await bridge.session.state.get();
    const lifecycle =
      now.phase !== "initializing" && now.phase !== "authenticating"
        ? now
        : await new Promise<Awaited<ReturnType<typeof bridge.session.state.get>>>(
            (settle) => {
              const stop = bridge.session.state.subscribe((current) => {
                if (
                  current.phase === "initializing" ||
                  current.phase === "authenticating"
                )
                  return;
                queueMicrotask(() => stop());
                settle(current);
              });
            }
          );
    if (lifecycle.phase !== "signed_in") {
      throw new Error("Chat state requires a signed-in Session.");
    }
    const value = await new Promise<{
      session: { sessionId: string; audience: string } | null;
      snapshot: ChatRuntimeSnapshot;
    }>((settle, fail) => {
      // The core's chat as this window sees it, once (its value of the `chat` topic).
      const scope = window as unknown as {
        commaCore: {
          subscribe(
            topic: object,
            onValue: (value: unknown) => void,
            onError: (error: unknown) => void
          ): () => void;
        };
        commaNative: { self: { windowId: string } };
      };
      const stop = scope.commaCore.subscribe(
        { topic: "chat", surface: scope.commaNative.self.windowId },
        (shown) => {
          settle(shown as never);
          queueMicrotask(() => stop());
        },
        fail
      );
    });
    if (value.session?.sessionId !== lifecycle.session.sessionId)
      throw new Error("The chat session lease is missing or stale.");
    return value.snapshot;
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

    // The core's chat as this window sees it, each value of it.
    const host = window as unknown as {
      commaCore: {
        subscribe(
          topic: object,
          onValue: (value: unknown) => void,
          onError: (error: unknown) => void
        ): () => void;
      };
      commaNative: { self: { windowId: string } };
    };
    probe.projectionUnsubscribe = host.commaCore.subscribe(
      { topic: "chat", surface: host.commaNative.self.windowId },
      (value: unknown) => {
        const { session: shown, snapshot } = value as {
          session: { sessionId: string } | null;
          snapshot: ChatRuntimeSnapshot;
        };
        if (shown?.sessionId !== session.sessionId) return;
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
      () => undefined
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
