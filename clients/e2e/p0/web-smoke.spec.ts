import { expect, test } from "@playwright/test";
import { Buffer } from "node:buffer";
import { installBrowserTestSession } from "../helpers/browser-auth";
import {
  chatSmokeWorkspaceChat,
  chatSmokeAssistantReply,
  chatSmokeSkill,
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "./chat-stub";

const testSession = {
  apiBaseUrl: "http://127.0.0.1:65535",
  email: "smoke@comma.local",
  token: "p0-smoke-session-token",
};

test.use({ locale: "en-US" });

test("web app boots the client runtime", async ({ page }) => {
  await page.goto("/");

  await expect(page.locator("#root")).toBeAttached();
  await expect.poll(() => page.evaluate(() => document.readyState)).toBe("complete");
  await expect(
    page.evaluate(() => {
      const root = document.getElementById("root");

      return {
        hasRoot: root !== null,
        hasRenderedChildren: (root?.childElementCount ?? 0) > 0,
        hash: window.location.hash,
      };
    })
  ).resolves.toEqual({
    hasRoot: true,
    hasRenderedChildren: true,
    hash: "",
  });
});

test("web app renders the authenticated Comma shell controls", async ({ page }) => {
  await installBrowserTestSession(page, testSession);

  await page.goto("/");

  await expect(page.getByRole("group", { name: "AI input" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Attach" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Send" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Voice input" })).toBeEnabled();

  await expect(page.getByRole("navigation", { name: "Primary" })).toBeVisible();
  await expect(page.getByTestId("comma-window-bar")).toBeVisible();
  await expect(
    page.getByRole("button", { exact: true, name: "Settings" })
  ).toBeVisible();

  // Search is the window bar's pill (and its chord): a palette over the
  // current route, never a location.
  const currentUrl = page.url();
  await page.getByTestId("comma-window-bar-search").click();

  await expect(page.getByRole("dialog", { name: "Search Comma" })).toBeVisible();
  await expect(page.getByRole("combobox", { name: "Search Comma" })).toBeFocused();
  expect(page.url()).toBe(currentUrl);
});

test("web app opens Chat and completes a conversation against a /v1 stub", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    additionalInboxConversations: [chatSmokeWorkspaceChat],
  });

  try {
    await installBrowserTestSession(page, {
      ...testSession,
      apiBaseUrl: stub.baseUrl,
    });

    await page.goto("/#/inbox");

    const content = page.getByRole("region", { name: "Content" });

    await expect(page.getByRole("complementary", { name: "Chat" })).toHaveCount(0);
    // The host list supplies the notification used to open this Chat.
    const workspaceChatRow = content
      .getByTestId("inbox-item")
      .and(
        content.locator(
          `a[href$="/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeWorkspaceChat.id}"]`
        )
      );
    await expect(workspaceChatRow).toBeVisible();
    // Opening the notification uses the canonical list, not Home Chat composition.
    expect(stub.conversationListRequestCount).toBeGreaterThanOrEqual(1);
    await workspaceChatRow.click();
    await expect(page).toHaveURL(
      new RegExp(
        `#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeWorkspaceChat.id}$`
      )
    );

    await content.locator('input[type="file"]').setInputFiles([
      {
        name: "smoke.txt",
        mimeType: "text/plain",
        buffer: Buffer.from("smoke attachment"),
      },
      {
        name: "fail-once.txt",
        mimeType: "text/plain",
        buffer: Buffer.from("retry attachment"),
      },
    ]);
    const failedUpload = page.getByTestId("chat-upload-error");
    await expect(failedUpload).toContainText("fail-once.txt upload failed");
    const retryUpload = failedUpload.getByRole("button", { name: "Retry upload" });
    await retryUpload.evaluate((button) => {
      (button as HTMLButtonElement).click();
    });
    await expect(page.getByTestId("chat-upload-error")).toHaveCount(0);
    await expect(content.getByText("smoke.txt")).toBeVisible();
    await expect(content.getByText("fail-once.txt")).toBeVisible();
    await expect(
      content.getByRole("button", { name: "Send message", exact: true })
    ).toBeEnabled();

    const textbox = content.getByRole("textbox", { name: "AI prompt" });
    // Filter without completing the plain-text skill reference before selection.
    await textbox.fill("请总结周会 /weekly");
    await expect(
      content.getByRole("option", { name: chatSmokeSkill.name, exact: false })
    ).toBeVisible();
    await page.keyboard.press("Enter");
    const skillToken = textbox.locator(
      `[data-ai-input-token][data-menu-id="skills"][data-item-id="${chatSmokeSkill.skill_id}"]`
    );
    await expect(skillToken).toHaveText(chatSmokeSkill.name);
    await expect(textbox).toContainText("请总结周会");
    await expect(textbox).toBeFocused();
    await textbox.press("Enter");
    await expect(textbox).toHaveAttribute("contenteditable", "true");
    await expect(textbox).toHaveText("");
    await expect(textbox).toHaveAttribute("data-empty", "true");

    await expect(content.getByText("请总结周会")).toBeVisible();
    await expect(content.getByText("[[comma-protocol]]")).toHaveCount(0);
    await expect(content.getByText("Attached files in your workspace:")).toHaveCount(0);
    await expect(
      content.getByTestId("chat-attachment-pill-msg-user-smoke-0")
    ).toHaveText(/smoke\.txt/);
    await expect(
      content.getByTestId("chat-attachment-pill-msg-user-smoke-1")
    ).toHaveText(/fail-once\.txt/);
    await expect(content.getByText(chatSmokeAssistantReply)).toBeVisible();
    expect(stub.uploads.map((upload) => upload.filename)).toEqual([
      "smoke.txt",
      "fail-once.txt",
    ]);
    expect(stub.messageBodies).toEqual([
      expect.objectContaining({
        message: expect.objectContaining({
          text: expect.stringContaining("Attached files in your workspace:"),
        }),
        skills: [{ location: chatSmokeSkill.location }],
      }),
    ]);
    expect(
      (stub.messageBodies[0] as { message?: { text?: string } }).message?.text
    ).toContain("请总结周会 /weekly-summary\n\nAttached files in your workspace:");
    expect(
      (stub.messageBodies[0] as { message?: { text?: string } }).message?.text
    ).toContain(stub.uploads[0]!.path);
    await content.getByTestId(`chat-ref-card-${chatSmokeTaskConversation.id}`).click();
    await content
      .getByTestId("chat-sidebar")
      .getByRole("button", { name: "Open task", exact: true })
      .click();
    await expect(page).toHaveURL(
      new RegExp(
        `#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    await expect(
      content.getByTestId("comma-route-outlet").getByTestId("task-conversation-status")
    ).toHaveText("Done");
    await expect(content.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
    expect(
      stub.authCookies.some((cookie) =>
        cookie?.includes(`comma_session=${testSession.token}`)
      )
    ).toBe(true);
  } finally {
    await stub.close();
  }
});

test("Comma Center sends through its single assistant conversation and keeps history", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await installBrowserTestSession(page, {
      ...testSession,
      apiBaseUrl: stub.baseUrl,
    });

    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    const textbox = composer.getByRole("textbox", { name: "AI prompt" });

    await expect(composer).toBeVisible();
    await textbox.fill("Comma Center smoke");
    const send = composer.getByRole("button", { name: "Send" });
    await expect(send).toBeEnabled();
    await send.click();

    await expect(content.getByText("Comma Center smoke")).toBeVisible();
    await expect(content.getByText(chatSmokeAssistantReply)).toBeVisible();
    await expect(page).toHaveURL(/#\/$|\/$/);
    expect(stub.chatMessageBodies).toEqual([
      expect.objectContaining({
        message: { text: "Comma Center smoke", type: "text" },
      }),
    ]);

    await content.getByTestId(`chat-ref-card-${chatSmokeTaskConversation.id}`).click();
    await expect(page).toHaveURL(/#\/$|\/$/);
    const chatSidebar = content.getByTestId("chat-sidebar");
    await expect(chatSidebar).toBeVisible();
    await expect(
      chatSidebar.getByRole("tab", {
        exact: true,
        name: chatSmokeTaskConversation.title,
      })
    ).toHaveAttribute("aria-selected", "true");
    await expect(
      chatSidebar.getByTestId(
        `chat-sidebar-conversation-${chatSmokeTaskConversation.id}`
      )
    ).toBeVisible();
    await expect(chatSidebar.getByRole("textbox", { name: "AI prompt" })).toBeVisible();

    await page.reload();
    await expect(content.getByText("Comma Center smoke")).toBeVisible();
    await expect(content.getByText(chatSmokeAssistantReply)).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("web Chat follows Participant status and commits one streamed reply", async ({
  page,
}) => {
  const assistantDraft = "STREAMING_E2E_";
  const assistantReply = "STREAMING_E2E_COMPLETE";
  const stub = await startChatSmokeStub({
    assistantDraft,
    assistantReply,
    holdStreamingReplyStart: true,
    streamAssistantReply: true,
  });

  try {
    await installBrowserTestSession(page, {
      ...testSession,
      apiBaseUrl: stub.baseUrl,
    });

    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    const textbox = composer.getByRole("textbox", { name: "AI prompt" });

    await textbox.fill("Verify streamed completion state");
    await composer.getByRole("button", { name: "Send" }).click();

    const draft = content.getByTestId("chat-assistant-draft");
    const participantStatus = content.getByTestId("participant-status-slot");
    await expect(participantStatus).toHaveAttribute("data-active", "true");
    await expect(participantStatus).toContainText("Thinking");

    stub.startStreamingReply();
    await stub.waitForDraft();
    await expect(draft).toContainText(assistantDraft);
    await expect(participantStatus).toHaveAttribute("data-state", "active");
    await expect(participantStatus).toHaveAttribute("data-active", "false");
    await expect(participantStatus).toBeHidden();

    stub.completeStreamingReply();

    await expect(content.getByText(assistantReply, { exact: true })).toHaveCount(1);
    await expect(draft).toHaveCount(0);
    await expect(participantStatus).toHaveAttribute("data-state", "stopped");
    await expect(participantStatus).toHaveAttribute("data-active", "false");
  } finally {
    await stub.close();
  }
});
