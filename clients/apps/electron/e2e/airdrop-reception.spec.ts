import { _electron as electron, expect, test } from "@playwright/test";
import { execFile, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { copyFile, mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { chatSmokeWorkspaceChat, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const helper = resolve(
  electronAppDir,
  "dist/native/darwin",
  process.arch,
  "opendropkit"
);
const photo = resolve(
  process.cwd(),
  "packages/ui/src/components/chat-panel/assets/generated-image-preview.png"
);
const run = promisify(execFile);

/** The command line of the receiver Main spawned for this profile, if any. */
async function receiverProcess(userDataDir: string) {
  const { stdout } = await run("/bin/ps", ["-axo", "pid=,command="]);
  return stdout
    .split("\n")
    .find((line) => line.includes(join(userDataDir, "airdrop", "received")))
    ?.trim();
}

/** The listening port of the receiver Main spawned for this profile, if any. */
async function receiverPort(userDataDir: string) {
  const pid = (await receiverProcess(userDataDir))?.split(/\s+/)[0];
  if (!pid) return undefined;
  const { stdout: listening } = await run("/usr/sbin/lsof", [
    "-Pan",
    "-p",
    pid,
    "-iTCP",
    "-sTCP:LISTEN",
  ]).catch(() => ({ stdout: "" }));
  return /:(\d+) \(LISTEN\)/.exec(listening)?.[1];
}

// The real OpenDropKit helper receives over local TLS, the way a nearby
// device's upload arrives; radio discovery is outside this test.
test.skip(
  process.platform !== "darwin" || !existsSync(helper),
  "AirDrop reception needs macOS and the fetched helper (build:native:airdrop)."
);

async function launchReceivingComma() {
  const api = await startChatSmokeStub();
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-airdrop-e2e-"));
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...hostEnv,
      COMMA_API_BASE_URL: api.baseUrl,
      COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "airdrop@comma.local",
      COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "airdrop-session-token",
      NODE_ENV: "test",
    },
  });
  const close = async () => {
    await app.close();
    await api.close();
    await rm(userDataDir, { force: true, recursive: true });
  };
  try {
    const main = await findElectronWindowByNativeRole(app, "main-window");
    const composer = main
      .getByRole("region", { name: "Content" })
      .locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).waitFor();
    let port: string | undefined;
    await expect
      .poll(async () => (port = await receiverPort(userDataDir)), { timeout: 20_000 })
      .toBeTruthy();
    /** Sends files the way a nearby device does: one offer, one upload. */
    const send = (files: readonly string[]) =>
      spawn(helper, [
        "send",
        "--name",
        "iPhone",
        "--host",
        "::1",
        "--port",
        port!,
        ...files.flatMap((file) => ["--file", file]),
        "--identity-directory",
        join(userDataDir, "sender-identity"),
      ]);
    return { close, composer, main, send, userDataDir };
  } catch (error) {
    await close();
    throw error;
  }
}

test("an offer asks in a toast, previews what arrived, and Settings renames and hides Comma", async () => {
  test.setTimeout(180_000);
  const { close, composer, main, send, userDataDir } = await launchReceivingComma();
  let sender: ReturnType<typeof spawn> | undefined;
  try {
    sender = send([photo]);

    const toast = main.locator('[data-testid^="comma-airdrop-"]');
    await expect(toast.getByText("AirDrop from iPhone")).toBeVisible({
      timeout: 20_000,
    });
    await expect(
      toast.getByText(`Adds to “${chatSmokeWorkspaceChat.title}”`)
    ).toBeVisible();
    await expect(toast.getByText("generated-image-preview.png")).toBeVisible();
    const cardOverflow = () =>
      main.evaluate(
        () =>
          document
            .querySelector('[data-testid^="comma-airdrop-"]')!
            .getBoundingClientRect().bottom - window.innerHeight
      );
    // The enter slide starts below the window edge; let it land first.
    await expect.poll(cardOverflow).toBeLessThanOrEqual(0);
    // Clicking leaves the pointer on the stack, which pins the toast to a
    // measured height; the taller result must still stay inside the window.
    const lowestCardEdge = main.evaluate(async () => {
      let lowest = -Infinity;
      const until = performance.now() + 2_500;
      while (performance.now() < until) {
        const card = document.querySelector('[data-testid^="comma-airdrop-"]');
        if (card) lowest = Math.max(lowest, card.getBoundingClientRect().bottom);
        await new Promise(requestAnimationFrame);
      }
      return lowest - window.innerHeight;
    });
    await toast.getByRole("button", { name: "Accept" }).click();

    // The card becomes the result, showing the received image itself.
    await expect(
      toast.getByText(`Added to “${chatSmokeWorkspaceChat.title}”`)
    ).toBeVisible({ timeout: 30_000 });
    expect(await lowestCardEdge).toBeLessThanOrEqual(0);
    // Main serves the preview bytes over the binary command; the image decodes.
    const preview = toast.getByRole("img", { name: "generated-image-preview.png" });
    await expect(preview).toHaveAttribute("src", /^blob:/);
    await expect
      .poll(() => preview.evaluate((image: HTMLImageElement) => image.naturalWidth))
      .toBeGreaterThan(0);
    await expect(composer.getByTestId("image-attachment")).toBeVisible();
    await expect.poll(() => sender?.exitCode, { timeout: 20_000 }).toBe(0);

    await main.evaluate(() => {
      window.location.hash = "#/settings?category=general";
    });
    // Until renamed, nearby devices see the account's name. This stub has no
    // profile, so its session email (smoke@comma.local) names it.
    await main
      .getByRole("button", { name: "Edit AirDrop name: smoke’s Comma" })
      .click();
    // ps escapes the curly apostrophe, so the prefix shows Main agrees.
    expect(await receiverProcess(userDataDir)).toContain("--name smoke");
    const name = main.getByRole("textbox", { name: "AirDrop name" });
    await name.fill("Studio Mac");
    await name.press("Enter");
    await expect(
      main.getByRole("button", { name: "Edit AirDrop name: Studio Mac" })
    ).toBeVisible();
    // Main restarts the receiver under the new name.
    await expect
      .poll(() => receiverProcess(userDataDir), { timeout: 20_000 })
      .toContain("--name Studio Mac --directory");
    expect(
      JSON.parse(await readFile(join(userDataDir, "app-preferences.json"), "utf8"))
    ).toMatchObject({ airDropName: "Studio Mac" });

    const visible = main.getByRole("switch", { name: "Show Comma in AirDrop" });
    await expect(visible).toBeChecked();
    await visible.press("Space");
    await expect(visible).not.toBeChecked();
    // With the receiver gone, nearby devices no longer see Comma.
    await expect
      .poll(() => receiverPort(userDataDir), { timeout: 20_000 })
      .toBeUndefined();
    expect(
      JSON.parse(await readFile(join(userDataDir, "app-preferences.json"), "utf8"))
    ).toMatchObject({ showInAirDrop: false });
  } finally {
    sender?.kill();
    await close();
  }
});

test("several files ride one sideways strip, each showing its own preview", async () => {
  test.setTimeout(180_000);
  const { close, composer, main, send, userDataDir } = await launchReceivingComma();
  let sender: ReturnType<typeof spawn> | undefined;
  try {
    // Distinct paths: a batch never repeats a file.
    const outgoing = join(userDataDir, "outgoing");
    await mkdir(outgoing);
    const photos = await Promise.all(
      Array.from({ length: 8 }, async (_, index) => {
        const path = join(outgoing, `photo-${index + 1}.png`);
        await copyFile(photo, path);
        return path;
      })
    );
    sender = send(photos);

    const toast = main.locator('[data-testid^="comma-airdrop-"]');
    await expect(toast.getByText("AirDrop from iPhone")).toBeVisible({
      timeout: 20_000,
    });
    const strip = toast.getByLabel("Files");
    await expect(strip.getByRole("listitem")).toHaveCount(8);
    await toast.getByRole("button", { name: "Accept" }).click();

    await expect(
      toast.getByText(`Added to “${chatSmokeWorkspaceChat.title}”`)
    ).toBeVisible({ timeout: 30_000 });
    // Every file decodes its own preview, not only the first few.
    const previews = strip.getByRole("img");
    await expect(previews).toHaveCount(8);
    await expect
      .poll(() =>
        previews.evaluateAll(
          (images) =>
            images.filter((image) => (image as HTMLImageElement).naturalWidth > 0)
              .length
        )
      )
      .toBe(8);
    // The strip scrolls sideways inside the card instead of growing it.
    const { overflow, scrolled } = await strip.evaluate((viewport) => {
      const hidden = viewport.scrollWidth - viewport.clientWidth;
      viewport.scrollLeft = hidden;
      return { overflow: hidden, scrolled: viewport.scrollLeft };
    });
    expect(overflow).toBeGreaterThan(0);
    expect(scrolled).toBeGreaterThan(0);
    await expect(composer.getByTestId("image-attachment")).toHaveCount(8);
    await expect.poll(() => sender?.exitCode, { timeout: 20_000 }).toBe(0);
  } finally {
    sender?.kill();
    await close();
  }
});
