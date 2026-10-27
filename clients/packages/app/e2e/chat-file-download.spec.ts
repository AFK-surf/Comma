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
    // A browser downloads from the attachment's media URL, which the server refuses for one it cannot read.
    await page.route(
      "**/messages/msg_worker_file/attachments/2/media",
      async (route) => {
        attachmentRequests += 1;
        await route.fulfill({
          status: 404,
          contentType: "application/json",
          body: JSON.stringify({ error: "not_found" }),
        });
      }
    );
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
  let mediaRequests = 0;
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "file-retry@comma.local",
      token: "comma_sess_file_retry",
    });
    await page.addInitScript(() => {
      window.open = () => null;
    });
    await page
      .context()
      .route("**/messages/msg_worker_retry/attachments/0", async (route) => {
        attachmentRequests += 1;
        await route.fulfill({
          status: 200,
          contentType: "application/pdf",
          headers: {
            "content-disposition": "attachment; filename*=UTF-8''report.pdf",
          },
          body: pdfBytes,
        });
      });
    // The browser downloads from the attachment's media URL: the first time the
    // server cannot give one, the next it does (the stub's, the attachment's own address).
    await page.route(
      "**/messages/msg_worker_retry/attachments/0/media",
      async (route) => {
        mediaRequests += 1;
        if (mediaRequests === 1) {
          await route.fulfill({
            status: 503,
            contentType: "application/json",
            body: JSON.stringify({ error: "workspace_file_unavailable" }),
          });
        } else {
          await route.fallback();
        }
      }
    );
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
    expect(mediaRequests).toBe(1);
    expect(attachmentRequests).toBe(1);
    const downloaded = page.waitForEvent("download");
    await retry.click();
    const download = await downloaded;
    expect(download.suggestedFilename()).toBe("report.pdf");
    expect(await download.failure()).toBeNull();
    expect(await readFile((await download.path())!)).toEqual(pdfBytes);
    expect(mediaRequests).toBe(2);
    expect(attachmentRequests).toBe(2);
    expect(page.context().pages()).toEqual([page]);
  } finally {
    await stub.close();
  }
});

// The browser owns the file body once its download starts. Later iframe navigation
// must keep that transfer alive and leave the conversation and draft in place.
test("an agent's file over 10 MB downloads without leaving the conversation or cancelling an earlier body", async ({
  page,
}) => {
  const archive = Buffer.alloc(12_000_000, 7);
  const mintRequested = Promise.withResolvers<void>();
  const mintHeld = Promise.withResolvers<void>();
  const firstBodyHeld = Promise.withResolvers<void>();
  let mediaRequests = 0;
  const stub = await startChatSmokeStub({
    extraRoutes: async (_request, url, response) => {
      if (url.pathname === "/archive-denied") {
        response.writeHead(403, { "content-type": "text/html" });
        response.end(
          '<script>top.location.href="/escaped";window.open("/escaped")</script>'
        );
        return true;
      }
      if (url.pathname !== "/archive-first" && url.pathname !== "/archive-second")
        return false;
      const first = url.pathname === "/archive-first";
      response.writeHead(200, {
        "content-type": "application/zip",
        "content-length": archive.length,
        "content-disposition": `attachment; filename="${first ? "dataset.zip" : "dataset-copy.zip"}"`,
      });
      if (first) {
        response.write(archive.subarray(0, 4096));
        await firstBodyHeld.promise;
        response.end(archive.subarray(4096));
      } else {
        response.end(archive);
      }
      return true;
    },
    taskTranscript: [
      {
        actor_type: "agent",
        agent_id: "worker_file",
        message_id: "msg_worker_archive",
        kind: "message",
        role_label: "worker",
        content: [
          {
            type: "file",
            file_name: "dataset.zip",
            mime_type: "application/zip",
            blob_ref: { uuid: "u", hash: "h", size: archive.length },
          },
        ],
      },
    ],
  });
  const targets = [
    "archive-denied",
    "archive-timeout",
    "archive-first",
    "archive-second",
  ].map((path) => `${stub.baseUrl}/${path}`);
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "file-archive@comma.local",
      token: "comma_sess_file_archive",
    });
    await page.route(
      "**/messages/msg_worker_archive/attachments/0/media",
      async (route) => {
        const url = targets[mediaRequests++]!;
        if (mediaRequests === 1) {
          mintRequested.resolve();
          await mintHeld.promise;
        }
        await route.fulfill({ json: { url, expires_at: 4_102_444_800 } });
      }
    );
    await page.route(targets[1]!, (route) => route.abort("timedout"));
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const conversationUrl = page.url();
    const prompt = page.getByRole("textbox", { name: "AI prompt" });
    const draft = "Keep this draft while downloading.";
    await prompt.fill(draft);
    await page
      .locator(".chat-panel-file")
      .filter({ hasText: "dataset.zip" })
      .getByRole("button", { name: "Preview dataset.zip", exact: true })
      .click();
    const preview = page.getByTestId("file-preview-panel");
    await expect(
      preview.getByText("A preview is not available for this file type.")
    ).toBeVisible();
    expect(stub.attachmentReads).toEqual([]);

    const downloadButton = preview.getByRole("button", {
      name: "Download dataset.zip",
      exact: true,
    });
    await downloadButton.click();
    await mintRequested.promise;
    expect(page.context().pages()).toEqual([page]);
    const denied = page.waitForResponse(targets[0]!);
    mintHeld.resolve();
    const deniedResponse = await denied;
    expect(deniedResponse.status()).toBe(403);
    const downloadFrame = deniedResponse.frame();
    expect(downloadFrame).not.toBe(page.mainFrame());
    await downloadFrame.waitForURL(targets[0]!, { waitUntil: "load" });
    expect(await (await downloadFrame.frameElement()).isVisible()).toBe(false);
    await expect(page).toHaveURL(conversationUrl);
    await expect(prompt).toHaveText(draft);

    const remoteFailure = page.waitForEvent("requestfailed", {
      predicate: (request) => request.url() === targets[1],
    });
    await downloadButton.click();
    const failedRequest = await remoteFailure;
    // Each download navigates a hidden frame of its own.
    const failedFrame = failedRequest.frame();
    expect([page.mainFrame(), downloadFrame]).not.toContain(failedFrame);
    expect(failedRequest.failure()?.errorText).toContain("TIMED_OUT");
    await expect(page).toHaveURL(conversationUrl);
    await expect(prompt).toHaveText(draft);
    await expect(page.getByTestId("file-download")).toContainText("Download started");
    await expect(page.getByText("Download complete", { exact: true })).toHaveCount(0);

    const firstStarted = page.waitForEvent("download");
    const firstRequest = page.waitForRequest(targets[2]!);
    await downloadButton.click();
    const firstDownload = await firstStarted;
    const firstFrame = (await firstRequest).frame();
    expect([page.mainFrame(), downloadFrame, failedFrame]).not.toContain(firstFrame);
    expect(firstDownload.suggestedFilename()).toBe("dataset.zip");
    // The first response body is still held when another frame starts the second.
    const secondStarted = page.waitForEvent("download");
    const secondRequest = page.waitForRequest(targets[3]!);
    await downloadButton.click();
    const secondDownload = await secondStarted;
    const secondFrame = (await secondRequest).frame();
    expect([page.mainFrame(), downloadFrame, failedFrame, firstFrame]).not.toContain(
      secondFrame
    );
    expect(secondDownload.suggestedFilename()).toBe("dataset-copy.zip");
    expect((await readFile((await secondDownload.path())!)).equals(archive)).toBe(true);
    firstBodyHeld.resolve();
    expect((await readFile((await firstDownload.path())!)).equals(archive)).toBe(true);
    expect(page.context().pages()).toEqual([page]);
    expect(page.frames()).toEqual([
      page.mainFrame(),
      downloadFrame,
      failedFrame,
      firstFrame,
      secondFrame,
    ]);
    await expect(page).toHaveURL(conversationUrl);
    await expect(prompt).toHaveText(draft);
  } finally {
    mintHeld.resolve();
    firstBodyHeld.resolve();
    await page.unrouteAll({ behavior: "wait" });
    await stub.close();
  }
});
