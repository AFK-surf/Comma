import { expect, test } from "./support/page";
import { stepUntil, testClock } from "./support/virtual-time";
import { useWebApp } from "./support/web-app";

// packages/app/e2e/agent-browser.spec.ts, on the web app world: the browsers
// API is the stub's (fixtures/web-app/routes/agent-browser.ts), and the half
// second in which no stream may start is the world's time.
const app = useWebApp(
  { taskStatus: "active" },
  { routes: "agent-browser", records: true }
);

// The stub's workspace and its task conversation (e2e/p0/chat-stub.ts).
const taskUrl = "/#/tasks/ws-smoke/grp-smoke/cnv_public_task_smoke";

// The core reads a session's browsers again every 10 s
// (packages/core/src/session-browsers.ts): a change of the stub's shows
// within this many frames of world time.
const nextRead = { frames: 1250 };

type BrowserState = {
  scopedReads: number;
  inputs: Record<string, unknown>[];
  streams: number;
  cleared: boolean;
};
const state = () => app.stub().call("browserState") as Promise<BrowserState>;
/** Moves world time a frame at a time until `holds` of the stub's state. */
const eventually = (holds: (state: BrowserState) => boolean) =>
  stepUntil(async () => holds(await state()));

test("remote browser paints frames and admits mouse and keyboard only after takeover", async ({
  page,
}) => {
  await app.stub().call("setTaskParticipants", [], {
    participant_id: await app.stub().call("browserParticipant"),
    actor_id: "agent-browser-e2e",
    name: "Browser worker",
  });
  const surface = document.createElement("canvas");
  surface.width = 16;
  surface.height = 9;
  const context = surface.getContext("2d")!;
  context.fillStyle = "red";
  context.fillRect(0, 0, 16, 9);
  await app
    .stub()
    .call("setBrowserFrame", surface.toDataURL("image/jpeg").split(",")[1]);

  await app.open(page, taskUrl);
  const browserButton = page
    .locator("header")
    .getByRole("button", { name: "Browser", exact: true });
  await eventually(({ scopedReads }) => scopedReads > 0);
  await expect(page.getByRole("button", { name: "Browser", exact: true })).toHaveCount(
    0
  );
  await app.stub().call("setBrowserActive", true);
  await stepUntil(() => browserButton.isVisible(), nextRead);
  await expect(browserButton).toHaveAttribute("aria-expanded", "false");
  await browserButton.click();
  await expect(browserButton).toHaveAttribute("aria-expanded", "true");
  const panel = page.getByRole("region", { name: "Agent browser" });
  await expect(
    panel.getByText("Logins and website storage are shared", { exact: false })
  ).toBeVisible();
  const canvas = panel.locator("canvas");
  await stepUntil(
    async () => (await canvas.evaluate((node: HTMLCanvasElement) => node.width)) === 16
  );
  await canvas.click({ position: { x: 30, y: 20 } });
  expect((await state()).inputs).toHaveLength(0);
  await panel.getByRole("button", { name: "Take control", exact: true }).click();
  await expect(panel.getByRole("button", { name: "Return to agent" })).toBeVisible();
  await canvas.click({ position: { x: 30, y: 20 } });
  await canvas.press("Tab");
  await panel
    .getByRole("textbox", { name: "Text to type in the browser" })
    .fill("中文輸入");
  await panel.getByRole("button", { name: "Send text" }).click();
  await eventually(({ inputs }) =>
    inputs.some((input) => input.type === "mousePressed")
  );
  await eventually(({ inputs }) =>
    inputs.some((input) => input.type === "keyDown" && input.key === "Tab")
  );
  await eventually(({ inputs }) =>
    inputs.some((input) => input.type === "text" && input.text === "中文輸入")
  );
  await panel.getByRole("button", { name: "Return to agent" }).click();
  await expect(panel.getByRole("textbox")).toBeDisabled();
  await expect(panel.getByRole("alert")).toHaveText(
    "Some browser changes were saved. Recent changes on other sites may be missing after recovery."
  );
  await browserButton.click();
  await expect(browserButton).toHaveAttribute("aria-expanded", "false");
  await expect(panel).not.toBeVisible();
  const stopped = (await state()).streams;
  await testClock().advance(500);
  expect((await state()).streams).toBe(stopped);
  await browserButton.click();
  await panel.getByRole("button", { name: "Close browser", exact: true }).click();
  await expect(browserButton).toHaveCount(0);
  await expect(panel).not.toBeVisible();
  await app.stub().call("setBrowserActive", true);
  await stepUntil(() => browserButton.isVisible(), nextRead);
  await browserButton.click();
  await panel.getByRole("button", { name: "Clear shared logins…" }).click();
  const confirmation = panel.getByRole("group", { name: "Clear shared browser data" });
  await expect(confirmation).toBeVisible();
  expect((await state()).cleared).toBe(false);
  await confirmation.getByRole("button", { name: "Cancel", exact: true }).click();
  expect((await state()).cleared).toBe(false);
  await panel.getByRole("button", { name: "Clear shared logins…" }).click();
  await confirmation.getByRole("button", { name: "Clear and close" }).click();
  await eventually(({ cleared }) => cleared);
  await expect(browserButton).toHaveCount(0);
});
