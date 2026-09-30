import { render, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createCommaApi, type CommaConversation } from "../../../../api";
import { TaskDetailsPanel } from "../TaskDetailsPanel";
import { TaskDetailsPopover } from "../TaskDetailsPopover";

const GROUP = "grp_panel";

/** The catalog after label A was deleted: only B and C remain. */
const CATALOG = {
  colors: [],
  labels: [
    { color: "blue", description: "", id: "lbl_b", name: "Backend" },
    { color: "purple", description: "", id: "lbl_c", name: "Design" },
  ],
  proposals: [],
};

function stubCatalog(catalog: unknown = CATALOG) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const url = input instanceof Request ? input.url : String(input);
      if (url.endsWith(`/v1/comma/groups/${GROUP}/task-labels`)) {
        return new Response(JSON.stringify(catalog), {
          headers: { "content-type": "application/json" },
          status: 200,
        });
      }
      throw new TypeError(`Unexpected fetch: ${url}`);
    })
  );
}

/** A Task still carrying the deleted label A beside B. */
const conversation = {
  group_id: GROUP,
  id: "cnv_task",
  kind: "agent_task",
  labels: ["lbl_a", "lbl_b"],
  status: "running",
  title: "Labelled task",
} as unknown as CommaConversation;

function renderPanel(onSetLabels: (ids: string[]) => Promise<void>) {
  const api = createCommaApi({ baseUrl: "", token: "" });
  return render(
    <TaskDetailsPanel
      api={api}
      canDone={false}
      conversation={conversation}
      doneState="idle"
      groupId={GROUP}
      onDone={vi.fn()}
      onSetLabels={onSetLabels}
      open
    />
  );
}

describe("TaskDetailsPanel labels", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("opens Tasks filtered by the clicked status, origin, or client platform", async () => {
    const onOpenTasksFilter = vi.fn();
    render(
      <TaskDetailsPanel
        canDone={false}
        conversation={{
          ...conversation,
          status: "completed",
          origin: "comma",
          client_platform: "macos",
        }}
        doneState="idle"
        groupId={GROUP}
        onDone={vi.fn()}
        onOpenTasksFilter={onOpenTasksFilter}
        open
      />
    );
    await userEvent.click(screen.getByRole("button", { name: "Done" }));
    expect(onOpenTasksFilter).toHaveBeenLastCalledWith({ status: "done" });
    await userEvent.click(screen.getByRole("button", { name: "Comma" }));
    expect(onOpenTasksFilter).toHaveBeenLastCalledWith({ platform: "comma" });
    await userEvent.click(screen.getByRole("button", { name: "macOS" }));
    expect(onOpenTasksFilter).toHaveBeenLastCalledWith({ clientPlatform: "macos" });
  });

  it("refreshes a visible Task's catalog when server-assigned label IDs change", async () => {
    let labels = CATALOG.labels;
    const fetchCatalog = vi.fn(
      async () =>
        new Response(JSON.stringify({ ...CATALOG, labels }), {
          headers: { "content-type": "application/json" },
        })
    );
    vi.stubGlobal("fetch", fetchCatalog);
    const api = createCommaApi({ baseUrl: "", token: "" });
    const panel = (ids: string[]) => (
      <TaskDetailsPanel
        api={api}
        canDone={false}
        conversation={{ ...conversation, labels: ids }}
        doneState="idle"
        groupId={GROUP}
        onDone={vi.fn()}
        open
      />
    );
    const { rerender } = render(panel(["lbl_b"]));
    expect(await screen.findByText("Backend")).toBeVisible();
    expect(fetchCatalog).toHaveBeenCalledTimes(1);
    labels = [
      ...labels,
      { id: "lbl_new", name: "Release", color: "orange", description: "Release work" },
    ];
    rerender(panel(["lbl_b", "lbl_new"]));
    expect(await screen.findByText("Release")).toBeVisible();
    expect(fetchCatalog).toHaveBeenCalledTimes(2);
    rerender(panel(["lbl_b", "lbl_new"]));
    expect(fetchCatalog).toHaveBeenCalledTimes(2);
  });

  it("shows a new-label request for this Task even before its labels are created", async () => {
    stubCatalog({
      ...CATALOG,
      proposals: [
        {
          id: "prp_new",
          op: "create",
          status: "pending",
          created_at: 1,
          payload: {
            conversation_id: conversation.id,
            labels: [{ name: "Release", color: "orange", description: "Release work" }],
          },
        },
      ],
    });
    renderPanel(vi.fn(async () => undefined));
    expect(
      await screen.findByText(
        "A label request needs your attention in the original chat or Settings."
      )
    ).toBeVisible();
  });

  it("keeps folded properties open while adding a label", async () => {
    stubCatalog();
    const setLabels = vi.fn(async () => undefined);
    render(
      <TaskDetailsPopover
        api={createCommaApi({ baseUrl: "", token: "" })}
        canDone={false}
        conversation={conversation}
        doneState="idle"
        groupId={GROUP}
        onDone={vi.fn()}
        onSetLabels={setLabels}
      />
    );
    await userEvent.click(screen.getByTestId("task-panel-toggle"));
    await userEvent.click(await screen.findByRole("button", { name: "Add label" }));
    const search = await screen.findByPlaceholderText("Change or add labels…");
    await waitFor(() => expect(search).toHaveFocus());
    await userEvent.type(search, "des");
    await userEvent.click(screen.getByRole("menuitemcheckbox", { name: "Design" }));
    await waitFor(() => expect(setLabels).toHaveBeenCalledWith(["lbl_b", "lbl_c"]));
    expect(screen.getByTestId("task-panel-popover")).toBeVisible();
    await userEvent.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByTestId("task-label-picker")).toBeNull());
    expect(screen.getByTestId("task-panel-popover")).toBeVisible();
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Add label" })).toHaveFocus()
    );
    await userEvent.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByTestId("task-panel-popover")).toBeNull());
  });

  it("adds a label without carrying a deleted label's id into the write", async () => {
    stubCatalog();
    const setLabels = vi.fn(async () => undefined);
    renderPanel(setLabels);

    expect(await screen.findByText("Backend")).toBeInTheDocument();
    expect(screen.queryByText("lbl_a")).toBeNull();

    await userEvent.click(screen.getByRole("button", { name: "Add label" }));
    await userEvent.click(
      await screen.findByRole("menuitemcheckbox", { name: "Design" })
    );

    await waitFor(() => expect(setLabels).toHaveBeenCalledWith(["lbl_b", "lbl_c"]));
  });

  it("removes a label from the picker a chip opens, without a deleted label's id", async () => {
    stubCatalog();
    const setLabels = vi.fn(async () => undefined);
    renderPanel(setLabels);

    await userEvent.click(await screen.findByRole("button", { name: "Backend" }));
    const picker = await screen.findByTestId("task-label-picker");
    const backend = await screen.findByRole("menuitemcheckbox", { name: "Backend" });
    expect(backend).toHaveAttribute("aria-checked", "true");
    await userEvent.click(backend);

    await waitFor(() => expect(setLabels).toHaveBeenCalledWith([]));
    expect(picker).toBeVisible();
  });

  it("narrows the picker by search", async () => {
    stubCatalog();
    renderPanel(vi.fn(async () => undefined));

    await userEvent.click(await screen.findByRole("button", { name: "Add label" }));
    await userEvent.type(screen.getByPlaceholderText("Change or add labels…"), "des");

    expect(screen.getByRole("menuitemcheckbox", { name: "Design" })).toBeVisible();
    expect(screen.queryByRole("menuitemcheckbox", { name: "Backend" })).toBeNull();
  });
});
