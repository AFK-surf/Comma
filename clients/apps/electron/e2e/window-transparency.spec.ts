import type { Locator } from "@playwright/test";
import { browserRenderWork } from "../../../e2e/helpers/render-work";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import { expect, test } from "./electron-test";

/**
 * The window ground over the macOS material (styles.css): the shell tints the
 * material with the window color, as much as Appearance's Transparency
 * leaves, and opaque while Comma's theme differs from the system's. A drag of
 * the Transparency slider previews on the shell before the setting commits;
 * it must restyle the shell, not the transcript under Settings.
 */

const turns = 6;

const transcript = Array.from({ length: turns }, (_, turn) =>
  (["user", "agent"] as const).map((actor) => ({
    actor_type: actor,
    content: [
      {
        type: "text" as const,
        text:
          actor === "user"
            ? `Where does step ${turn} stand?`
            : `### Step ${turn}\n\nThe rollout is on track.\n\n- Confirm the migration\n- Update the runbook`,
      },
    ],
    created_at: 1_720_000_000 + turn * 10 + (actor === "agent" ? 5 : 0),
    kind: "message",
    message_id: `ground-${actor}-${turn}`,
  }))
).flat();

/** How opaque the shell paints the window color: its background's alpha, 0 to 1. */
const groundAlpha = (shell: Locator) =>
  shell.evaluate((element) => {
    const canvas = document.createElement("canvas");
    canvas.width = 1;
    canvas.height = 1;
    const context = canvas.getContext("2d")!;
    // A color the canvas cannot read leaves this one, which no case expects.
    context.fillStyle = "transparent";
    context.fillStyle = getComputedStyle(element).backgroundColor;
    context.fillRect(0, 0, 1, 1);
    return context.getImageData(0, 0, 1, 1).data[3]! / 255;
  });

/** The alpha of the window color at a Transparency of `transparency` percent. */
const alphaAt = (transparency: number) => (100 - transparency) / 100;

test.skip(
  process.platform !== "darwin",
  "Main draws the main window over a system material on macOS (window-options.ts)."
);

test(
  "the window ground follows Transparency, and a slider drag restyles the shell alone",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const stub = await startChatSmokeStub({ workspaceTranscript: transcript });
    try {
      const { mainWindow: page } = sharedElectron;
      sharedElectron.useApi(stub.server);
      await sharedElectron.signIn({ email: "smoke@comma.local", userId: stub.userId });
      await expect(
        page.locator(`[data-message-id="ground-agent-${turns - 1}"]`)
      ).toBeVisible();
      const shell = page.locator(".comma-app-shell");
      const html = page.locator("html");
      const updateAppearance = (appearance: Record<string, unknown>) =>
        page.evaluate(
          (patch) =>
            window.commaNative!.appPreferences.update({
              clientSettings: { appearance: patch },
            }),
          appearance
        );
      await page.getByRole("button", { name: "Account", exact: true }).click();
      await page.getByRole("menuitem", { name: "Settings", exact: true }).click();
      await page.getByRole("button", { name: "Appearance", exact: true }).click();
      // The slider shows a saved value in the render after the provider wrote it
      // on the shell, so waiting on aria-valuenow makes the shell's tint readable.
      const slider = page.getByRole("slider", { name: "Transparency" });

      await test.step("the shell tints the material by the saved Transparency", async () => {
        await expect(slider).toHaveAttribute("aria-valuenow", "50");
        expect(await groundAlpha(shell)).toBeCloseTo(alphaAt(50), 2);
        await updateAppearance({ windowTransparency: 20 });
        await expect(slider).toHaveAttribute("aria-valuenow", "20");
        expect(await groundAlpha(shell)).toBeCloseTo(alphaAt(20), 2);
      });

      await test.step("the shell is opaque while the theme differs from the system's", async () => {
        // The renderer prefers the launch's light scheme.
        await updateAppearance({ theme: "dark" });
        await expect(html).toHaveAttribute("data-theme", "Dark mode");
        expect(await groundAlpha(shell)).toBe(1);
        await updateAppearance({ theme: "default" });
        await expect(html).toHaveAttribute("data-theme", "Light mode");
        expect(await groundAlpha(shell)).toBeCloseTo(alphaAt(20), 2);
      });

      await test.step("a drag previews on the shell and restyles nothing else", async () => {
        const box = (await slider.boundingBox())!;
        const y = box.y + box.height / 2;
        const at = (transparency: number) => box.x + (box.width * transparency) / 100;
        const documentElements = await page.locator("*").count();

        // The field paints a pointer's value and previews it in one step.
        await page.mouse.move(at(30), y);
        await page.mouse.down();
        await expect(slider).toContainText("30%");
        expect(await groundAlpha(shell)).toBeCloseTo(alphaAt(30), 2);
        const { restyled } = await browserRenderWork(page, async () => {
          for (const transparency of [25, 20, 15]) {
            await page.mouse.move(at(transparency), y);
            await expect(slider).toContainText(`${transparency}%`);
            // Reading the shell's color restyles what the preview changed.
            expect(await groundAlpha(shell)).toBeCloseTo(alphaAt(transparency), 2);
          }
        });
        await page.mouse.up();
        await expect(slider).toHaveAttribute("aria-valuenow", "15");
        expect(await groundAlpha(shell)).toBeCloseTo(alphaAt(15), 2);

        expect(restyled.length).toBeGreaterThan(0);
        expect(
          Math.max(...restyled),
          `elements restyled by a drag step, of ${documentElements} in the document`
        ).toBeLessThanOrEqual(8);
      });
    } finally {
      await stub.close();
    }
  }
);
