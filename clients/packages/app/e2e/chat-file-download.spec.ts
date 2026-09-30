import { expect, test } from "@playwright/test";
import { readFile } from "node:fs/promises";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

test("a worker file without bound bytes is descriptive, while an unavailable bound attachment reports retrieval failure", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    taskTranscript: [
      {
        actor_type: "agent",
        agent_id: "worker_file",
        message_id: "msg_worker_file",
        kind: "message",
        role_label: "worker",
        content: [
          { type: "text", text: "The report is ready." },
          {
            type: "file",
            file_name: "unbound.pdf",
            file_ref: { environment_id: "vfs", path: "/unbound.pdf" },
          },
          {
            type: "file",
            file_name: "Apple_Report_2026.pdf",
            mime_type: "application/pdf",
            blob_ref: {
              kind: "blob",
              uuid: "a".repeat(32),
              hash: "b".repeat(64),
              size: 64,
            },
          },
        ],
      },
    ],
  });
  let attachmentRequests = 0;
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "file-download@comma.local",
      token: "comma_sess_file_download",
    });
    await page.route("**/messages/msg_worker_file/attachments/*", async (route) => {
      attachmentRequests += 1;
      expect(route.request().url()).toMatch(/\/attachments\/2$/);
      await route.fulfill({
        status: 404,
        contentType: "application/json",
        body: JSON.stringify({ error: "not_found" }),
      });
    });
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const unbound = page.locator(".chat-panel-file").filter({ hasText: "unbound.pdf" });
    await expect(unbound).toBeVisible();
    await expect(
      unbound.getByRole("button", { name: "Download", exact: true })
    ).toHaveCount(0);
    const bound = page
      .locator(".chat-panel-file")
      .filter({ hasText: "Apple_Report_2026.pdf" });
    await expect(
      bound.getByRole("button", { name: "Download", exact: true })
    ).toHaveCount(0);
    await bound
      .getByRole("button", { name: "Preview Apple_Report_2026.pdf", exact: true })
      .click();
    const preview = page.getByTestId("file-preview-panel");
    await expect(preview.getByText("Could not preview this file.")).toBeVisible();
    expect(attachmentRequests).toBe(1);
    const download = preview.getByRole("button", {
      name: "Download Apple_Report_2026.pdf",
      exact: true,
    });
    await download.click();
    await expect(
      page.getByText(
        "Apple_Report_2026.pdf is unavailable. Ask the sender to attach the file again."
      )
    ).toBeVisible();
    await expect(
      page.getByText(/could not be saved to your Downloads folder/)
    ).toHaveCount(0);
    await expect(download).toBeDisabled();
    expect(attachmentRequests).toBe(2);
  } finally {
    await stub.close();
  }
});

test("a temporary attachment failure can be retried to download the worker's bytes", async ({
  page,
}) => {
  const pdfBytes = Buffer.from("%PDF-1.7\nworker attachment\n%%EOF\n");
  const stub = await startChatSmokeStub({
    taskTranscript: [
      {
        actor_type: "agent",
        agent_id: "worker_file",
        message_id: "msg_worker_retry",
        kind: "message",
        role_label: "worker",
        content: [
          {
            type: "file",
            file_name: "folder/report.pdf",
            mime_type: "application/pdf",
            blob_ref: { uuid: "u", hash: "h", size: pdfBytes.length },
          },
        ],
      },
    ],
  });
  let attachmentRequests = 0;
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "file-retry@comma.local",
      token: "comma_sess_file_retry",
    });
    await page.route("**/messages/msg_worker_retry/attachments/0", async (route) => {
      attachmentRequests += 1;
      if (attachmentRequests === 2) {
        await route.fulfill({
          status: 503,
          contentType: "application/json",
          body: JSON.stringify({ error: "workspace_file_unavailable" }),
        });
      } else {
        await route.fulfill({
          status: 200,
          contentType: "application/pdf",
          body: pdfBytes,
        });
      }
    });
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const file = page.locator(".chat-panel-file").filter({ hasText: "report.pdf" });
    await expect(
      file.getByRole("button", { name: "Download", exact: true })
    ).toHaveCount(0);
    await file.getByRole("button", { name: "Preview report.pdf", exact: true }).click();
    await expect.poll(() => attachmentRequests).toBe(1);
    const retry = page
      .getByTestId("file-preview-panel")
      .getByRole("button", { name: "Download report.pdf", exact: true });
    await retry.click();
    await expect(
      page.getByText(
        "report.pdf could not be retrieved. The network or service may be unavailable; try again shortly."
      )
    ).toBeVisible();
    await expect(retry).toBeEnabled();
    expect(attachmentRequests).toBe(2);
    const downloaded = page.waitForEvent("download");
    await retry.click();
    const download = await downloaded;
    expect(download.suggestedFilename()).toBe("report.pdf");
    expect(await download.failure()).toBeNull();
    expect(await readFile((await download.path())!)).toEqual(pdfBytes);
    expect(attachmentRequests).toBe(3);
  } finally {
    await stub.close();
  }
});
