import { expect, test, type Page } from "./support/page";
import { useWebApp } from "./support/web-app";

// The web app, its client core's worker and the chat stub server run as one
// world: what a test sees depends on the code, not on how long the worker,
// the network or the server took.
const assistantDraft = "STREAMING_E2E_";
const assistantReply = "STREAMING_E2E_COMPLETE";
const app = useWebApp(
  {
    assistantDraft,
    assistantReply,
    holdStreamingReplyStart: true,
    streamAssistantReply: true,
  },
  { records: true }
);

/** The scenario's steps and assertions. */
async function streamedReply(page: Page) {
  const content = page.getByRole("region", { name: "Content" });
  const composer = content.locator(".comma-chat-composer");
  const textbox = composer.getByRole("textbox", { name: "AI prompt" });

  await textbox.fill("Verify streamed completion state");
  await composer.getByRole("button", { name: "Send" }).click();

  const draft = content.getByTestId("chat-assistant-draft");
  const participantStatus = content.getByTestId("participant-status-slot");
  await expect(participantStatus).toHaveAttribute("data-active", "true");
  await expect(participantStatus).toContainText("Thinking");

  await app.stub().call("startStreamingReply");
  await expect(draft).toContainText(assistantDraft);
  await expect(participantStatus).toHaveAttribute("data-state", "active");
  await expect(participantStatus).toHaveAttribute("data-active", "false");
  await expect(participantStatus).toBeHidden();

  await app.stub().call("completeStreamingReply");

  await expect(content.getByText(assistantReply, { exact: true })).toHaveCount(1);
  await expect(draft).toHaveCount(0);
  await expect(participantStatus).toHaveAttribute("data-state", "stopped");
  await expect(participantStatus).toHaveAttribute("data-active", "false");
}

test("web Chat follows Participant status and commits one streamed reply", async ({
  page,
}) => {
  await app.open(page);
  await streamedReply(page);
});
