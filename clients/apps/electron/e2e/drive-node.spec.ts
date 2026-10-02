import { _electron as electron, expect, test, type Page } from "@playwright/test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { startSessionProjectionStub } from "../../../e2e/helpers/session-fixture";

/**
 * Drive over the node, end to end through the production renderer, the
 * generated bridge and Main — with the daemon replaced by Main's node in
 * memory (`COMMA_ELECTRON_E2E_SYNCHRONICITY_MODE=fake`). What the demo store
 * cannot show is what this covers: the install's own folder arriving from
 * the node and refusing deletion, bytes read on demand, an upload published
 * through the node, a divergence settled by adopting another device's copy,
 * a pin, and a space another device publishes being mirrored here.
 */
const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const DRIVE_E2E_EMAIL = "drive-node-e2e@example.com";
const DRIVE_E2E_TOKEN = "comma_sess_drive_node_e2e";
const DRIVE_E2E_LARGE_BYTES = 10_000_001;
let sessionStub: Awaited<ReturnType<typeof startSessionProjectionStub>>;

test.describe("drive over the node", () => {
  let testDirectory: string;

  test.beforeAll(async () => {
    sessionStub = await startSessionProjectionStub({ email: DRIVE_E2E_EMAIL });
  });

  test.afterAll(async () => {
    await sessionStub.close();
  });

  test.beforeEach(async () => {
    testDirectory = await mkdtemp(join(tmpdir(), "comma-drive-node-e2e-"));
  });

  test.afterEach(async () => {
    await rm(testDirectory, { force: true, recursive: true });
  });

  test("finds and attaches Drive files through @ without visiting Drive", async () => {
    const stub = await startChatSmokeStub({ sessionEmail: DRIVE_E2E_EMAIL });
    const userDataPath = join(testDirectory, "mentions");
    recordElectronOnboardingCompleted(userDataPath, [stub.userId]);
    const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...env } = process.env;
    const app = await electron.launch({
      args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataPath}`],
      cwd: electronAppDir,
      env: {
        ...env,
        COMMA_API_BASE_URL: stub.baseUrl,
        COMMA_ELECTRON_E2E_SYNCHRONICITY_MODE: "fake",
        COMMA_ELECTRON_STARTUP_SESSION_EMAIL: DRIVE_E2E_EMAIL,
        COMMA_ELECTRON_STARTUP_SESSION_TOKEN: DRIVE_E2E_TOKEN,
        NODE_ENV: "test",
      },
    });
    try {
      const page = await findElectronWindowByNativeRole(app, "main-window");
      await page.waitForLoadState("domcontentloaded");
      const prompt = page.getByRole("textbox", { name: "AI prompt" }).first();
      await expect(prompt).toBeVisible();
      await prompt.click();
      await page.keyboard.type("Summarize @");
      const list = page.getByRole("listbox", { name: "Mentions" });
      const drive = list.getByRole("group").filter({ hasText: "Drive" });
      await expect(drive.getByRole("option", { name: /dot.png/ })).toBeVisible();
      // Commit outside the Drive renderer. The already-mounted composer must
      // discover these files without navigation, focus changes, or reloads.
      await page.evaluate(async () => {
        const node = (
          window as unknown as {
            commaNative: {
              synchronicity: {
                write(input: {
                  space: string;
                  path: string;
                  content: string;
                }): Promise<unknown>;
              };
            };
          }
        ).commaNative.synchronicity;
        for (let i = 0; i < 61; i++)
          await node.write({
            space: "comma-drive",
            path: `generated/deep/report-${String(i).padStart(3, "0")}.txt`,
            content: btoa(`report ${i}`),
          });
      });
      await expect(drive.getByRole("option", { name: /report-060.txt/ })).toBeVisible();
      await expect(drive.getByRole("option")).toHaveCount(6);
      await drive.getByRole("option", { name: "View more" }).click();
      const panel = page.getByRole("dialog", { name: "Drive" });
      const search = panel.getByRole("combobox", { name: "Drive" });
      await expect(panel.getByRole("option", { name: /report-060.txt/ })).toBeVisible();
      // Oldest generated file is beyond the first 50 rows. Search is global.
      await search.fill("report-000");
      await expect(panel.getByRole("option", { name: /report-000.txt/ })).toBeVisible();
      await expect(panel.getByRole("option")).toHaveCount(1);
      await search.fill("no-such-drive-file");
      await expect(panel.getByTestId("ai-input-menu-browse-no-results")).toBeVisible();
      await page.mouse.move(0, 0);
      await search.fill("");
      await expect(panel.getByRole("option", { name: /report-060.txt/ })).toBeVisible();
      // Keyboard navigation reaches the next metadata page, not only the
      // renderer's already loaded chunk.
      await search.press("ArrowUp");
      await search.press("ArrowDown");
      await expect(panel.getByRole("option", { name: /report-000.txt/ })).toHaveCount(
        1
      );
      await search.fill("report-000");
      await panel.getByRole("option", { name: /report-000.txt/ }).click();
      await expect(
        page.getByLabel("Attachments").getByText("report-000.txt")
      ).toBeVisible();
      await expect(page.getByTestId("drive-route")).toHaveCount(0);
      expect(new URL(page.url()).hash).not.toContain("drive");
    } finally {
      await app.close();
      await stub.close();
    }
  });

  test("shows the node's tree, reads, writes, settles and pins through it", async () => {
    const userDataPath = join(testDirectory, "user-data");
    recordElectronOnboardingCompleted(userDataPath, [sessionStub.userId]);
    const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...env } = process.env;
    const app = await electron.launch({
      args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataPath}`],
      cwd: electronAppDir,
      env: {
        ...env,
        COMMA_API_BASE_URL: sessionStub.baseUrl,
        COMMA_ELECTRON_E2E_SYNCHRONICITY_MODE: "fake",
        COMMA_ELECTRON_STARTUP_SESSION_EMAIL: DRIVE_E2E_EMAIL,
        COMMA_ELECTRON_STARTUP_SESSION_TOKEN: DRIVE_E2E_TOKEN,
        NODE_ENV: "test",
      },
    });
    try {
      const page = await openDrive(app);
      const previewText = page.getByTestId("drive-preview-panel").locator("pre");

      // The install's own folder and the space another device publishes,
      // both from the node; the files the node holds, with the divergent one
      // marked. Nothing here comes from the demo store.
      const rail = page.getByTestId("drive-space-rail");
      await expect(rail.getByTestId("drive-space-comma-drive")).toContainText("Drive");
      await expect(rail.getByTestId("drive-space-notes")).toContainText("notes");
      const hello = page.getByTestId("drive-file-synch:comma-drive:hello.txt");
      await expect(hello).toBeVisible();
      await expect(
        page.getByTestId("drive-file-synch:comma-drive:shared.txt")
      ).toContainText("2 Versions");
      await expect(page.getByTestId("drive-folder-notes")).toBeVisible();

      // A space retained only as a replica is readable but not writable on
      // this node. The toolbar and row menu must not advertise mutations the
      // real Synchronicity source contract will reject.
      await rail.getByTestId("drive-space-notes").click();
      const remoteNote = page.getByTestId("drive-file-synch:notes:todo.md");
      await expect(remoteNote).toBeVisible();
      await expect(page.getByTestId("drive-add-files")).toBeDisabled();
      await remoteNote.click({ button: "right" });
      await expect(page.getByRole("menuitem", { name: "Delete" })).toHaveCount(0);
      await page.keyboard.press("Escape");
      await rail.getByTestId("drive-space-comma-drive").click();
      await expect(hello).toBeVisible();

      // Image rows draw themselves without being opened: the list asks the
      // node for the bytes and keeps only a thumbnail — the SVG as it is, the
      // PNG drawn down — so neither row waits for a click.
      for (const name of ["logo.svg", "dot.png"]) {
        const thumbnail = page
          .getByTestId(`drive-file-synch:comma-drive:${name}`)
          .getByTestId("drive-file-thumbnail");
        await expect(thumbnail).toBeVisible();
        await expect
          .poll(() =>
            thumbnail.evaluate((img) => (img as HTMLImageElement).naturalWidth)
          )
          .toBeGreaterThan(0);
      }

      await rail.getByTestId("drive-space-comma-drive").click({ button: "right" });
      const ownSyncRow = page.getByTestId("drive-space-sync-row-comma-drive");
      await expect(ownSyncRow).toBeVisible();
      await expect(ownSyncRow.getByRole("switch")).toBeEnabled();
      await expect(ownSyncRow.getByRole("switch")).toBeChecked();
      await ownSyncRow.getByRole("switch").click({ force: true });
      await expect(ownSyncRow.getByRole("switch")).not.toBeChecked();
      await expect(hello).toBeVisible();
      await expect(page.getByRole("menuitem", { name: "Delete" })).toHaveCount(0);
      await expect(page.getByRole("menuitem", { name: "Rename" })).toHaveCount(0);
      await page.keyboard.press("Escape");
      await expect(page.getByTestId("drive-sync-trigger")).toContainText("off");
      await page.getByTestId("drive-sync-trigger").click();
      await page.getByTestId("drive-sync-panel").getByRole("switch").press("Space");
      const picker = page.getByTestId("drive-sync-pick-dialog");
      await expect(picker).toBeVisible();
      await picker.getByRole("checkbox", { name: "notes", exact: true }).press("Space");
      await page.getByRole("button", { name: "Start syncing", exact: true }).click();
      await expect(picker).not.toBeVisible();
      await expect(page.getByTestId("comma-drive-sync-started")).toContainText(
        "1 folders have local sync enabled"
      );
      await expect(page.getByTestId("drive-sync-trigger")).toContainText("on");

      // Bytes come from the node when the preview asks.
      await hello.dblclick();
      await expect(previewText).toContainText("hello from the e2e node");
      await expect(page.getByTestId("drive-preview-panel")).toContainText("E2E Mac");

      // Copy puts the image on the operating-system clipboard through Main:
      // the renderer's own clipboard-write permission is denied in this
      // session, so a copy that only used the web API would do nothing.
      await app.evaluate(({ clipboard }) => clipboard.clear());
      await page.getByTestId("drive-file-synch:comma-drive:dot.png").dblclick();
      await page.getByTestId("drive-preview-copy").click();
      await expect(page.getByTestId("comma-drive-preview-copy")).toContainText(
        "Image copied"
      );
      expect(
        await app.evaluate(({ clipboard }) => clipboard.readImage().isEmpty())
      ).toBe(false);

      // Uploads use real disk-backed selections so Electron can resolve a
      // preload-vetted source path; synthetic in-memory Files have no path.
      const uploadedPath = join(testDirectory, "uploaded.txt");
      await writeFile(uploadedPath, "published through the node");
      await page.getByTestId("drive-add-files").click();
      await page.getByRole("menuitem", { name: "Upload files" }).click();
      await page.locator('input[type="file"]').first().setInputFiles(uploadedPath);
      const uploaded = page.getByTestId("drive-file-synch:comma-drive:uploaded.txt");
      await expect(uploaded).toBeVisible();
      await expect(page.getByTestId("drive-transfer-tab-upload")).toHaveText(
        "Upload 1/1"
      );
      expect(await nodeState(page)).toMatchObject({ status: "ready" });

      // The native Drive upload path must not inherit the 10 MB chat/fallback
      // payload limit; Main streams the selected file from disk into the node.
      const largeUploadPath = join(testDirectory, "large-upload.bin");
      await writeFile(
        largeUploadPath,
        Buffer.concat([
          Buffer.from("large-upload-start"),
          Buffer.alloc(DRIVE_E2E_LARGE_BYTES - "large-upload-start".length, 7),
        ])
      );
      await page.getByTestId("drive-add-files").click();
      await page.getByRole("menuitem", { name: "Upload files" }).click();
      await page.locator('input[type="file"]').first().setInputFiles(largeUploadPath);
      const largeUploaded = page.getByTestId(
        "drive-file-synch:comma-drive:large-upload.bin"
      );
      await expect(largeUploaded).toBeVisible();
      await expect
        .poll(
          async () =>
            (await nodeList(page, "comma-drive")).find(
              (entry) => entry.path === "large-upload.bin"
            )?.size
        )
        .toBe(DRIVE_E2E_LARGE_BYTES);

      // The own copy is newest and therefore already cached by the preview.
      // Keeping the older remote copy must discard that cache and fetch the
      // newly selected bytes rather than leaving the own preview in place.
      await page.getByTestId("drive-file-synch:comma-drive:shared.txt").dblclick();
      await expect(previewText).toContainText("own copy");
      const versions = page.getByTestId("drive-versions-panel");
      await expect(versions).toContainText("This file has 2 versions");
      const remoteRow = versions
        .locator('[data-testid^="drive-version-"]')
        .filter({ hasText: "e2eremote0" });
      await expect(remoteRow).toContainText("e2eremote0");
      await remoteRow.click();
      await remoteRow.getByTestId("drive-versions-keep").click();
      await expect(
        page.getByTestId("comma-drive-version-synch:comma-drive:shared.txt")
      ).toContainText("Kept the version from");
      await expect(versions).toBeHidden();
      await expect(previewText).toContainText("remote copy");

      // Keep Offline is a pin on the node.
      await hello.click({ button: "right" });
      await page.getByRole("menuitem", { name: "Keep Offline" }).click();
      await expect(
        page.getByTestId("comma-drive-keep-offline-synch:comma-drive:hello.txt")
      ).toContainText("Kept offline");
      await expect
        .poll(async () => (await nodeState(page)).pins)
        .toEqual(["comma-drive/hello.txt"]);

      // A space another device publishes is mirrored here as a replica with a checkout.
      await rail.getByTestId("drive-space-notes").click({ button: "right" });
      const notesSync = page
        .getByTestId("drive-space-sync-row-notes")
        .getByRole("switch");
      await expect(notesSync).not.toBeChecked();
      // The switch's input is the size of its mark; the click lands on it anyway.
      await notesSync.click({ force: true });
      await expect(page.getByTestId("comma-drive-space-sync-notes")).toContainText(
        "Syncing “notes”"
      );
      await expect
        .poll(
          async () =>
            (await nodeState(page)).spaces.find((space) => space.id === "notes")
              ?.checkoutPath
        )
        .toMatch(/Comma Spaces\/notes$/);
      await page.keyboard.press("Escape");

      // Delete goes through the node before the row leaves.
      await uploaded.click({ button: "right" });
      await page.getByRole("menuitem", { name: "Delete" }).click();
      await page.getByRole("button", { name: "Delete" }).click();
      await expect(uploaded).toHaveCount(0);
      expect(
        (await nodeList(page, "comma-drive")).some(
          (entry) => entry.path === "uploaded.txt"
        )
      ).toBe(false);
    } finally {
      await app.close();
    }
  });
});

async function openDrive(app: Awaited<ReturnType<typeof electron.launch>>) {
  const mainWindow = await findElectronWindowByNativeRole(app, "main-window");
  await mainWindow.waitForLoadState("domcontentloaded");
  await mainWindow.evaluate(() => {
    window.location.hash = "#/drive";
  });
  await expect(mainWindow.getByTestId("drive-route")).toBeVisible();
  return mainWindow;
}

type NodeBridge = {
  synchronicity: {
    list(input: {
      limit: number;
      space: string;
    }): Promise<{ entries: { path: string; size?: number }[] }>;
    state(): Promise<{
      pins: string[];
      spaces: { checkoutPath: string; id: string }[];
      status: string;
    }>;
  };
};

/** The node as the renderer sees it, through the same preload bridge the route uses. */
function nodeState(page: Page) {
  return page.evaluate(() =>
    (window as unknown as { commaNative: NodeBridge }).commaNative.synchronicity.state()
  );
}

function nodeList(page: Page, space: string) {
  return page.evaluate(
    async (spaceId) =>
      (
        await (
          window as unknown as { commaNative: NodeBridge }
        ).commaNative.synchronicity.list({
          limit: 100,
          space: spaceId,
        })
      ).entries,
    space
  );
}
