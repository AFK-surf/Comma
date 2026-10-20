import { expect, test } from "./electron-test";
import { clickElectronMenuItem, focusElectronWindow } from "./electron-operations";
import type { UpdateInfo } from "velopack";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

type UpdateTestState = typeof globalThis & {
  finishManualUpdate?: () => void;
  finishManualDownload?: () => void;
  appliedUpdates?: UpdateInfo[];
  /** Main's scripted update feed (`COMMA_ELECTRON_E2E_UPDATE_FEED=scripted`). */
  commaE2eUpdateFeed?: {
    script(feed: {
      status(): unknown;
      check(): Promise<UpdateInfo | null>;
      download(update: UpdateInfo): Promise<boolean>;
      apply(update: UpdateInfo): Promise<boolean>;
    }): void;
  };
};

const release: UpdateInfo = {
  TargetFullRelease: {
    PackageId: "comma",
    Version: "0.0.2",
    Type: "Full",
    FileName: "comma.nupkg",
    SHA1: "test",
    SHA256: "test",
    Size: 1,
    NotesMarkdown: "",
    NotesHtml: "",
  },
  DeltasToTarget: [],
  IsDowngrade: false,
};

// Exercise the real native menu -> preload IPC -> renderer -> toast path.
// Only the update service is replaced: no network feed or real installation.
// AutomaticUpdates.test.tsx covers the "current" and "failed" outcomes; one
// download and restart keep the native menu, utility core and renderer connected.
// app-updates.test.ts owns scheduling; AutomaticUpdates.test.tsx owns automatic offers.
test.describe(() => {
  test.use({ sharedElectronEnv: { COMMA_ELECTRON_E2E_UPDATE_FEED: "scripted" } });
  test(
    "manual update check downloads and applies the offered release through Main",
    { tag: "@shared-app" },
    async ({ sharedElectron }) => {
      const apiStub = await startChatSmokeStub();
      const { app, mainWindow: page } = sharedElectron;
      try {
        sharedElectron.useApi(apiStub.server);
        await sharedElectron.signIn({
          email: "update-feedback@comma.local",
          userId: apiStub.userId,
        });
        await expect(
          page.getByRole("complementary", { name: "App sidebar" })
        ).toBeVisible();
        // A desktop that keeps another app in front never gives the focus: the failed test's report names that app.
        await focusElectronWindow(app, page);
        const enabled = () =>
          app.evaluate(
            ({ Menu }) =>
              Menu.getApplicationMenu()?.getMenuItemById("check-updates")?.enabled
          );
        await expect.poll(enabled).toBe(true);
        // The check the core makes (at start, or for the menu: the menu's joins one under way) waits for the test.
        await app.evaluate((_, update) => {
          const state = globalThis as UpdateTestState;
          state.appliedUpdates = [];
          state.commaE2eUpdateFeed!.script({
            status: () => ({ configured: true, productName: "Comma" }),
            check: () =>
              new Promise<UpdateInfo | null>((resolveCheck) => {
                state.finishManualUpdate = () => resolveCheck(update);
              }),
            download: () =>
              new Promise<boolean>((resolveDownload) => {
                state.finishManualDownload = () => resolveDownload(true);
              }),
            apply: async (downloaded) => {
              state.appliedUpdates!.push(downloaded);
              return true;
            },
          });
        }, release);
        const clickCheck = () => clickElectronMenuItem(app, { id: "check-updates" });
        await clickCheck();
        await expect(
          page.getByText("Checking for updates…", { exact: true })
        ).toBeVisible();
        await expect.poll(enabled).toBe(false);
        await expect
          .poll(() =>
            app.evaluate(() =>
              Boolean((globalThis as UpdateTestState).finishManualUpdate)
            )
          )
          .toBe(true);
        await app.evaluate(() => (globalThis as UpdateTestState).finishManualUpdate!());
        await expect(
          page.getByText("Downloading update…", { exact: true })
        ).toBeVisible();
        await expect(
          page.getByText("Checking for updates…", { exact: true })
        ).toHaveCount(0);
        await expect.poll(enabled).toBe(false);
        await expect
          .poll(() =>
            app.evaluate(() =>
              Boolean((globalThis as UpdateTestState).finishManualDownload)
            )
          )
          .toBe(true);
        await app.evaluate(() =>
          (globalThis as UpdateTestState).finishManualDownload!()
        );
        await expect(page.getByText("Update ready", { exact: true })).toBeVisible();
        await expect(page.getByRole("button", { name: "Restart now" })).toBeVisible();
        await expect(
          page.getByText("Downloading update…", { exact: true })
        ).toHaveCount(0);
        await expect(
          page.getByText("Checking for updates…", { exact: true })
        ).toHaveCount(0);
        await expect.poll(enabled).toBe(true);
        expect(
          await app.evaluate(() => (globalThis as UpdateTestState).appliedUpdates)
        ).toEqual([]);
        await page.getByRole("button", { name: "Restart now" }).click();
        await expect
          .poll(() =>
            app.evaluate(() => (globalThis as UpdateTestState).appliedUpdates)
          )
          .toEqual([release]);
      } finally {
        await app.evaluate(() => {
          const state = globalThis as UpdateTestState;
          delete state.appliedUpdates;
          delete state.finishManualUpdate;
          delete state.finishManualDownload;
        });
        await apiStub.close();
      }
    }
  );
});
