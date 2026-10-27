import { expect, test } from "@playwright/test";
import type { IncomingMessage, ServerResponse } from "node:http";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

// A Task's app card draws outside the Markdown renderer, whose element resets
// stripped its type, and gives the app its preview size: the frame took the
// browser's default 300×150 before. The card is a launch cover a phone's
// width at most, and the app in it always shows its phone layout.

const app = {
  id: "app_habits",
  slug: "x7k2q9",
  workspace_id: chatSmokeWorkspace.id,
  name: "Team habits",
  description: "",
  icon_url: null,
  repo: null,
  visibility: "workspace",
  status: "active",
  live_version: 3,
  latest_version: 3,
  author: { name: "Ada" },
  capabilities: [],
  egress: [],
  secrets: [],
  grants: [],
  installed: false,
  install: null,
  storage: [],
  has_backend: false,
};

/** An uncompressed ustar archive of one `index.html`: the bundle format. */
function bundle(): Buffer {
  const data = Buffer.from("<!doctype html><html><body><p>Habits</p></body></html>");
  const header = Buffer.alloc(512);
  header.write("index.html", 0);
  header.write("0000644\0", 100);
  header.write(`${data.length.toString(8).padStart(11, "0")}\0`, 124);
  header.write("        ", 148);
  header.write("0", 156);
  header.write("ustar\0", 257);
  header.write("00", 263);
  const sum = header.reduce((total, byte) => total + byte, 0);
  header.write(`${sum.toString(8).padStart(6, "0")}\0 `, 148);
  return Buffer.concat([
    header,
    data,
    Buffer.alloc((512 - (data.length % 512)) % 512),
    Buffer.alloc(1024),
  ]);
}

async function appRoutes(_: IncomingMessage, url: URL, res: ServerResponse) {
  if (url.pathname === `/v1/comma/apps/${app.id}/open`) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        app,
        version: 3,
        digest: "digest-3",
        viewer: { id: "usr", name: "Ada" },
      })
    );
    return true;
  }
  if (url.pathname.endsWith(`/apps/${app.id}/versions/3/bundle`)) {
    res.writeHead(200, { "content-type": "application/x-tar" });
    res.end(bundle());
    return true;
  }
  return false;
}

test("a Task's app card shows the app at its preview size and opens it beside the chat", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    extraRoutes: appRoutes,
    taskStatus: "ready_for_review",
    taskReviewVersion: 3,
    taskTranscript: [
      {
        actor_type: "agent",
        agent_id: "worker_app",
        message_id: "msg_app",
        kind: "message",
        text: "Team habits — preview version 3",
        content: [
          {
            type: "mini_app",
            version: 1,
            app_id: app.id,
            app_version: 3,
            name: app.name,
            summary: "Team habits — preview version 3",
          },
        ],
      },
    ],
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "apps@comma.local",
      token: "comma_sess_apps",
    });
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const card = page.getByTestId("mini-app-message-card");
    const frame = card.getByTestId("mini-app-frame");
    await expect(frame).toBeVisible();
    await expect(
      card.locator("xpath=ancestor::*[contains(@class, 'markstream-react')]")
    ).toHaveCount(0);

    // The card is a launch cover a phone's width at most; the app in it lays
    // out at an iPhone's width (its phone layout), shown smaller. Both sizes
    // are laid out with the visible frame: nothing arrives later.
    const cardBox = await card.boundingBox();
    expect(cardBox!.width).toBeLessThanOrEqual(384);
    const body = await card.getByTestId("mini-app-body").boundingBox();
    expect(body!.height).toBe(240);
    expect(await frame.evaluate((element) => element.clientWidth)).toBe(390);

    // The actions menu stays its own: a press on it opens the menu, not the app.
    await card.getByRole("button", { name: "App actions" }).click();
    await expect(page.getByRole("menuitem", { name: "App settings" })).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByTestId("mini-app-frame")).toHaveCount(1);

    // The card's open comes before its menu in Tab order, and its focus ring is the card's own.
    await page.keyboard.press("Shift+Tab");
    await expect(card.getByTestId("mini-app-card-open")).toBeFocused();
    await expect(card.getByTestId("mini-app-chrome")).toHaveCSS(
      "box-shadow",
      /rgba\(152, 162, 179, 0\.14\) 0px 0px 0px 4px/
    );

    // A click anywhere on the card, here on its name under the preview, opens the app in the right panel beside the
    // chat.
    const name = await card.getByText(app.name, { exact: true }).boundingBox();
    await page.mouse.click(name!.x + name!.width / 2, name!.y + name!.height / 2);
    await expect(page.getByTestId("mini-app-frame")).toHaveCount(2);
  } finally {
    await stub.close();
  }
});

// A page switch and back shows the card's app as it was left, at once: the same frame and document, with no session
// opened and no app started again (each of those waits on the server).
test("a Task's app card keeps its running app across a page switch", async ({
  page,
}) => {
  let opens = 0;
  const stub = await startChatSmokeStub({
    extraRoutes: (req, url, res) => {
      if (url.pathname === `/v1/comma/apps/${app.id}/open`) opens += 1;
      return appRoutes(req, url, res);
    },
    taskTranscript: [
      {
        actor_type: "agent",
        agent_id: "worker_app",
        message_id: "msg_app",
        kind: "message",
        text: "Team habits — preview version 3",
        content: [
          {
            type: "mini_app",
            version: 1,
            app_id: app.id,
            app_version: 3,
            name: app.name,
            summary: "Team habits — preview version 3",
          },
        ],
      },
    ],
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "apps@comma.local",
      token: "comma_sess_apps",
    });
    const taskRoute = `#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`;
    await page.goto(`/${taskRoute}`);
    const card = page.getByTestId("mini-app-message-card");
    const frame = card.getByTestId("mini-app-frame");
    await expect(
      card.frameLocator('[data-testid="mini-app-frame"]').getByText("Habits")
    ).toBeVisible();
    // Marks on the frame element and on the app's document, which a new frame or a reload would not carry.
    await frame.evaluate((element) => {
      (element as HTMLIFrameElement & { kept?: true }).kept = true;
    });
    const appDocument = async () => (await frame.elementHandle())!.contentFrame();
    await (await appDocument())!.evaluate(() => {
      (window as Window & { kept?: true }).kept = true;
    });

    await page.evaluate(() => {
      location.hash = "#/";
    });
    await expect(card).toHaveCount(0);
    await page.evaluate((route) => {
      location.hash = route;
    }, taskRoute);

    await expect(frame).toBeVisible();
    expect(
      await frame.evaluate((element) => ({
        kept: (element as HTMLIFrameElement & { kept?: true }).kept === true,
        width: element.clientWidth,
      }))
    ).toEqual({ kept: true, width: 390 });
    expect(
      await (await appDocument())!.evaluate(
        () => (window as Window & { kept?: true }).kept === true
      )
    ).toBe(true);
    expect(opens).toBe(1);
  } finally {
    await stub.close();
  }
});

// A Task opened in Home's right panel shows its app card there. The card opens
// the app as a tab of that same panel: the Task's own panel is not on screen,
// and an app opened there showed nowhere.
test("a Task's app card in Home's right panel opens the app in that panel", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    extraRoutes: appRoutes,
    inlineTaskReference: true,
    taskTranscript: [
      {
        actor_type: "agent",
        agent_id: "worker_app",
        message_id: "msg_app",
        kind: "message",
        text: "Team habits — preview version 3",
        content: [
          {
            type: "mini_app",
            version: 1,
            app_id: app.id,
            app_version: 3,
            name: app.name,
            summary: "Team habits — preview version 3",
          },
        ],
      },
    ],
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "apps@comma.local",
      token: "comma_sess_apps",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer
      .getByRole("textbox", { name: "AI prompt" })
      .fill("Build a habit app");
    await composer.getByRole("button", { name: "Send" }).click();
    await content
      .locator('[data-message-id="msg-assistant-smoke"]')
      .getByTestId(`chat-inline-task-${chatSmokeTaskConversation.id}`)
      .click();

    const panel = content.getByTestId("chat-sidebar");
    const card = panel.getByTestId("mini-app-message-card");
    await expect(card.getByTestId("mini-app-frame")).toBeVisible();
    await card.getByTestId("mini-app-card-open").click();
    // The panel now shows the app itself, in its own tab.
    await expect(
      panel.locator('[data-testid="mini-app-chrome"][data-variant="flush"]')
    ).toBeVisible();
  } finally {
    await stub.close();
  }
});

// A deleted app keeps its place in the conversation as a gray block that says why, not an empty app frame.
test("a Task's card for a deleted app shows that the app is unavailable", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    extraRoutes: async (_, url, res) => {
      if (url.pathname !== `/v1/comma/apps/${app.id}/open`) return false;
      res.writeHead(404, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { code: "not_found", message: "Not found" } }));
      return true;
    },
    taskTranscript: [
      {
        actor_type: "agent",
        agent_id: "worker_app",
        message_id: "msg_app",
        kind: "message",
        text: "Team habits — preview version 3",
        content: [
          {
            type: "mini_app",
            version: 1,
            app_id: app.id,
            app_version: 3,
            name: app.name,
            summary: "Team habits — preview version 3",
          },
        ],
      },
    ],
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "apps@comma.local",
      token: "comma_sess_apps",
    });
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const gone = page.getByTestId("mini-app-card-gone");
    await expect(gone).toContainText("App unavailable");
    await expect(gone).toContainText("Team habits was deleted");
    await expect(page.getByTestId("mini-app-frame")).toHaveCount(0);
  } finally {
    await stub.close();
  }
});
