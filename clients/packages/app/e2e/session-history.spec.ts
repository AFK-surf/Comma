import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspaceChat, startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import {
  sessionStressLiveRecord,
  sessionStressRecords,
  startSessionStressStub,
} from "./session-history-stress";
import { enableSessionHistory } from "./session-history-settings";

test.beforeEach(async ({ context }) => {
  await enableSessionHistory(context);
});

test("Session folds idle into a divider with a hoverable top dot without compressing actual execution", async ({
  page,
}) => {
  const epoch = 1788564963000;
  await page.clock.setFixedTime(new Date(epoch + 7_219_100));
  const execution = (
    id: string,
    lane: "model" | "tool",
    start: number,
    end: number
  ) => ({
    id,
    lane,
    started_at_ms: epoch + start,
    observed_at_ms: epoch + end,
    completed_at_ms: epoch + end,
    duration_ms: end - start,
  });
  const records = [
    {
      id: "1",
      kind: "user",
      content: { content: "Earlier request" },
      timestamp_ms: epoch,
    },
    {
      id: "2",
      kind: "assistant",
      content: { content: "Finished" },
      timestamp_ms: epoch + 1000,
      execution: execution("old", "model", 0, 1000),
    },
    {
      id: "3",
      kind: "summary",
      content: { content: "New input context" },
      timestamp_ms: epoch + 7_200_000,
    },
    {
      id: "4",
      kind: "user",
      content: { content: "New request" },
      timestamp_ms: epoch + 7_200_000,
    },
    {
      id: "5",
      kind: "assistant",
      content: { content: "New response" },
      timestamp_ms: epoch + 7_219_000,
      execution: execution("new", "model", 7_201_000, 7_219_000),
    },
    {
      id: "6",
      kind: "tool",
      content: {
        type: "tool_call_completed",
        tool_name: "im_api.internal.send_message",
        result: {
          status: "completed",
          input: { conversation_id: chatSmokeWorkspaceChat.id, content: "Hello there" },
          content: { sent: true },
        },
      },
      timestamp_ms: epoch + 7_219_080,
      execution: execution("send", "tool", 7_219_000, 7_219_080),
    },
    {
      id: "7",
      kind: "tool",
      content: { status: "running", tool_name: "background.read" },
      timestamp_ms: epoch + 7_219_100,
      execution: {
        ...execution("pending", "tool", 7_219_090, 7_219_100),
        completed_at_ms: null,
      },
    },
  ];
  const stub = await startChatSmokeStub({
    sessionEmail: "idle@comma.local",
    sessionHistory: (url) => ({
      body: {
        conversation_id: chatSmokeWorkspaceChat.id,
        participant_id: "ptp-router-smoke",
        records: records.slice(-Number(url.searchParams.get("limit"))),
        has_more: false,
        next_before: null,
      },
    }),
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "idle@comma.local",
      token: "comma_sess_idle",
    });
    await page.goto("/");
    await page.getByRole("textbox", { name: "AI prompt" }).click();
    await page.getByTestId("session-history-participant").hover();
    const preview = page.getByTestId("session-history-preview");
    const mini = preview.getByTestId("session-history-mini-timeline");
    await expect(mini).toBeVisible();
    await expect(mini).toHaveAttribute("data-start-ms", String(epoch + 7_039_100));
    await expect(mini).toHaveAttribute("data-end-ms", String(epoch + 7_219_100));
    await expect(mini.locator("[data-span-id]")).toHaveCount(3);
    await expect(mini.locator('[data-span-id="record:5"]')).toHaveAttribute(
      "data-start-ms",
      String(epoch + 7_201_000)
    );
    await expect(mini.locator('[data-span-id="tool:pending"]')).toHaveAttribute(
      "data-display-shape",
      "open"
    );
    await expect(preview.locator(".comma-session-preview-row")).toHaveCount(3);
    await expect(preview.locator(".comma-session-duration").first()).toHaveText("18s");
    await expect(preview.locator(".comma-session-summary").first()).toHaveText(
      "New response"
    );
    const previewTime = await preview.locator("time").last().textContent();
    await expect(preview.locator("details")).toHaveCount(0);
    await expect(mini.getByRole("button")).toHaveCount(3);
    await mini.locator('[data-span-id="tool:pending"]').hover();
    const inspector = page.getByTestId("session-timeline-inspector");
    await expect(inspector).toContainText("background.read");
    await expect(inspector).toContainText("End not recorded");
    await inspector.hover();
    await expect(preview).toBeVisible();
    await expect(inspector).toBeVisible();
    await mini.locator('[data-span-id="tool:send"]').focus();
    await expect(inspector.locator(".comma-session-inspector-operation")).toHaveText(
      `${chatSmokeWorkspaceChat.title} · Hello there`
    );
    await expect(inspector).not.toContainText(chatSmokeWorkspaceChat.id);
    await expect(inspector).not.toContainText("Message sent");
    expect((await inspector.textContent())!.split("Hello there")).toHaveLength(2);
    const sendPreview = preview.locator(".comma-session-preview-row").nth(1);
    await expect(sendPreview).not.toContainText(chatSmokeWorkspaceChat.id);
    expect((await sendPreview.textContent())!.split("Hello there")).toHaveLength(2);
    await mini.locator('[data-span-id="record:5"]').hover();
    await expect(inspector).toContainText("New response");
    await expect(inspector.getByTestId("session-inspector-duration")).toHaveText("18s");
    await page.screenshot({ path: test.info().outputPath("mini-inspector.png") });
    await page.getByTestId("session-history-participant").click();
    const history = page.getByTestId("session-history-page");
    await expect(history.locator("article")).toHaveCount(7);
    const sendRow = history.locator('[data-record-id="tool:send"]');
    const sendSummary = sendRow.locator(":scope > details > summary");
    await expect(sendSummary).toContainText(
      `${chatSmokeWorkspaceChat.title} · Hello there`
    );
    await expect(sendSummary).not.toContainText(chatSmokeWorkspaceChat.id);
    await expect(sendSummary).not.toContainText("Message sent");
    expect((await sendSummary.textContent())!.split("Hello there")).toHaveLength(2);
    await history.locator('[data-span-id="tool:send"]').focus();
    await expect(inspector).toContainText(
      `${chatSmokeWorkspaceChat.title} · Hello there`
    );
    expect((await inspector.textContent())!.split("Hello there")).toHaveLength(2);
    await sendSummary.click();
    for (const key of ["content", "result", "input"]) {
      await sendRow
        .locator(`.comma-session-json-node[data-key="${key}"] > summary`)
        .click();
    }
    await expect(sendRow.locator(".comma-session-json")).toContainText(
      chatSmokeWorkspaceChat.id
    );
    await sendSummary.click();
    await expect(history.locator('[data-record-id="tool:pending"] time')).toHaveText(
      previewTime!
    );
    const context = history.locator('[data-span-id="record:3"]');
    const input = history.locator('[data-span-id="record:4"]');
    await expect(context).toHaveAttribute("data-lane", "0");
    await expect(input).toHaveAttribute("data-lane", "0");
    expect(
      await context.evaluate((el) => getComputedStyle(el, "::before").backgroundColor)
    ).not.toBe(
      await input.evaluate((el) => getComputedStyle(el, "::before").backgroundColor)
    );
    const pending = history.locator('[data-span-id="tool:pending"]');
    await expect(pending).toHaveAttribute("data-display-shape", "open");
    await expect(pending).toHaveAttribute("aria-label", /End time unknown/);
    expect(
      await pending.evaluate((el) => getComputedStyle(el, "::before").clipPath)
    ).toContain("polygon");
    await pending.click();
    await expect(history.locator('[data-record-id="tool:pending"]')).toHaveAttribute(
      "data-selected",
      "true"
    );
    for (const box of await history.locator("[data-span-id]").evaluateAll((elements) =>
      elements.map((el) => ({
        width: el.getBoundingClientRect().width,
        height: el.getBoundingClientRect().height,
      }))
    )) {
      expect(box.width).toBeGreaterThanOrEqual(4);
      expect(box.height).toBeGreaterThanOrEqual(22);
    }
    await expect(
      history.locator('[data-span-id="record:2"] [data-phase="ttft"]')
    ).toHaveCount(0);
    // These tools are 10 ms apart; minimum pixel widths must not imply parallelism.
    await expect(history.locator('[data-span-id="tool:send"]')).toHaveAttribute(
      "data-track",
      (await pending.getAttribute("data-track"))!
    );
    const idle = history.getByTestId("session-timeline-idle");
    await expect(idle).toHaveCount(1);
    await expect(idle).toHaveAttribute("data-duration-ms", "7199000");
    const divider = history.getByTestId("session-timeline-idle-divider");
    await expect(divider).toHaveCount(1);
    await expect(divider.locator("svg")).toHaveCount(0);
    expect((await idle.boundingBox())!.height).toBe(16);
    expect((await idle.boundingBox())!.y).toBe((await divider.boundingBox())!.y);
    const oldModel = await history.locator('[data-span-id="record:2"]').boundingBox();
    const nextInput = await history.locator('[data-span-id="record:4"]').boundingBox();
    expect(Math.abs(oldModel!.x + oldModel!.width - nextInput!.x)).toBeLessThan(1);
    const highlighted = history.getByTestId("session-timeline-idle-range");
    await expect(highlighted).toHaveCount(0);
    await idle.hover();
    await expect(page.getByRole("tooltip")).toContainText(
      "Collapsed idle time: 1 hr 59 min 59 sec"
    );
    await expect(highlighted).toHaveCount(1);
    await expect(highlighted).toHaveAttribute("data-start-ms", String(epoch + 1000));
    await expect(highlighted).toHaveAttribute("data-end-ms", String(epoch + 7_200_000));
    expect(Math.abs((await highlighted.boundingBox())!.x - nextInput!.x)).toBeLessThan(
      1
    );
    await idle.focus();
    await expect(page.getByRole("tooltip")).toBeVisible();
    const track = await history.getByTestId("session-timeline-track").boundingBox();
    const model = history.locator('[data-span-id="record:5"]');
    await expect(model).toHaveAttribute("data-start-ms", String(epoch + 7_201_000));
    await expect(model).toHaveAttribute("data-end-ms", String(epoch + 7_219_000));
    expect((await model.boundingBox())!.width / track!.width).toBeGreaterThan(0.7);
    await model.click();
    await expect(highlighted).toHaveCount(0);
    await expect(history.locator('[data-record-id="5"]')).toHaveAttribute(
      "data-selected",
      "true"
    );
    await page.mouse.move(track!.x + track!.width * 0.5, track!.y + 2);
    await page.mouse.down();
    await page.mouse.move(track!.x + track!.width * 0.9, track!.y + 2, { steps: 4 });
    await page.mouse.up();
    await expect(history.locator('[data-record-id="1"]')).toHaveAttribute(
      "data-timeline-outside",
      "true"
    );
    await expect(history.locator('[data-record-id="5"]')).toHaveAttribute(
      "data-timeline-outside",
      "false"
    );
    const originalStart = Number(
      await history.getByTestId("session-timeline-track").getAttribute("data-start-ms")
    );
    const geometry = async () => ({
      height: (await history.getByTestId("session-timeline-track").boundingBox())!
        .height,
      modelTop: await model.evaluate((el) => (el as HTMLElement).style.top),
      ledgerTop: (await history
        .getByRole("region", { name: "Execution records" })
        .boundingBox())!.y,
    });
    const originalGeometry = await geometry();
    await history.getByRole("button", { name: "Zoom in", exact: true }).click();
    expect(
      Number(
        await history
          .getByTestId("session-timeline-track")
          .getAttribute("data-start-ms")
      )
    ).toBeGreaterThan(originalStart);
    expect(await geometry()).toEqual(originalGeometry);
    await expect(model).toHaveAttribute("data-start-ms", String(epoch + 7_201_000));
    const zoomSize = () =>
      history
        .getByTestId("session-timeline-track")
        .evaluate(
          (el) =>
            Number(el.getAttribute("data-axis-to")) -
            Number(el.getAttribute("data-axis-from"))
        );
    const selectedSize = await zoomSize();
    await history.getByRole("button", { name: "Zoom out", exact: true }).click();
    expect(await zoomSize()).toBeCloseTo(selectedSize * 2, 6);
    expect(await geometry()).toEqual(originalGeometry);
    await history.getByRole("button", { name: "Show all", exact: true }).click();
    await expect(history.getByTestId("session-timeline-track")).toHaveAttribute(
      "data-start-ms",
      String(originalStart)
    );
    const wheelTrack = history.getByTestId("session-timeline-track");
    const wheelBounds = (await wheelTrack.boundingBox())!;
    const readWindow = () =>
      wheelTrack.evaluate((el) => ({
        from: Number(el.getAttribute("data-axis-from")),
        to: Number(el.getAttribute("data-axis-to")),
      }));
    await page.mouse.move(wheelBounds.x + wheelBounds.width * 0.3, wheelBounds.y + 10);
    await page.mouse.wheel(0, -300);
    await expect.poll(async () => (await readWindow()).from).toBeGreaterThan(0);
    const zoomed = await readWindow();
    expect(await geometry()).toEqual(originalGeometry);
    expect(zoomed.from + 0.3 * (zoomed.to - zoomed.from)).toBeCloseTo(0.3, 2);
    await page.mouse.wheel(150, 0);
    await expect
      .poll(async () => (await readWindow()).from)
      .toBeGreaterThan(zoomed.from);
    const panned = await readWindow();
    expect(await geometry()).toEqual(originalGeometry);
    expect(panned.to - panned.from).toBeCloseTo(zoomed.to - zoomed.from, 6);
    await history.getByRole("button", { name: "Show all", exact: true }).click();
  } finally {
    await stub.close();
  }
});

test("Session summaries distinguish async outcomes and disclose complete debug only on expansion", async ({
  page,
}) => {
  const records = [
    {
      id: "1",
      kind: "assistant",
      content: {
        content: "Looking up the session",
        model: "test-model",
        input_tokens: 12000,
        output_tokens: 600,
        cache_read_input_tokens: 9000,
        cache_write_input_tokens: 1000,
        tool_calls: [
          {
            id: "call-test",
            name: "call",
            args: { tool: "memory.search", params: { query: "Muse Spark" } },
          },
        ],
      },
    },
    {
      id: "2",
      kind: "tool",
      content: {
        tool_call_id: "call-test",
        content: '{"status":"running","tool_name":"memory.search"}',
      },
    },
    {
      id: "3",
      kind: "runtime",
      content: {
        content: JSON.stringify({
          type: "tool_call_completed",
          tool_name: "memory.search",
          result: {
            status: "completed",
            duration_ms: 1200,
            content: '{"matches":[]}',
            error_message: null,
          },
        }),
      },
    },
    {
      id: "4",
      kind: "runtime.event",
      content: {
        event: {
          type: "error",
          message: "Permission denied",
          diagnostic: "debug-only-marker",
          long_value: "Full unwrapped JSON content. ".repeat(40),
          extra: null,
        },
      },
    },
    {
      id: "5",
      kind: "tool",
      content: {
        tool_name: "fs.read_file",
        input: { environment: "dev-linux", path: "/workspace/Comma/README.md" },
        status: "completed",
        content: "Read complete",
      },
    },
    {
      id: "6",
      kind: "runtime",
      content: {
        type: "migration_notice_delta",
        summary: "Tool contract updated",
        content: "Complete migration instructions",
      },
    },
    {
      id: "7",
      kind: "runtime",
      content: {
        type: "future_runtime_event",
        content: "Runtime event retained",
        duration_ms: 0,
      },
    },
  ].map((record, index) => ({
    ...record,
    created_at: 1788564963000 + index * 1000,
    timestamp_ms: 1788564963000 + index * 1000,
    execution:
      index === 0
        ? {
            id: "model-1",
            lane: "model",
            started_at_ms: 1788564962100,
            first_token_at_ms: 1788564962300,
            observed_at_ms: 1788564963000,
            completed_at_ms: 1788564963000,
            duration_ms: 900,
          }
        : index === 1 || index === 2
          ? {
              id: "call-test",
              lane: "tool",
              started_at_ms: 1788564963800,
              observed_at_ms: 1788564963000 + index * 1000,
              completed_at_ms: index === 1 ? null : 1788564965000,
              duration_ms: index === 1 ? 200 : 1200,
            }
          : index === 4
            ? {
                id: "parallel",
                lane: "tool",
                started_at_ms: 1788564963900,
                observed_at_ms: 1788564964800,
                completed_at_ms: 1788564964800,
                duration_ms: 900,
              }
            : null,
  }));
  const stub = await startChatSmokeStub({
    sessionEmail: "summary@comma.local",
    sessionHistory: (url) => ({
      body: {
        conversation_id: chatSmokeWorkspaceChat.id,
        participant_id: "ptp-router-smoke",
        records: records.slice(-Number(url.searchParams.get("limit"))),
        has_more: false,
        next_before: null,
      },
    }),
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "summary@comma.local",
      token: "comma_sess_summary",
    });
    await page.goto("/");
    const participant = page.getByTestId("session-history-participant");
    await page.getByRole("textbox", { name: "AI prompt" }).click();
    await participant.hover();
    const preview = page.getByTestId("session-history-preview");
    await expect(preview).toContainText("Tool contract updated");
    await expect(preview).toContainText("Runtime event retained");
    await expect(preview).not.toContainText("debug-only-marker");
    await participant.click();
    const history = page.getByTestId("session-history-page");
    await expect(history.locator("article")).toHaveCount(6);
    await expect
      .poll(() =>
        history
          .locator("article")
          .evaluateAll((rows) => rows.map((row) => row.getAttribute("data-record-id")))
      )
      .toEqual(["1", "tool:call-test", "tool:parallel", "4", "6", "7"]);
    await expect(history).toContainText("0 matches");
    await expect(history).toContainText("Permission denied");
    await expect(history.locator('[data-record-id="1"]')).not.toContainText(
      "Muse Spark"
    );
    await expect(history.locator('[data-record-id="2"]')).toHaveCount(0);
    await expect(history.locator('[data-record-id="tool:call-test"]')).toHaveAttribute(
      "data-kind",
      "success"
    );
    await expect(history.locator('[data-record-id="tool:call-test"]')).toContainText(
      "1.2s"
    );
    const timedRow = history.locator('[data-record-id="tool:call-test"]');
    await expect(timedRow.locator("time")).toHaveText(
      await page.evaluate(() =>
        new Date(1788564963800).toLocaleTimeString("en", { hour12: false })
      )
    );
    await expect(
      history.locator('[data-record-id="1"] .comma-session-duration')
    ).toHaveText("900ms");
    const zeroDuration = history.locator('[data-record-id="7"]');
    await expect(zeroDuration.locator(".comma-session-duration")).toHaveCount(0);
    await expect(zeroDuration.locator("time")).toHaveText(/\d{2}:\d{2}:\d{2}/);
    const error = history.locator('[data-record-id="4"]');
    await expect(error).toHaveAttribute("data-kind", "error");
    const timeline = history.getByRole("region", { name: "Timeline", exact: true });
    await expect(timeline.locator(".comma-session-overview-labels")).toHaveText(
      "InputModelTools"
    );
    await expect(timeline.locator('[data-lane="3"]')).toHaveCount(0);
    await expect(timeline.locator('[data-span-id="record:4"]')).toHaveAttribute(
      "data-lane",
      "0"
    );
    await expect(timeline.locator('[data-span-id="record:7"]')).toHaveAttribute(
      "data-lane",
      "0"
    );
    await expect(timeline.locator('[data-span-id="record:2"]')).toHaveCount(0);
    await expect(timeline.locator('[data-span-id="record:3"]')).toHaveCount(0);
    const request = timeline.locator('[data-span-id="record:1"]');
    await expect(request).toHaveAttribute("data-kind", "model");
    await expect(request).toHaveAttribute("aria-label", /Model request/);
    await expect(request).toHaveAttribute("aria-label", /TTFT 200 ms/);
    await expect(request.locator('[data-phase="start"]')).toHaveCount(1);
    await expect(request.locator('[data-phase="ttft"]')).toHaveAttribute(
      "data-time-ms",
      "1788564962300"
    );
    await expect(request.locator('[data-phase="end"]')).toHaveCount(1);
    await request.hover();
    const inspector = page.getByTestId("session-timeline-inspector");
    await expect(inspector).toContainText("TTFT");
    await expect(inspector).toContainText("200ms");
    await expect(inspector).toContainText("75%");
    await expect(inspector).toContainText("12,000");
    await expect(inspector).toContainText("600");
    await expect(inspector).toContainText("9,000");
    await expect(inspector.locator("time")).toHaveCount(2);
    await expect(inspector.locator("time").first()).toHaveAttribute(
      "dateTime",
      "2026-09-04T23:36:02.100Z"
    );
    await page.screenshot({ path: test.info().outputPath("model-inspector.png") });
    await request.focus();
    await page.keyboard.press("Escape");
    await expect(inspector).toHaveCount(0);
    await expect(history.locator('[data-record-id="1"]')).toHaveAttribute(
      "data-kind",
      "model"
    );
    await expect(history.locator('[data-record-id="1"] summary')).toContainText(
      "Model request"
    );
    await expect(timeline.locator('[data-span-id="record:6"]')).toHaveAttribute(
      "data-lane",
      "0"
    );
    await expect(history.locator('[data-record-id="6"]')).toHaveAttribute(
      "data-kind",
      "migration"
    );
    const tool = timeline.locator('[data-span-id="tool:call-test"]');
    const parallel = timeline.locator('[data-span-id="tool:parallel"]');
    const readRow = history.locator('[data-record-id="tool:parallel"]');
    await expect(readRow.locator(".comma-session-kind")).toHaveText("Read file");
    await expect(readRow.locator(".comma-session-summary")).toHaveText(
      "dev-linux · /workspace/Comma/README.md"
    );
    await expect(readRow.locator(".comma-session-operation-status")).toHaveText(
      "Completed"
    );
    await expect(history.locator(".comma-session-row-index")).toHaveCount(0);
    await expect(history.locator("article > details > summary svg")).toHaveCount(0);
    await expect(history.locator(".comma-session-ledger-heading")).not.toContainText(
      "#"
    );
    await expect(
      history.locator('[data-record-id="1"] .comma-session-kind')
    ).toHaveText("Model request");
    await expect(
      history.locator('[data-record-id="1"] .comma-session-summary')
    ).toHaveText("");
    const requestMetrics = history.locator(
      '[data-record-id="1"] [data-testid="session-model-metrics"]'
    );
    await expect(requestMetrics).toContainText("TTFT 200ms");
    await expect(requestMetrics).toContainText("Input tokens 12K");
    await expect(requestMetrics).toContainText("Output tokens 600");
    await expect(requestMetrics).toContainText("Cache hit 75%");
    await expect(
      history.locator('[data-record-id="1"] .comma-session-row-content')
    ).not.toContainText("Muse Spark");
    await expect(
      history.locator('[data-record-id="tool:call-test"] .comma-session-kind')
    ).toHaveText("Search");
    await expect(
      history.locator('[data-record-id="tool:call-test"] .comma-session-summary')
    ).toHaveText("Muse Spark");
    await expect(tool).toHaveAttribute("data-start-ms", "1788564963800");
    await expect(tool).toHaveAttribute("data-end-ms", "1788564965000");
    expect(await tool.getAttribute("data-track")).not.toBe(
      await parallel.getAttribute("data-track")
    );
    await tool.click();
    await expect(history.locator('[data-record-id="tool:call-test"]')).toHaveAttribute(
      "data-selected",
      "true"
    );
    await expect(history.locator('[data-record-id="tool:call-test"]')).toBeInViewport();
    await expect(timeline).toContainText("Real time");
    await expect(timeline.locator('[data-span-id="record:6"]')).toHaveAttribute(
      "aria-label",
      /Event timestamp · does not indicate execution duration/
    );
    await expect(timeline).not.toContainText("model records lack execution intervals");
    const track = await history.getByTestId("session-timeline-track").boundingBox();
    await page.mouse.move(track!.x + track!.width * 0.05, track!.y + 2);
    await page.mouse.down();
    await page.mouse.move(track!.x + track!.width * 0.4, track!.y + 2, { steps: 4 });
    await page.mouse.up();
    await expect(error).toHaveAttribute("data-timeline-outside", "true");
    await expect(history.locator('[data-record-id="1"]')).toHaveAttribute(
      "data-timeline-outside",
      "false"
    );
    await timeline.getByRole("button", { name: "Clear focus" }).click();
    await expect(error).toHaveAttribute("data-timeline-outside", "false");
    await expect(history.getByTestId("session-json")).toHaveCount(0);
    const groupedTool = history.locator('[data-record-id="tool:call-test"]');
    await expect(groupedTool).toHaveCount(1);
    const toolDisclosure = groupedTool.locator(":scope > details > summary");
    await toolDisclosure.click();
    await expect(groupedTool.locator(".comma-session-debug-stage")).toHaveCount(3);
    await expect(groupedTool.getByTestId("session-json")).toHaveCount(0);
    for (const record of records.slice(0, 3)) {
      const stage = groupedTool.locator(`[data-source-id="${record.id}"]`);
      await stage.locator(":scope > summary").click();
      const tree = stage.getByTestId("session-json");
      await expect(tree).toBeVisible();
      await expandJson(tree);
      expect(JSON.parse((await tree.textContent())!)).toEqual(record);
    }
    await expect(groupedTool).toContainText("Muse Spark");
    await toolDisclosure.click();
    const disclosure = error.locator(":scope > details > summary");
    await disclosure.focus();
    await page.keyboard.press("Enter");
    const debug = error.getByTestId("session-json");
    await expect(debug).toBeVisible();
    await expandJson(debug);
    expect(JSON.parse((await debug.textContent())!)).toEqual(records[3]);
    const jsonViewport = error.getByRole("region", { name: "JSON", exact: true });
    expect(await debug.evaluate((el) => getComputedStyle(el).whiteSpace)).toBe("pre");
    expect(await jsonViewport.evaluate((el) => el.scrollWidth > el.clientWidth)).toBe(
      true
    );
    await jsonViewport.hover();
    await page.mouse.wheel(600, 0);
    await expect
      .poll(() => jsonViewport.evaluate((el) => el.scrollLeft))
      .toBeGreaterThan(0);
    await disclosure.click();
    await expect(debug).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("loading older records preserves the reading anchor when execution time places them after it", async ({
  page,
}) => {
  const epoch = 1_788_564_963_000;
  const stub = await startChatSmokeStub({
    sessionEmail: "history-anchor@comma.local",
    sessionHistory(url) {
      const limit = Number(url.searchParams.get("limit"));
      const before = Number(url.searchParams.get("before") || 121);
      const start = Math.max(1, before - limit);
      return {
        body: {
          conversation_id: chatSmokeWorkspaceChat.id,
          participant_id: "ptp-router-smoke",
          records: Array.from({ length: before - start }, (_, index) => {
            const id = start + index;
            return id === 110
              ? {
                  id: String(id),
                  kind: "session.async_tool_call_completed",
                  timestamp_ms: epoch + 110_000,
                  content: {
                    tool_call_id: "long-read",
                    tool_name: "read",
                    content: "Long-running read completed",
                  },
                  execution: {
                    id: "long-read",
                    lane: "tool",
                    started_at_ms: epoch,
                    observed_at_ms: epoch + 110_000,
                    completed_at_ms: epoch + 110_000,
                    duration_ms: 110_000,
                  },
                }
              : {
                  id: String(id),
                  kind: "user",
                  timestamp_ms: epoch + id * 1000,
                  content: { content: `Timed input ${id}` },
                };
          }),
          has_more: start > 1,
          next_before: start > 1 ? String(start) : null,
        },
      };
    },
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "history-anchor@comma.local",
      token: "comma_sess_history_anchor",
    });
    await page.goto("/");
    await page.getByTestId("session-history-participant").click();
    const history = page.getByTestId("session-history-page");
    const viewport = history.getByRole("region", {
      name: "Execution records",
      exact: true,
    });
    await expect(history.locator("article")).toHaveCount(50);
    const anchor = history.locator('[data-record-id="tool:long-read"]');
    const offset = () =>
      anchor.evaluate(
        (row) =>
          row.getBoundingClientRect().top -
          row.closest('[role="region"]')!.getBoundingClientRect().top
      );
    // Scrolling up to the oldest record loaded asks for the page before it;
    // the offset is read in the same task as the scroll, before that request.
    const beforeOffset = await viewport.evaluate((el) => {
      el.scrollTop = 0;
      const row = el.querySelector('[data-record-id="tool:long-read"]')!;
      return row.getBoundingClientRect().top - el.getBoundingClientRect().top;
    });
    // Every older page lands below the anchor (execution time places it
    // first), so the top stays in reach and paging runs to the start of the
    // session while the anchor holds its place.
    await expect(history.locator("article")).toHaveCount(120);
    await expect(
      history.getByText("Beginning of session", { exact: true })
    ).toBeVisible();
    await expect(history.locator("article").first()).toHaveAttribute(
      "data-record-id",
      "tool:long-read"
    );
    await expect(history.locator("article").nth(1)).toHaveAttribute(
      "data-record-id",
      "1"
    );
    await expect
      .poll(async () => Math.abs((await offset()) - beforeOffset))
      .toBeLessThan(3);
  } finally {
    await stub.close();
  }
});

async function expandJson(tree: import("@playwright/test").Locator) {
  const nodes = tree.locator("details");
  for (;;) {
    const index = await nodes.evaluateAll((elements) =>
      elements.findIndex((element) => !element.hasAttribute("open"))
    );
    if (index === -1) return;
    const node = nodes.nth(index);
    await node.locator(":scope > summary").click();
    await expect(node.locator(":scope > .comma-session-json-children")).toBeVisible();
  }
}

test("Participant opens a right-sidebar Session tab while retaining the Conversation and prepending history without jumping", async ({
  page,
}, testInfo) => {
  const requests: URL[] = [];
  let failOlder = true;
  const stub = await startChatSmokeStub({
    sessionEmail: "history@comma.local",
    sessionHistory(url) {
      requests.push(url);
      const limit = Number(url.searchParams.get("limit"));
      const before = Number(url.searchParams.get("before") || 121);
      if (before < 121 && failOlder) {
        failOlder = false;
        return { status: 503, body: { error: "unavailable" } };
      }
      const start = Math.max(1, before - limit);
      return {
        body: {
          conversation_id: chatSmokeWorkspaceChat.id,
          participant_id: "ptp-router-smoke",
          records: Array.from({ length: before - start }, (_, index) => ({
            id: String(start + index),
            kind: index % 2 ? "assistant" : "tool",
            content: {
              content: `Execution record ${start + index}\n${"Session execution details. ".repeat(16)}`,
            },
          })),
          has_more: start > 1,
          next_before: start > 1 ? String(start) : null,
        },
      };
    },
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "history@comma.local",
      token: "comma_sess_history",
    });
    await page.goto("/");
    const participant = page.getByTestId("session-history-participant");
    await expect(participant).toBeVisible();
    expect(requests).toHaveLength(0);
    const composer = page.getByRole("textbox", { name: "AI prompt" });
    await composer.fill("Keep this conversation draft");
    await composer.click();
    await participant.hover();
    const preview = page.getByTestId("session-history-preview");
    await expect(preview).toContainText("Execution record 120");
    await expect(preview.locator("li")).toHaveCount(3);
    await expect(preview.getByTestId("session-history-mini-timeline")).toBeVisible();
    await expect(
      preview.getByTestId("session-history-mini-timeline").locator("[data-span-id]")
    ).toHaveCount(0);
    expect(requests[0]!.searchParams.get("limit")).toBe("3");
    await participant.click();
    const sidebar = page.getByTestId("chat-sidebar");
    const historyTab = sidebar.getByRole("tab", {
      name: "Session history · Comma",
      exact: true,
    });
    await expect(historyTab).toHaveAttribute("aria-selected", "true");
    await expect(composer).toBeVisible();
    await expect(composer).toHaveText("Keep this conversation draft");
    expect((await sidebar.boundingBox())!.x).toBeGreaterThan(
      (await composer.boundingBox())!.x
    );
    await participant.click();
    await expect(historyTab).toHaveCount(1);
    const history = sidebar.getByTestId("session-history-page");
    const viewport = history.getByRole("region", { name: "Execution records" });
    await expect(history.locator("article")).toHaveCount(50);
    const unknownRequest = history.locator('[data-lane="1"]').first();
    // This fixture has no timestamps, so it does not invent timeline bars.
    await expect(unknownRequest).toHaveCount(0);
    await expect(
      history.getByRole("button", { name: "50 records without time", exact: true })
    ).toBeVisible();
    await expect(history).toContainText(
      "25 model records lack execution intervals; gaps do not imply idle time"
    );
    await expect(history.locator('[data-record-id="120"]')).toBeInViewport();
    await page.screenshot({ path: testInfo.outputPath("session-history.png") });
    const beforeScrollRequests = requests.length;
    // Scrolling up to the oldest record loaded asks for the page before it:
    // exactly one request, which this stub fails.
    await viewport.evaluate((element) => {
      element.scrollTop = 0;
    });
    await expect(history.getByRole("alert")).toContainText("Could not load");
    expect(requests).toHaveLength(beforeScrollRequests + 1);
    await expect(history.locator("article")).toHaveCount(50);
    // The failed page leaves the rows where they were, with Retry above them;
    // the reader brings it into view before pressing it.
    const retry = history.getByRole("button", { name: "Retry" });
    await retry.scrollIntoViewIfNeeded();
    const first = history.locator('[data-record-id="71"]');
    const top = (await first.boundingBox())!.y;
    await retry.click();
    await expect(history.locator("article")).toHaveCount(100);
    await expect
      .poll(async () => Math.abs((await first.boundingBox())!.y - top))
      .toBeLessThan(3);
    await viewport.evaluate((element) => {
      element.scrollTop = 0;
    });
    await expect(history.locator("article")).toHaveCount(120);
    const ids = await history
      .locator("article")
      .evaluateAll((elements) =>
        elements.map((element) => Number(element.getAttribute("data-record-id")))
      );
    expect(ids).toEqual(Array.from({ length: 120 }, (_, index) => index + 1));
    const requestCount = requests.length;
    await sidebar.getByRole("button", { name: "New tab", exact: true }).click();
    await expect(historyTab).toHaveAttribute("aria-selected", "false");
    await expect(history).toBeHidden();
    await historyTab.click();
    await expect(history.locator("article")).toHaveCount(120);
    expect(requests).toHaveLength(requestCount);
    await sidebar.getByRole("tab", { name: "New tab", exact: true }).hover();
    await sidebar.getByRole("button", { name: "Close New tab", exact: true }).click();
    await expect(historyTab).toHaveAttribute("aria-selected", "true");
    await expect(history).toBeVisible();
    await sidebar.getByRole("button", { name: "New tab", exact: true }).click();
    await historyTab.click();
    await sidebar
      .getByRole("button", { name: "Close Session history · Comma", exact: true })
      .click();
    await expect(history).toHaveCount(0);
    await expect(participant).toBeVisible();
    await expect(composer).toHaveText("Keep this conversation draft");
  } finally {
    await stub.close();
  }
});

test("Session pages through 203 mixed records with stable anchors and grouped tools", async ({
  page,
}, testInfo) => {
  test.setTimeout(60_000);
  const requests: URL[] = [];
  const records = sessionStressRecords(21).slice(0, 203);
  const stub = await startSessionStressStub(records, requests);
  const pageDurations: number[] = [];
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "session-stress@comma.local",
      token: "comma_sess_stress",
    });
    await page.goto("/");
    await page.getByTestId("session-history-participant").click();
    const history = page.getByTestId("session-history-page");
    const viewport = history.getByRole("region", { name: "Execution records" });
    for (let loaded = 50; loaded <= 203; loaded = Math.min(203, loaded + 50)) {
      await expect(
        history.getByText(`${loaded} loaded records`, { exact: true })
      ).toBeVisible();
      expect(requests.at(-1)!.searchParams.get("limit")).toBe("50");
      if (loaded === 50) {
        await history.locator('[data-span-id="tool:stress-18-a"]').click();
        const row = (await history
          .locator('[data-record-id="tool:stress-18-a"]')
          .boundingBox())!;
        const visible = (await viewport.boundingBox())!;
        expect(
          Math.abs(row.y + row.height / 2 - visible.y - visible.height / 2)
        ).toBeLessThan(2);
        expect(requests).toHaveLength(1);
      }
      if (loaded === 203) break;
      // Choose a stable mid-page entry so adding a tool's older call phase cannot
      // legitimately move this anchor to a different position in the ledger.
      const anchorId = await history
        .locator("article")
        .nth(10)
        .getAttribute("data-record-id");
      const anchor = history.locator(`[data-record-id="${anchorId}"]`);
      if (loaded === 150) {
        // The browser reports a scroll one frame after it happens, and the live
        // clock re-renders the ledger in its own timer callback, before that
        // frame. A tick between the two must keep the new position instead of
        // restoring the anchor read at the previous one.
        const articles = await history.locator("article").count();
        const at = Date.now();
        await page.clock.install({ time: at });
        await page.clock.pauseAt(at + 1000);
        stub.pushHistoryFrame([sessionStressLiveRecord()]);
        await expect(history.locator("article")).toHaveCount(articles + 1);
        const liveDuration = history.locator(
          '[data-record-id="tool:stress-live"] .comma-session-duration'
        );
        const shown = await liveDuration.textContent();
        await expect
          .poll(async () => {
            await page.clock.runFor(100);
            return liveDuration.textContent();
          })
          .not.toBe(shown);
        // Mid-ledger, well clear of the top, where reaching the oldest record
        // would also ask for the page before it.
        const target = await viewport.evaluate((element) => {
          const middle = Math.round((element.scrollHeight - element.clientHeight) / 2);
          setTimeout(() => {
            element.scrollTop = middle;
          }, 0);
          return middle;
        });
        await page.clock.runFor(100);
        expect(await viewport.evaluate((element) => element.scrollTop)).toBe(target);
        stub.pushHistoryFrame([]);
        await expect(history.locator("article")).toHaveCount(articles);
        await page.clock.resume();
      }
      // Scrolling up to the oldest record loaded asks for the page before it.
      // The anchor is read in the same task as the scroll, before the page is
      // requested.
      const started = Date.now();
      const before = await viewport.evaluate((element, id) => {
        element.scrollTop = 0;
        return element
          .querySelector(`[data-record-id="${id}"]`)!
          .getBoundingClientRect().top;
      }, anchorId);
      await expect(
        history.getByText(`${Math.min(203, loaded + 50)} loaded records`, {
          exact: true,
        })
      ).toBeVisible();
      pageDurations.push(Date.now() - started);
      if (loaded >= 100)
        await expect
          .poll(async () => Math.abs((await anchor.boundingBox())!.y - before))
          .toBeLessThan(3);
    }
    await expect(history.locator("article")).toHaveCount(165);
    const ids = await history
      .locator("article")
      .evaluateAll((elements) =>
        elements.map((el) => el.getAttribute("data-record-id"))
      );
    expect(new Set(ids).size).toBe(ids.length);
    expect(requests).toHaveLength(5);
    expect(
      requests
        .filter((url) => url.searchParams.has("before"))
        .map((url) => Number(url.searchParams.get("before")))
    ).toEqual(Array.from({ length: 4 }, (_, index) => 154 - index * 50));
    await expect(history.getByTestId("session-json")).toHaveCount(0);
    const track = history.getByTestId("session-timeline-track");
    const bounds = (await track.boundingBox())!;
    // At this density, zoom separates minimum-width bars that share a real-time row.
    await page.mouse.move(bounds.x, bounds.y + 10);
    await page.mouse.wheel(0, -1500);
    await expect
      .poll(async () => Number(await track.getAttribute("data-axis-to")))
      .toBeLessThan(0.1);
    const tool = history.locator('[data-span-id="tool:stress-0-a"]');
    await tool.click();
    await expect(history.locator('[data-record-id="tool:stress-0-a"]')).toHaveAttribute(
      "data-selected",
      "true"
    );
    await history.getByRole("button", { name: "Show all", exact: true }).click();
    await page.mouse.move(bounds.x + bounds.width * 0.5, bounds.y + 10);
    await page.mouse.wheel(0, -1500);
    await expect
      .poll(async () => Number(await track.getAttribute("data-axis-from")))
      .toBeGreaterThan(0.4);
    await history.locator('[data-span-id="tool:stress-10-a"]').click();
    const centered = history.locator('[data-record-id="tool:stress-10-a"]');
    await expect(centered).toHaveAttribute("data-selected", "true");
    await expect
      .poll(async () => {
        const row = (await centered.boundingBox())!;
        const visible = (await viewport.boundingBox())!;
        return Math.abs(row.y + row.height / 2 - visible.y - visible.height / 2);
      })
      .toBeLessThan(2);
    expect(requests).toHaveLength(5);
    await page.screenshot({ path: testInfo.outputPath("session-203-records.png") });
    await testInfo.attach("pagination-timings", {
      body: JSON.stringify({
        records: 203,
        pages: requests.length,
        renderedEntries: ids.length,
        pageDurationsMs: pageDurations,
      }),
      contentType: "application/json",
    });
  } finally {
    await stub.close();
  }
});

test("Session renders 5003 records after owner pagination without intermediate UI updates", async ({
  page,
}, testInfo) => {
  test.setTimeout(90_000);
  const requests: URL[] = [];
  const records = sessionStressRecords(501).slice(0, 5003);
  const stub = await startSessionStressStub(records, requests);
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "session-stress@comma.local",
      token: "comma_sess_stress",
    });
    await page.goto("/");
    // Exercise the real SharedWorker owner and its 50-record HTTP contract.
    // This cold-render check withholds intermediate projections only. The
    // short pagination test checks live updates, cursors and scroll anchors.
    await page.evaluate(() => {
      const bridge = window.commaNative!.sessionHistory;
      const load = bridge.load.bind(bridge);
      const subscribe = bridge.state.subscribe.bind(bridge.state);
      bridge.state.subscribe = () => () => {};
      bridge.load = async (input) => {
        try {
          let envelope = await load(input);
          for (let pageNumber = 1; envelope.snapshot.hasMore; pageNumber++) {
            if (pageNumber >= 101) throw new Error("History cursor did not terminate");
            envelope = await load({ ...input, mode: "older" });
          }
          if (envelope.snapshot.records.length !== 5003)
            throw new Error("History owner lost records during pagination");
          const ids = envelope.snapshot.records.map((record) => record.id);
          if (new Set(ids).size !== 5003)
            throw new Error("History owner duplicated records during pagination");
          return envelope;
        } finally {
          bridge.load = load;
          bridge.state.subscribe = subscribe;
        }
      };
    });
    await page.getByTestId("session-history-participant").click();
    const history = page.getByTestId("session-history-page");
    const viewport = history.getByRole("region", { name: "Execution records" });
    await expect(history.getByText("5003 loaded records", { exact: true })).toBeVisible(
      { timeout: 30_000 }
    );
    await expect(history.locator("article")).toHaveCount(4005);
    const ids = await history
      .locator("article")
      .evaluateAll((elements) =>
        elements.map((element) => element.getAttribute("data-record-id"))
      );
    expect(new Set(ids).size).toBe(4005);
    expect(requests).toHaveLength(101);
    expect(requests.every((url) => url.searchParams.get("limit") === "50")).toBe(true);
    expect(
      requests.slice(1).map((url) => Number(url.searchParams.get("before")))
    ).toEqual(Array.from({ length: 100 }, (_, index) => 4954 - index * 50));
    await expect(history.getByTestId("session-json")).toHaveCount(0);
    await expect(
      history.getByText("Beginning of session", { exact: true })
    ).toBeVisible();
    const track = history.getByTestId("session-timeline-track");
    const bounds = (await track.boundingBox())!;
    // At this density, zoom separates minimum-width bars that share a real-time row.
    await page.mouse.move(bounds.x, bounds.y + 10);
    await page.mouse.wheel(0, -1500);
    await expect
      .poll(async () => Number(await track.getAttribute("data-axis-to")))
      .toBeLessThan(0.1);
    const tool = history.locator('[data-span-id="tool:stress-0-a"]');
    await tool.click();
    await expect(history.locator('[data-record-id="tool:stress-0-a"]')).toHaveAttribute(
      "data-selected",
      "true"
    );
    await history.getByRole("button", { name: "Show all", exact: true }).click();
    await page.mouse.move(bounds.x + bounds.width * 0.5, bounds.y + 10);
    await page.mouse.wheel(0, -1500);
    await expect
      .poll(async () => Number(await track.getAttribute("data-axis-from")))
      .toBeGreaterThan(0.4);
    await history.locator('[data-span-id="tool:stress-250-a"]').click();
    const centered = history.locator('[data-record-id="tool:stress-250-a"]');
    await expect(centered).toHaveAttribute("data-selected", "true");
    await expect
      .poll(async () => {
        const row = (await centered.boundingBox())!;
        const visible = (await viewport.boundingBox())!;
        return Math.abs(row.y + row.height / 2 - visible.y - visible.height / 2);
      })
      .toBeLessThan(2);
    expect(requests).toHaveLength(101);
    await page.screenshot({ path: testInfo.outputPath("session-5003-records.png") });
  } finally {
    await stub.close();
  }
});

test("Web tabs share the desktop chat runtime and closing one tab preserves the other", async ({
  page,
  context,
}) => {
  const requests: URL[] = [];
  const stub = await startChatSmokeStub({
    sessionEmail: "shared-host@comma.local",
    assistantAttachments: [
      {
        fileName: "diagram.png",
        mimeType: "image/png",
        type: "image",
        path: "/uploads/AAAAAAAAAAAAAAAAAAAAAA-diagram.png",
        size: 4096,
      },
    ],
    sessionHistory(url) {
      requests.push(url);
      return {
        body: {
          conversation_id: chatSmokeWorkspaceChat.id,
          participant_id: "ptp-router-smoke",
          records: [{ id: "1", kind: "tool", content: "Shared execution record" }],
          has_more: false,
          next_before: null,
        },
      };
    },
  });
  const second = await context.newPage();
  const session = {
    apiBaseUrl: stub.baseUrl,
    email: "shared-host@comma.local",
    token: "comma_sess_shared_host",
  };
  try {
    await installBrowserTestSession(page, session);
    await installBrowserTestSession(second, session);
    await page.goto("/");
    await second.goto("/");
    const firstInput = page.getByRole("textbox", { name: "AI prompt" });
    const secondInput = second.getByRole("textbox", { name: "AI prompt" });
    await expect(firstInput).toBeVisible();
    await expect(secondInput).toBeVisible();
    await firstInput.fill("A draft shared by both views");
    await expect(secondInput).toHaveText("A draft shared by both views");
    await page.bringToFront();
    await firstInput.click();
    await page.getByTestId("session-history-participant").hover();
    await expect(page.getByTestId("session-history-preview")).toContainText(
      "Shared execution record"
    );
    await second.bringToFront();
    await secondInput.click();
    await second.getByTestId("session-history-participant").hover();
    await expect(second.getByTestId("session-history-preview")).toContainText(
      "Shared execution record"
    );
    expect(requests).toHaveLength(1);
    await page.close();
    await expect(secondInput).toHaveText("A draft shared by both views");
    await secondInput.press("Enter");
    await expect(
      second.getByText("收到，stub 已生成回复。", { exact: true })
    ).toBeVisible();
    expect(stub.messageBodies).toHaveLength(1);
    await expect(second.getByRole("img", { name: "diagram.png" })).toBeVisible();
    expect(
      await second
        .getByRole("img", { name: "diagram.png" })
        .evaluate((image: HTMLImageElement) => image.complete && image.naturalWidth > 0)
    ).toBe(true);
    await second.reload();
    await expect(
      second.getByText("收到，stub 已生成回复。", { exact: true })
    ).toBeVisible();
    await expect(second.getByRole("img", { name: "diagram.png" })).toBeVisible();
  } finally {
    await second.close();
    await stub.close();
  }
});
