// The sandbox's screen in the conversation: the Task's owner alone has it, it holds a view of the sandbox's Device only
// while it is in sight, only looks, and leaves the picture to the side panel while the screen has a tab there.
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { flush } from "@comma/test-utils/fake-clock";
import { cleanup, render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import {
  screenPageId,
  useOptionalChatSidebar,
} from "../../../chat-sidebar/ChatSidebarContext";
import { useDeviceScreenSource } from "../../../remote-screen/useDeviceScreenSource";
import { CodingScreenInline } from "../CodingScreenInline";

const sight = vi.hoisted(() => ({ shown: true }));
const staged = vi.hoisted(() => ({ props: [] as Record<string, unknown>[] }));
vi.mock("../../../chat-sidebar/ChatSidebarContext", async (original) => ({
  ...(await original<typeof import("../../../chat-sidebar/ChatSidebarContext")>()),
  useOptionalChatSidebar: vi.fn(),
}));
vi.mock("../../../remote-screen/ScreenLink", () => ({ useShown: () => sight.shown }));
vi.mock("../../../remote-screen/useDeviceScreenSource", () => ({
  useDeviceScreenSource: vi.fn(() => ({ key: "source" })),
}));
vi.mock("../../../remote-screen/ScreenStreamStage", () => ({
  ScreenStreamStage: (props: Record<string, unknown>) => {
    staged.props.push(props);
    return <div data-testid="stage" />;
  },
}));

const OWNER = "usr_ada";
const DEVICE = "dev-sbx-cnv_1";
const host = { workspaceId: "w1", groupId: "grp_1", conversationId: "cnv_1" };
const openScreen = vi.fn();
const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });

async function inline(viewer = OWNER) {
  const sent: string[] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "session"
        ? { phase: "signed_in", userId: viewer, audience: "comma", sessionId: "s1" }
        : undefined,
    calls: (name) => {
      sent.push(name);
      return null;
    },
  });
  render(
    core.wrap(
      <CodingScreenInline
        coding={{ workspaceId: "w1", taskId: "cnv_1" }}
        device={DEVICE}
        groupId="grp_1"
        owner={OWNER}
      />
    )
  );
  await flush();
  return sent;
}

beforeEach(() => {
  sight.shown = true;
  staged.props = [];
  openScreen.mockClear();
  vi.mocked(useDeviceScreenSource).mockClear();
  vi.mocked(useOptionalChatSidebar).mockReturnValue({
    activeHost: host,
    isOpen: false,
    openScreen,
  } as never);
});
afterEach(cleanup);

it("shows the Task's owner the sandbox's display live, to look at, as a view of the Task", async () => {
  const sent = await inline();
  expect(screen.getByTestId("stage")).toBeTruthy();
  expect(staged.props.at(-1)).toMatchObject({ control: false, target: "display" });
  // Each view it opens says whose sandbox it is, so the core asks the sandbox to show its screen as the view opens and
  // while it is open. The picture asks nothing more by itself.
  expect(vi.mocked(useDeviceScreenSource)).toHaveBeenLastCalledWith(
    "w1",
    DEVICE,
    [],
    undefined,
    "cnv_1"
  );
  expect(sent).not.toContain("coding.screen");

  await user().click(screen.getByRole("button", { name: "Open in side panel" }));
  expect(openScreen).toHaveBeenCalledWith(host, {
    workspaceId: "w1",
    device: DEVICE,
    apps: [],
    target: "display",
    task: "cnv_1",
  });
});

it("shows nothing to another member", async () => {
  await inline("usr_bo");
  expect(screen.queryByTestId("task-screen-inline")).toBeNull();
  expect(vi.mocked(useDeviceScreenSource)).not.toHaveBeenCalled();
});

it("holds no view while it is out of sight", async () => {
  sight.shown = false;
  await inline();
  expect(screen.getByTestId("task-screen-inline")).toBeTruthy();
  expect(screen.queryByTestId("stage")).toBeNull();
});

it("leaves the picture to the side panel while the screen has a tab there", async () => {
  const page = { device: DEVICE, apps: [], target: "display" as const };
  vi.mocked(useOptionalChatSidebar).mockReturnValue({
    activeHost: host,
    isOpen: true,
    activeSession: { screenPages: [{ ...page, id: screenPageId(page) }] },
    openScreen,
  } as never);
  await inline();
  expect(screen.queryByTestId("task-screen-inline")).toBeNull();
});
