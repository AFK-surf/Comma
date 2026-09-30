import { createHash } from "node:crypto";
import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { openTaskDetails } from "../../../e2e/helpers/task-panel";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

test("message and Task details use the same Worker avatar colors", async ({ page }) => {
  const agentId = "agt1_worker_1";
  const actorId = `actor_${createHash("sha256").update(agentId).digest("base64url")}`;
  const stub = await startChatSmokeStub({
    taskStatus: "active",
    taskSchedule: null,
    taskTranscript: [
      {
        actor_type: "agent",
        agent_id: agentId,
        role_label: "worker",
        content: [{ type: "text", text: "Worker completed the task." }],
        created_at: 1_720_000_004,
        kind: "message",
        message_id: "msg_worker_avatar",
      },
    ],
  });
  try {
    stub.setTaskParticipants([], {
      participant_id: "ptc_worker",
      actor_id: actorId,
      name: "Default workspace Worker",
    });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "worker-avatar@comma.local",
      token: "comma_sess_worker_avatar",
    });
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const messageAvatar = page.locator(
      '[data-message-id="msg_worker_avatar"] > .comma-chat-assistant-source-avatar'
    );
    await expect(messageAvatar).toBeVisible();
    const details = await openTaskDetails(page);
    const sidebarAvatar = details.locator(
      '[data-testid="task-panel-worker"] .comma-session-avatar'
    );
    await expect(sidebarAvatar).toBeVisible();
    await expect(sidebarAvatar).toHaveCSS("background-image", /radial-gradient/);
    const palette = await sidebarAvatar.evaluate((element) => {
      const style = getComputedStyle(element);
      return {
        backgroundColor: style.backgroundColor,
        backgroundImage: style.backgroundImage,
      };
    });
    await expect(messageAvatar).toHaveCSS("background-image", palette.backgroundImage);
    await expect(messageAvatar).toHaveCSS("background-color", palette.backgroundColor);
  } finally {
    await stub.close();
  }
});
