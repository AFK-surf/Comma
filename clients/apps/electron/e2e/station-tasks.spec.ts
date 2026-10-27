import { readFileSync } from "node:fs";
import { readFile, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import { chatSmokeWorkspace } from "../../../e2e/p0/chat-stub-records";
import { chooseTaskStatus, openTaskDetails } from "../../../e2e/helpers/task-panel";
import { expect, test as base } from "./electron-test";
import { startE2eStation } from "./fixtures/station";

/**
 * Tasks a station hosts, through the production renderer and the Comma client core in its utility process: the
 * Tasks page lists the workspace's station Tasks from Comma's Task index (the chat stub), a new Task is made on the
 * machine over `comma/mesh/1` (a station on loopback iroh, `fixtures/station.ts`), and it opens on the page any Task
 * opens on, which reads and writes on the station itself. Which calls the core makes and what it keeps is tested in packages/core (station-tasks,
 * station-new-task); here: the window, the core's process and the mesh, together.
 */
const EMAIL = "stations-e2e@example.com";
/** A picture the Task's agent posts. */
const picture = resolve(
  __dirname,
  "../../../packages/ui/src/components/chat-panel/assets/generated-image-preview.png"
);
/** The session the stub's email sign-in gives (`startChatSmokeStub`). */
const TOKEN = `smoke-token:${EMAIL}`;

// The station listens before the shared app starts again: the core reaches it at the address the reset gives.
const test = base.extend<{ station: Awaited<ReturnType<typeof startE2eStation>> }>({
  // Playwright requires fixture dependencies to use object destructuring.
  // eslint-disable-next-line no-empty-pattern
  station: async ({}, use) => {
    const station = await startE2eStation({
      name: "Studio",
      workspace: chatSmokeWorkspace.id,
      group: chatSmokeWorkspace.group_id,
    });
    try {
      await use(station);
    } finally {
      await station.close();
    }
  },
  sharedElectronEnv: async ({ station }, use) => {
    await use({ COMMA_ELECTRON_E2E_STATION_PEERS: station.peers });
  },
});

test(
  "the Tasks page lists a station's Tasks, makes one on the machine, and opens it on the station",
  { tag: "@shared-app" },
  async ({ sharedElectron, station }, testInfo) => {
    const stub = await startChatSmokeStub({
      extraRoutes: station.routes,
      sessionEmail: EMAIL,
      taskLabels: [
        { id: "lbl_ship", name: "Ship", color: "blue" },
        { id: "lbl_ci", name: "CI", color: "green" },
      ],
    });
    try {
      const { mainWindow: page } = sharedElectron;
      sharedElectron.useApi(stub.server);
      await sharedElectron.signIn({ email: EMAIL, userId: stub.userId });
      await page.getByRole("link", { name: "Tasks" }).click();

      // The station's Task is listed with where it runs.
      const hosted = page.getByRole("button", { name: "Fix flaky checkout test" });
      await expect(hosted).toBeVisible();
      await expect(page.getByTestId("task-card-host").first()).toHaveText(
        "On Studio · claude-opus-5-5"
      );
      // Its labels, as its station keeps them, beside where it runs.
      await expect(page.getByTestId("task-card-label").first()).toHaveText("Ship");
      await page.screenshot({ path: testInfo.outputPath("tasks.png") });

      // A new Task on the machine: its profile's model, and the first message.
      await page.getByRole("button", { name: "New task" }).first().click();
      const dialog = page.getByTestId("new-station-task");
      await expect(dialog).toContainText("gpt-5.5");
      await dialog
        .getByRole("textbox", { name: "What should it do?" })
        .fill("Run the checkout tests twice.");
      await page.screenshot({ path: testInfo.outputPath("new-task.png") });
      await page.getByRole("button", { name: "Create task" }).click();
      await station.heard("made", 1);
      expect(station.made).toMatchObject([
        {
          runtime: "codex",
          profile: "work",
          model: "gpt-5.5",
          clientKey: expect.any(String),
        },
      ]);
      await station.heard("posted", 1);
      expect(station.posted).toMatchObject([
        {
          body: { text: "Run the checkout tests twice." },
          path: "/threads/8/messages",
        },
      ]);

      // It opens as any Task does, read on the station; its details say where it runs, and a person marks it done
      // there.
      await expect(page.getByTestId("chat-user-bubble-content")).toHaveText(
        "Run the checkout tests twice."
      );
      const details = await openTaskDetails(page);
      await expect(details.getByTestId("task-panel-run-place")).toContainText("Studio");
      // A step its agent records reaches the Task's Activity, under its brief; the chat shows no message for it.
      station.record(8, ["Ran the checkout tests twice"]);
      const activity = details.getByTestId("task-panel-activity");
      await expect(activity.getByTestId("task-activity-request")).toHaveText(/Created/);
      await expect(activity.getByTestId("task-activity-step")).toHaveText(
        /Ran the checkout tests twice/
      );
      await expect(page.getByText(/Ran the checkout tests twice/)).toHaveCount(1);
      // Its labels are set on its station.
      await details.getByTestId("task-panel-labels").getByText("Add label").click();
      await page
        .getByTestId("task-label-picker")
        .getByRole("menuitemcheckbox", { name: "CI" })
        .click();
      await station.heard("labels", 1);
      expect(station.labels(8)).toEqual(["lbl_ci"]);
      await page.keyboard.press("Escape");
      await expect(details.getByTestId("task-panel-labels")).toContainText("CI");
      await page.screenshot({ path: testInfo.outputPath("station-task.png") });
      await chooseTaskStatus(details, "Done");
      await station.heard("status", 1);
      expect(station.status(8)).toBe("done");

      // A picture its agent posts shows in the chat and saves, read from the machine, as any Task's from Comma.
      const bytes = readFileSync(picture);
      station.post(8, "The run, as it ended.", { name: "checkout.png", bytes });
      const shown = page.getByRole("img", { name: "checkout.png", exact: true });
      await expect(shown).toHaveAttribute("src", /^blob:/);
      // Decoded, it has its pixels.
      expect(
        await shown.evaluate(async (img) => {
          await (img as HTMLImageElement).decode();
          return (img as HTMLImageElement).naturalWidth;
        })
      ).toBeGreaterThan(0);
      await page.screenshot({ path: testInfo.outputPath("station-task-picture.png") });
      await shown.click({ button: "right" });
      await page
        .getByRole("menu")
        .getByRole("menuitem", { name: "Save image" })
        .click();
      const notification = page.getByTestId("file-download");
      await expect(
        notification.getByText("Download complete", { exact: true })
      ).toBeVisible();
      const saved = join(sharedElectron.downloadsDir, "checkout.png");
      expect(await readFile(saved)).toEqual(bytes);
      // The shared app goes on as it was: no file or notice left.
      await rm(saved);
      await notification.getByRole("button", { name: "Dismiss notification" }).click();
      await expect(notification).toBeHidden();

      // Its computer's details say how this device reaches it: straight, on loopback.
      await page.evaluate(() => {
        window.location.hash = "#/settings";
      });
      await page.getByRole("button", { name: "Devices", exact: true }).click();
      await page
        .getByRole("article", { name: "Studio" })
        .getByRole("button", { name: /More actions for/ })
        .click();
      await page.getByRole("menuitem", { name: "Details", exact: true }).click();
      await expect(page.getByRole("dialog", { name: "Studio" })).toContainText(
        "ConnectionDirect"
      );
      await page.screenshot({ path: testInfo.outputPath("devices.png") });

      // Neither the page nor the station had the session token.
      expect(await page.content()).not.toContain(TOKEN);
      expect(JSON.stringify(station.posted)).not.toContain(TOKEN);
    } finally {
      await stub.close();
    }
  }
);
