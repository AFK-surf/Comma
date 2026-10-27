import { expect, test, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

type TraceEvent = {
  args?: {
    data?: { reason?: string };
    elementCount?: number;
  };
  name: string;
  ts: number;
};

/** The newest sent message's bubble, landed: shown, and its flight over. */
async function landed(page: Page) {
  const bubble = page
    .locator('[data-slot="chat-user-output"]')
    .last()
    .locator(".comma-chat-user-bubble");
  await expect(bubble).toBeVisible();
  await expect(bubble).not.toHaveAttribute("data-outgoing-presentation", /./);
}

/** Records the renderer's style and layout work while `act` runs. */
async function traceStyleWork(page: Page, act: () => Promise<void>) {
  const cdp = await page.context().newCDPSession(page);
  const events: TraceEvent[] = [];
  cdp.on("Tracing.dataCollected", (payload) => {
    events.push(...(payload.value as unknown as TraceEvent[]));
  });
  const complete = new Promise<void>((resolve) =>
    cdp.once("Tracing.tracingComplete", () => resolve())
  );
  await cdp.send("Tracing.start", {
    categories: [
      "-*",
      "devtools.timeline",
      "disabled-by-default-devtools.timeline",
      "disabled-by-default-devtools.timeline.invalidationTracking",
    ].join(","),
    transferMode: "ReportEvents",
  });
  await act();
  await cdp.send("Tracing.end");
  await complete;
  await cdp.detach();
  return events;
}

test("a send adds no keyframes and restyles no more than its own turn", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({});
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "send-style@comma.local",
      token: "comma_sess_send_style",
    });
    await page.goto("/");
    const composer = page
      .getByTestId("comma-route-outlet")
      .locator(".comma-chat-composer");
    const prompt = composer.getByRole("textbox", { name: "AI prompt" });
    const send = composer.getByRole("button", { name: /^Send/ });
    await expect(prompt).toBeVisible();
    // The first send pays the thread's one-time costs (its first bubble tail,
    // its first thinking mark); the second is what every later send costs.
    await prompt.fill("first message");
    await send.click();
    await stub.waitForMessageBodies(1);
    await landed(page);

    await prompt.fill("second message");
    const events = await traceStyleWork(page, async () => {
      await send.click();
      await stub.waitForMessageBodies(2);
      await landed(page);
    });

    // The thinking mark plays the stylesheet's keyframes: a mark that brought
    // its own restyled every animated element in the document, twice per send.
    const keyframeRestyles = events.filter(
      (event) =>
        event.name === "StyleRecalcInvalidationTracking" &&
        event.args?.data?.reason === "@keyframes rule change"
    );
    expect(keyframeRestyles).toEqual([]);

    // No style recalc of the send restyles the document at large.
    const largestRecalc = Math.max(
      0,
      ...events
        .filter((event) => event.name === "UpdateLayoutTree")
        .map((event) => event.args?.elementCount ?? 0)
    );
    expect(largestRecalc).toBeLessThan(150);
  } finally {
    await stub.close();
  }
});
