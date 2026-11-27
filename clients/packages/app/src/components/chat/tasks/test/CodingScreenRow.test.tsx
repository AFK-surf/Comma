// The sandbox's screen from the Task panel: the Task's owner alone has the row, which asks the core for the sandbox's
// Device at the press and shows its display in the side panel as a page that only looks; a refusal is said in the
// core's own terms.
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { flush } from "@comma/test-utils/fake-clock";
import { render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, it, vi } from "vitest";
import { useOptionalChatSidebar } from "../../../chat-sidebar/ChatSidebarContext";
import { CodingSandboxRows } from "../CodingSession";

const toasts = vi.hoisted(() => ({ error: vi.fn() }));
vi.mock("@comma/ui/components/toast", async (original) => ({
  ...(await original<typeof import("@comma/ui/components/toast")>()),
  toast: toasts,
}));
vi.mock("../../../chat-sidebar/ChatSidebarContext", async (original) => ({
  ...(await original<typeof import("../../../chat-sidebar/ChatSidebarContext")>()),
  useOptionalChatSidebar: vi.fn(),
}));

const host = { workspaceId: "w1", groupId: "grp_1", conversationId: "cnv_1" };
const openScreen = vi.fn();
const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
const OWNER = "usr_ada";

/** The rows as `viewer` sees them, of a sandbox whose station shows its screen to `owner` (none: it shows none). */
async function rows(
  answer: () => unknown,
  {
    state = "ready",
    owner = OWNER,
    viewer = OWNER,
  }: { state?: string; owner?: string | null; viewer?: string } = {}
) {
  const sent: unknown[] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "session"
        ? { phase: "signed_in", userId: viewer, audience: "comma", sessionId: "s1" }
        : undefined,
    calls: (name, params) => {
      if (name !== "coding.screen") return null;
      sent.push(params);
      return answer();
    },
  });
  render(
    core.wrap(
      <CodingSandboxRows
        coding={{ workspaceId: "w1", taskId: "cnv_1" }}
        place={{ kind: "sandbox", state, ...(owner ? { screenOwner: owner } : {}) }}
      />
    )
  );
  await flush();
  return sent;
}

beforeEach(() => {
  toasts.error.mockClear();
  openScreen.mockClear();
  vi.mocked(useOptionalChatSidebar).mockReturnValue({
    activeHost: host,
    openScreen,
  } as never);
});

it("shows the running sandbox's display in the side panel, as a page of the Task that only looks", async () => {
  const sent = await rows(() => ({ deviceId: "dev-sbx-cnv_1" }));
  await user().click(screen.getByRole("button", { name: "View screen" }));
  await flush();
  expect(sent).toEqual([{ workspaceId: "w1", taskId: "cnv_1" }]);
  expect(openScreen).toHaveBeenCalledWith(host, {
    workspaceId: "w1",
    device: "dev-sbx-cnv_1",
    apps: [],
    target: "display",
    task: "cnv_1",
  });
});

it("says why the screen did not open, each reason in its own words", async () => {
  let code = "forbidden";
  await rows(() => {
    throw Object.assign(new Error(code), { code });
  });
  const press = async () => {
    await user().click(screen.getByRole("button", { name: "View screen" }));
    await flush();
  };
  // (the owner lost their role since; the sandbox's station says no display; it stopped; it did not answer; no network)
  for (const next of [
    "forbidden",
    "sandbox_has_no_screen",
    "sandbox_not_running",
    "sandbox_unreachable",
    "network",
  ]) {
    code = next;
    await press();
  }
  expect(toasts.error.mock.calls.map(([said]) => said)).toEqual([
    "Only the person who started this task can view its screen.",
    "This sandbox has no screen to view.",
    "The screen opens while the session runs.",
    "The sandbox did not answer. Try again in a moment.",
    "The screen could not be opened. Try again.",
  ]);
  expect(openScreen).not.toHaveBeenCalled();
});

const none = () =>
  expect(screen.queryByRole("button", { name: "View screen" })).toBeNull();

it("has no screen row for another member, for a sandbox that shows no screen, while it does not run, or where no side panel can show one", async () => {
  await rows(() => null, { viewer: "usr_bo" });
  none();
  await rows(() => null, { owner: null });
  none();
  await rows(() => null, { state: "stopped" });
  none();
  vi.mocked(useOptionalChatSidebar).mockReturnValue(null as never);
  await rows(() => null);
  none();
});
