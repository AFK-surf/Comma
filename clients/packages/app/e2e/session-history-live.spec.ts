import { expect, test } from "@playwright/test";
import type { ServerResponse } from "node:http";
import type { SessionHistoryRecord } from "@comma/native-bridge";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspaceChat, startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import { enableSessionHistory } from "./session-history-settings";

test.beforeEach(async ({ context }) => {
  await enableSessionHistory(context);
});

const send = (
  response: ServerResponse,
  phase: string,
  rows: SessionHistoryRecord[],
  live: SessionHistoryRecord[] = []
) =>
  response.write(
    `event: history\ndata: ${JSON.stringify({
      conversation_id: chatSmokeWorkspaceChat.id,
      participant_id: "ptp-router-smoke",
      phase,
      records: rows,
      live_records: live,
      server_time_ms: Date.now(),
      checkpoint: "200",
    })}\n\n`
  );

test("hover and detail share SSE updates while the mini keeps a real three-minute window", async ({
  page,
}) => {
  const epoch = Date.now();
  await page.clock.setFixedTime(epoch);
  const records: SessionHistoryRecord[] = Array.from({ length: 200 }, (_, i) => ({
    id: String(i + 1),
    kind: "user",
    content: { content: `Timed input ${i + 1}` },
    timestamp_ms: epoch - (199 - i) * 1000,
  }));
  const streams = new Set<ServerResponse>();
  const requests: URL[] = [];
  const stub = await startChatSmokeStub({
    sessionEmail: "live-history@comma.local",
    sessionHistory: (url) => {
      requests.push(url);
      const rows = records.slice(-Number(url.searchParams.get("limit")));
      return {
        body: {
          conversation_id: chatSmokeWorkspaceChat.id,
          participant_id: "ptp-router-smoke",
          records: rows,
          has_more: true,
          next_before: rows[0]!.id,
        },
      };
    },
    sessionHistoryEvents: (_url, response) => {
      streams.add(response);
      response.on("close", () => streams.delete(response));
      for (let index = 0; index < records.length; index += 50)
        send(response, "recent", records.slice(index, index + 50));
      send(response, "checkpoint", []);
    },
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "live-history@comma.local",
      token: "comma_sess_live",
    });
    await page.goto("/");
    await page.getByRole("textbox", { name: "AI prompt" }).click();
    const participant = page.getByTestId("session-history-participant");
    await participant.click();
    const history = page.getByTestId("session-history-page");
    await expect(history.locator("article")).toHaveCount(50);
    const ledger = history.getByRole("region", {
      name: "Execution records",
      exact: true,
    });
    const bottomGap = () =>
      ledger.evaluate((el) => el.scrollHeight - el.clientHeight - el.scrollTop);
    await expect.poll(bottomGap).toBeLessThanOrEqual(4);
    await page.getByRole("textbox", { name: "AI prompt" }).click();
    await participant.hover();
    const preview = page.getByTestId("session-history-preview");
    const mini = preview.getByTestId("session-history-mini-timeline");
    await expect(mini).toBeVisible();
    await expect
      .poll(() => mini.locator("[data-span-id]").count())
      .toBeGreaterThan(100);
    await expect(preview.locator(".comma-session-preview-row")).toHaveCount(3);
    const range = await mini.evaluate((e) => [
      Number(e.getAttribute("data-start-ms")),
      Number(e.getAttribute("data-end-ms")),
    ]);
    expect(range[1]! - range[0]!).toBe(180_000);
    expect(streams.size).toBe(1);
    const initialRequests = requests.length;
    const live: SessionHistoryRecord = {
      id: "execution:tool:parallel-read",
      kind: "tool",
      timestamp_ms: epoch,
      content: { tool_call_id: "parallel-read", tool_name: "read", status: "running" },
      execution: {
        id: "parallel-read",
        lane: "tool",
        started_at_ms: epoch,
        observed_at_ms: epoch,
        completed_at_ms: null,
        duration_ms: 0,
        live: true,
      },
    };
    for (const response of streams) send(response, "checkpoint", [], [live]);
    await page.clock.setFixedTime(epoch + 10_000);
    const fullTool = history.locator('[data-span-id="tool:parallel-read"]');
    const miniTool = mini.locator('[data-span-id="tool:parallel-read"]');
    await expect(fullTool).toBeVisible();
    await expect(miniTool).toBeVisible();
    await expect.poll(bottomGap).toBeLessThanOrEqual(4);
    await expect
      .poll(async () => Number(await miniTool.getAttribute("data-end-ms")) - epoch)
      .toBeGreaterThan(9000);
    await expect
      .poll(async () => Number(await fullTool.getAttribute("data-end-ms")) - epoch)
      .toBeGreaterThan(9000);
    // The first duration adds a second line to the live row without a new record.
    await expect(
      history.locator('[data-record-id="tool:parallel-read"] .comma-session-duration')
    ).toBeVisible();
    await expect.poll(bottomGap).toBeLessThanOrEqual(4);
    await miniTool.hover();
    const inspector = page.getByTestId("session-timeline-inspector");
    await expect(inspector).toContainText("Read file");
    await expect(inspector).toContainText("In progress");
    await expect(inspector.getByTestId("session-inspector-duration")).toHaveText("10s");
    await expect(preview).toBeVisible();
    await page.clock.setFixedTime(epoch + 11_000);
    await expect(inspector.getByTestId("session-inspector-duration")).toHaveText("11s");
    const final: SessionHistoryRecord = {
      ...live,
      id: "201",
      execution: {
        ...live.execution!,
        live: false,
        observed_at_ms: epoch + 12_000,
        completed_at_ms: epoch + 12_000,
        duration_ms: 12_000,
      },
      content: {
        tool_call_id: "parallel-read",
        tool_name: "read",
        status: "completed",
        content: "Complete",
      },
    };
    for (const response of streams) send(response, "update", [final]);
    await expect(fullTool).toHaveAttribute("data-end-ms", String(epoch + 12_000));
    await expect(miniTool).toHaveAttribute("data-end-ms", String(epoch + 12_000));
    await expect(
      history.locator('[data-record-id="tool:parallel-read"] .comma-session-duration')
    ).toHaveText("12s");
    await expect(preview.locator(".comma-session-duration").last()).toHaveText("12s");
    await expect(inspector.getByTestId("session-inspector-duration")).toHaveText("12s");
    await expect(inspector).toContainText("Completed");
    await fullTool.hover();
    await expect(inspector).toHaveCount(1);
    await expect(inspector).toContainText("Complete");
    await expect(inspector.getByTestId("session-inspector-duration")).toHaveText("12s");
    await fullTool.focus();
    await page.keyboard.press("Escape");
    await expect(inspector).toHaveCount(0);
    await page.getByRole("textbox", { name: "AI prompt" }).click();
    await participant.hover();
    await expect(preview).toBeVisible();
    // Advance the window after inspecting the bar: it moves away from the pointer.
    await page.clock.setFixedTime(epoch + 60_000);
    await expect
      .poll(async () => Number(await mini.getAttribute("data-end-ms")) - range[1]!)
      .toBe(60_000);
    await expect(mini.locator('[data-span-id="record:30"]')).toHaveCount(0);
    expect(requests).toHaveLength(initialRequests);
    await expect(history.locator("article")).toHaveCount(51);
    const model: SessionHistoryRecord = {
      id: "202",
      kind: "assistant",
      timestamp_ms: epoch + 58_000,
      content: {
        model: "test-model",
        input_tokens: 2500,
        output_tokens: 800,
        cache_read_input_tokens: 2000,
      },
      execution: {
        id: "model-final",
        lane: "model",
        started_at_ms: epoch + 58_000,
        first_token_at_ms: epoch + 58_500,
        observed_at_ms: epoch + 60_000,
        completed_at_ms: epoch + 60_000,
        duration_ms: 2000,
      },
    };
    for (const response of streams) send(response, "update", [model]);
    const modelMetrics = history.locator(
      '[data-record-id="202"] [data-testid="session-model-metrics"]'
    );
    await expect(modelMetrics).toContainText("TTFT 500ms");
    await expect(modelMetrics).toContainText("Output tokens 800");
    await expect(modelMetrics).toContainText("Cache hit 80%");
    await mini.locator('[data-span-id="record:202"]').hover();
    await expect(inspector).toContainText("80%");
    await expect(inspector).toContainText("2,500");
    expect(requests).toHaveLength(initialRequests);
    // Following the tail survives streamed insertions and updates to an existing row.
    await expect.poll(bottomGap).toBeLessThanOrEqual(4);
    await ledger.evaluate((el) => {
      el.scrollTop = el.scrollHeight;
    });
    const appended: SessionHistoryRecord = {
      id: "203",
      kind: "user",
      timestamp_ms: epoch + 60_000,
      content: { content: "Newest streamed event" },
    };
    for (const response of streams) send(response, "update", [appended]);
    await expect(history.locator('[data-record-id="203"]')).toBeVisible();
    await expect.poll(bottomGap).toBeLessThanOrEqual(4);
    await history.locator('[data-record-id="203"] summary').click();
    await expect.poll(bottomGap).toBeLessThanOrEqual(4);
    for (const response of streams)
      send(response, "update", [
        {
          ...appended,
          content: {
            content: "Expanded streamed event",
            debug: Array.from({ length: 20 }, (_, i) => `Detail ${i}`),
          },
        },
      ]);
    await expect(history.locator('[data-record-id="203"]')).toContainText(
      "Expanded streamed event"
    );
    await expect.poll(bottomGap).toBeLessThanOrEqual(4);

    // Read away from the tail without entering the older-page trigger at
    // the top. This assertion tests SSE anchoring, not page insertion.
    const readingPosition = await ledger.evaluate(
      (el) =>
        new Promise<number>((resolve) => {
          const target = Math.round((el.scrollHeight - el.clientHeight) / 2);
          el.addEventListener("scroll", () => resolve(target), { once: true });
          el.scrollTop = target;
        })
    );
    await expect
      .poll(() => ledger.evaluate((el) => el.scrollTop))
      .toBe(readingPosition);
    for (const response of streams)
      send(response, "update", [{ ...appended, id: "204" }]);
    await expect(history.locator('[data-record-id="204"]')).toHaveCount(1);
    expect(await ledger.evaluate((el) => el.scrollTop)).toBe(readingPosition);
    expect(requests).toHaveLength(initialRequests);
    await ledger.evaluate(
      (el) =>
        new Promise<void>((resolve) => {
          el.addEventListener("scroll", () => resolve(), { once: true });
          el.scrollTop = el.scrollHeight;
        })
    );
    await expect.poll(bottomGap).toBeLessThanOrEqual(4);
    for (const response of streams)
      send(response, "update", [{ ...appended, id: "205" }]);
    await expect(history.locator('[data-record-id="205"]')).toBeVisible();
    await expect.poll(bottomGap).toBeLessThanOrEqual(4);
    // A late async result belongs at its execution start, not at the SSE tail.
    const late: SessionHistoryRecord = {
      ...final,
      id: "206",
      kind: "session.async_tool_call_completed",
      timestamp_ms: epoch + 62_000,
      content: {
        tool_call_id: "late-read",
        tool_name: "read",
        status: "completed",
        content: "Late async result",
      },
      execution: {
        ...final.execution!,
        id: "late-read",
        started_at_ms: epoch + 5000,
        observed_at_ms: epoch + 62_000,
        completed_at_ms: epoch + 62_000,
        duration_ms: 57_000,
      },
    };
    for (const response of streams) send(response, "update", [late]);
    await expect
      .poll(() =>
        history
          .locator("article")
          .evaluateAll((rows) =>
            rows.slice(-6).map((row) => row.getAttribute("data-record-id"))
          )
      )
      .toEqual(["tool:parallel-read", "tool:late-read", "202", "203", "204", "205"]);
    await expect.poll(bottomGap).toBeLessThanOrEqual(4);
    await page.getByRole("textbox", { name: "AI prompt" }).click();
    await participant.hover();
    await expect(preview).toBeVisible();
    await expect(preview).not.toContainText("Late async result");
    await expect(mini.locator('[data-span-id="tool:late-read"]')).toHaveAttribute(
      "data-start-ms",
      String(epoch + 5000)
    );
    // A reader away from the tail keeps the same row when SSE inserts above it.
    await page.getByRole("textbox", { name: "AI prompt" }).click();
    await ledger.evaluate(
      (el) =>
        new Promise<void>((resolve) => {
          el.addEventListener("scroll", () => resolve(), { once: true });
          el.scrollTop = 400;
        })
    );
    const anchor = await ledger.evaluate((el) => {
      const top = el.getBoundingClientRect().top;
      const row = Array.from(el.querySelectorAll<HTMLElement>("article")).find(
        (candidate) => candidate.getBoundingClientRect().top >= top
      )!;
      return {
        id: row.dataset.recordId!,
        offset: row.getBoundingClientRect().top - top,
      };
    });
    for (const response of streams)
      send(response, "update", [
        {
          id: "207",
          kind: "runtime",
          timestamp_ms: epoch - 100_000,
          content: {
            content: "Late runtime notice before the current reading position",
          },
        },
      ]);
    await expect(history.locator('[data-record-id="207"]')).toHaveCount(1);
    await expect
      .poll(() =>
        ledger.evaluate((el, saved) => {
          const row = Array.from(el.querySelectorAll<HTMLElement>("article")).find(
            (candidate) => candidate.dataset.recordId === saved.id
          )!;
          return Math.abs(
            row.getBoundingClientRect().top -
              el.getBoundingClientRect().top -
              saved.offset
          );
        }, anchor)
      )
      .toBeLessThan(3);
    expect(requests).toHaveLength(initialRequests);
  } finally {
    await stub.close();
  }
});
