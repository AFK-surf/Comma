import type { Page } from "@playwright/test";
import { expect } from "../../../e2e/helpers/native-expect";
import { test } from "./electron-test";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const EMAIL = "window-regions@example.com";
const turns = 6;

// Long replies, so the transcript holds thousands of boxes.
const reply = (turn: number) =>
  `### Step ${turn}\n\n` +
  Array.from(
    { length: 60 },
    (_, item) => `- Item ${item} of step ${turn} is **on track** with \`code\`.`
  ).join("\n") +
  "\n\n```ts\nexport const ready = true;\n```";

const transcript = Array.from({ length: turns }, (_, turn) => [
  {
    actor_type: "user",
    content: [{ type: "text" as const, text: `Where does step ${turn} stand?` }],
    created_at: 1_720_000_000 + turn * 10,
    kind: "message",
    message_id: `region-user-${turn}`,
  },
  {
    actor_type: "agent",
    content: [{ type: "text" as const, text: reply(turn) }],
    created_at: 1_720_000_005 + turn * 10,
    kind: "message",
    message_id: `region-assistant-${turn}`,
  },
]).flat();

/**
 * Every box that carries a window app region and passes it on to a plain
 * child. Electron gives a box its parent's region and registers every box that
 * has one, at its unclipped rect, after each layout and each scroll; a region
 * must stay on the boxes that declare it. A Content Header that is a drag
 * surface names its descendants on purpose.
 */
const regionsPassedOn = (page: Page) =>
  page.evaluate(() => {
    const carrying = Array.from(document.body.querySelectorAll("*")).flatMap(
      (element) => {
        const region = getComputedStyle(element).getPropertyValue("-webkit-app-region");
        return region === "none" ? [] : [{ element, region }];
      }
    );
    const passing = carrying
      .filter(
        ({ element }) =>
          element instanceof HTMLElement &&
          !element.closest('.comma-content-header[data-window-drag-region="true"]')
      )
      .filter(({ element }) => {
        const child = document.createElement("div");
        element.append(child);
        const passed =
          getComputedStyle(child).getPropertyValue("-webkit-app-region") !== "none";
        child.remove();
        return passed;
      })
      .map(({ element, region }) => `${region} ${element.outerHTML.slice(0, 100)}`);
    return { carrying: carrying.length, passing };
  });

/**
 * Controls a press reaches whose point is not in a no-drag region: a press
 * there moves the window. A control is covered by its own no-drag, or by the
 * nearest box above it that declares a region when that is no-drag and holds
 * the control's point.
 */
const controlsOnDragRegions = (page: Page) =>
  page.evaluate(() => {
    const controls = document.querySelectorAll(
      'button, a[href], input, select, textarea, [role="button"], [role="link"], [role="menuitem"], [role="option"], [role="tab"], [role="switch"], [role="slider"]'
    );
    return Array.from(controls).flatMap((control) => {
      const rect = control.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) return [];
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      const hit = document.elementFromPoint(x, y);
      // Only a control a press reaches at its centre.
      if (!hit || !(hit === control || control.contains(hit))) return [];
      if (
        getComputedStyle(control).getPropertyValue("-webkit-app-region") === "no-drag"
      )
        return [];
      let box = control.parentElement;
      let boxRegion = "none";
      while (box) {
        boxRegion = getComputedStyle(box).getPropertyValue("-webkit-app-region");
        if (boxRegion !== "none") break;
        box = box.parentElement;
      }
      if (box && boxRegion === "no-drag") {
        const area = box.getBoundingClientRect();
        if (x >= area.left && x <= area.right && y >= area.top && y <= area.bottom) {
          return [];
        }
      }
      return [control.outerHTML.slice(0, 100)];
    });
  });

test(
  "electron keeps window app regions on the boxes that declare them",
  { tag: "@shared-app" },
  async ({ sharedElectron: { mainWindow: page, signIn, useApi } }, testInfo) => {
    const stub = await startChatSmokeStub({
      sessionEmail: EMAIL,
      workspaceTranscript: transcript,
      // The Plugins page raises its load failure as a toast.
      extraRoutes: (request, url, response) => {
        if (
          request.method !== "GET" ||
          url.pathname !== `/v1/comma/workspaces/${chatSmokeWorkspace.id}/plugins`
        )
          return false;
        response.writeHead(503, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: "unavailable" }));
        return true;
      },
    });
    try {
      useApi(stub.server);
      await signIn({ email: EMAIL, userId: stub.userId });

      // Home with the long transcript and the Chat Sidebar open.
      const column = page.locator(".comma-home-chat .comma-chat-column");
      await expect(
        column.locator('[data-message-id^="region-assistant-"]')
      ).toHaveCount(turns);
      await page.getByTestId("chat-sidebar-toggle").click();
      await expect(page.locator('[data-slot="right-sidebar"]')).toHaveAttribute(
        "data-open",
        "true"
      );
      const home = await regionsPassedOn(page);
      const homeControls = await controlsOnDragRegions(page);
      const contentRegions = await page.evaluate(() =>
        Array.from(
          document.querySelectorAll(
            ".comma-home-chat .comma-chat-column *, .comma-chat-sidebar-panels *"
          )
        )
          .filter(
            (element) =>
              getComputedStyle(element).getPropertyValue("-webkit-app-region") !==
              "none"
          )
          .map((element) => element.outerHTML.slice(0, 100))
      );

      // A toast card sits outside its stack's box, which is empty: the card
      // must declare its own no-drag, or a press on it over the drag shell
      // (the rail, the window bar) moves the window instead.
      await page.evaluate(() => (window.location.hash = "#/plugins"));
      const toastCard = page.locator("[data-sonner-toast]", {
        has: page.getByTestId("plugins-load-error"),
      });
      await expect(toastCard).toBeVisible();
      const toastCardRegion = await toastCard.evaluate((element) =>
        getComputedStyle(element).getPropertyValue("-webkit-app-region")
      );
      const plugins = await regionsPassedOn(page);
      const pluginsControls = await controlsOnDragRegions(page);

      await testInfo.attach("regions", {
        body: JSON.stringify({ home, plugins }, null, 2),
        contentType: "application/json",
      });
      expect(home.passing).toEqual([]);
      expect(contentRegions).toEqual([]);
      expect(toastCardRegion).toBe("no-drag");
      expect(plugins.passing).toEqual([]);
      // A press on any control in reach stays with the control.
      expect(homeControls).toEqual([]);
      expect(pluginsControls).toEqual([]);
    } finally {
      await stub.close();
    }
  }
);
