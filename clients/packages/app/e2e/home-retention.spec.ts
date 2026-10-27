import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const transcript = Array.from({ length: 12 }, (_, turn) => [
  {
    actor_type: "user",
    content: [{ type: "text" as const, text: `Where does step ${turn} stand?` }],
    created_at: 1_720_000_000 + turn * 10,
    kind: "message",
    message_id: `retention-user-${turn}`,
  },
  {
    actor_type: "agent",
    content: [
      {
        type: "text" as const,
        text: `### Step ${turn}\n\nThe rollout is on track.\n\n- Confirm the migration\n- Update the runbook\n- Share the summary\n- Watch the error budget`,
      },
    ],
    created_at: 1_720_000_000 + turn * 10 + 5,
    kind: "message",
    message_id: `retention-assistant-${turn}`,
  },
]).flat();

// Home stays mounted while another page shows. It keeps what it showed — its
// scroll and its Tasks rail's cards — and takes no focus or pointer meanwhile.
test("a page over Home keeps Home as it was and out of reach", async ({ page }) => {
  const stub = await startChatSmokeStub({
    extraInlineTasks: [
      { id: "cnv_retention_task", status: "in_progress", title: "Retention task" },
    ],
    includeTaskInInbox: true,
    taskStatus: "in_progress",
    workspaceTranscript: transcript,
  });
  try {
    await page.setViewportSize({ width: 1600, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-retention@comma.local",
      token: "comma_sess_home_retention",
    });
    await page.goto("/");
    const home = page.locator(".comma-home-chat");
    await expect(
      home.locator('[data-message-id="retention-assistant-11"]')
    ).toBeVisible();
    // The reader scrolls back, which ends the thread's follow of its tail.
    const viewport = home.locator(".comma-chat-scroll-viewport");
    await viewport.evaluate((element) => {
      (window as unknown as { scrolled: Promise<number> }).scrolled = new Promise(
        (resolve) =>
          element.addEventListener("scrollend", () => resolve(element.scrollTop), {
            once: true,
          })
      );
    });
    await viewport.hover();
    await page.mouse.wheel(0, -400);
    const scrollTop = await page.evaluate(
      () => (window as unknown as { scrolled: Promise<number> }).scrolled
    );
    expect(scrollTop).toBeGreaterThan(0);
    const card = page
      .getByTestId("home-tasks-rail")
      .locator(".comma-home-tasks-item")
      .first();
    await expect(card).toBeVisible();
    const cardElement = await card.elementHandle();

    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    await expect(
      page.getByRole("region", { name: "Tasks", exact: true })
    ).toBeVisible();
    // Neither focus nor a press reaches the Home behind the page. A press
    // tests every box under the point, the covered ones too.
    expect(
      await home.evaluate((element) => {
        const button = element.querySelector("button")!;
        button.focus();
        const box = button.getBoundingClientRect();
        const under = document.elementsFromPoint(
          box.left + box.width / 2,
          box.top + box.height / 2
        );
        return {
          focused: document.activeElement === button,
          placed: box.width > 0,
          pressed: under.some((hit) => element.contains(hit)),
        };
      })
    ).toEqual({ focused: false, placed: true, pressed: false });

    await page.getByRole("link", { name: "Home", exact: true }).click();
    await expect(home).toBeVisible();
    expect(await viewport.evaluate((element) => element.scrollTop)).toBe(scrollTop);
    // The rail shows the very cards it showed: it neither dropped nor rebuilt them.
    expect(await cardElement!.evaluate((element) => element.isConnected)).toBe(true);
    expect(await card.evaluate((element, kept) => element === kept, cardElement)).toBe(
      true
    );
  } finally {
    await stub.close();
  }
});
