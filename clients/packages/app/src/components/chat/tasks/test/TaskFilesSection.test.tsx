import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { render, screen, waitFor, within } from "@comma/test-utils/render";
import { stubProperty } from "@comma/test-utils/stub-property";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { beforeEach, expect, it, vi } from "vitest";
import type { TaskFile, TaskFilesValue } from "@comma/core-client";
import type { CommaConversation } from "@comma/core/api-schemas";
import { labelCatalog } from "../../../../test/labelsCore";
import { testProductLease } from "../../../../test/productInboxProjectionHarness";
import { ChatProvider } from "../../ChatProvider";
import { TaskDetailsPanel } from "../TaskDetailsPanel";

const pdfjs = vi.hoisted(() => ({
  getDocument: vi.fn(),
  GlobalWorkerOptions: {},
  PDFDataRangeTransport: class {
    onDataRange() {}
  },
  PDFWorker: class {
    destroy() {}
  },
}));
vi.mock("pdfjs-dist", () => pdfjs);

const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });

beforeEach(() => setInteractionModality("pointer"));

const conversation = {
  group_id: "grp_1",
  id: "cnv_1",
  kind: "agent_task",
  labels: ["lbl_b"],
  status: "running",
  title: "Report",
} as unknown as CommaConversation;

const file = (n: number): TaskFile => ({
  conversation_id: "cnv_1",
  task_title: "Report",
  message_id: `msg_${n}`,
  seq: n,
  index: 0,
  type: n === 1 ? "image" : "file",
  file_name: `file-${n}.pdf`,
  mime_type: null,
  size: 2_048,
  created_at: n,
});

const ready = (files: TaskFile[]): TaskFilesValue => ({
  status: "ready",
  files,
  nextCursor: null,
});

/** The Task panel over a core that answers `taskFiles.list` with `answer`, and other calls and topics with `script`. */
async function renderPanel(
  answer: () => TaskFilesValue,
  script: {
    calls?: (name: string, params: unknown) => unknown;
    values?: (topic: Record<string, unknown>) => unknown;
    /** Renders the panel in a chat session, which opening a file in an app needs. */
    chat?: boolean;
  } = {}
) {
  const core = createScriptedCore({
    calls: (name, params) =>
      name === "taskFiles.list" ? answer() : (script.calls?.(name, params) ?? null),
    values: (topic) =>
      script.values?.(topic) ??
      (topic.topic === "taskLabels"
        ? {
            catalog: labelCatalog({
              labels: [
                { color: "blue", description: "", id: "lbl_b", name: "Backend" },
              ],
            }),
            error: false,
            loading: false,
          }
        : topic.topic === "marks"
          ? { marks: {} }
          : undefined),
  });
  const onAttachFile = vi.fn();
  const onOpenFile = vi.fn();
  const panel = (
    <TaskDetailsPanel
      conversation={conversation}
      groupId="grp_1"
      onAttachFile={onAttachFile}
      onOpenFile={onOpenFile}
      open
    />
  );
  const { unmount } = render(
    core.wrap(
      script.chat ? (
        <ChatProvider productLease={testProductLease}>{panel}</ChatProvider>
      ) : (
        panel
      )
    )
  );
  await flush();
  await flush();
  return { core, onAttachFile, onOpenFile, unmount };
}

it("lists the Task's files below its labels, folds a long list as the Activity does, and opens one", async () => {
  const { core, onOpenFile } = await renderPanel(() =>
    ready([10, 9, 8, 7, 6, 5, 4, 3, 2, 1].map(file))
  );
  expect(core.sentTo("taskFiles.list")).toEqual([
    { group: "grp_1", conversation: "cnv_1" },
  ]);
  const section = screen.getByTestId("task-panel-files");
  expect(
    screen.getByTestId("task-panel-labels").compareDocumentPosition(section) &
      Node.DOCUMENT_POSITION_FOLLOWING
  ).toBeTruthy();

  const files = within(section);
  expect(files.getAllByTestId("task-panel-file").map((row) => row.textContent)).toEqual(
    [
      "file-10.pdf2 KB",
      "file-9.pdf2 KB",
      "file-8.pdf2 KB",
      "file-7.pdf2 KB",
      "file-6.pdf2 KB",
    ]
  );
  const more = files.getByTestId("task-panel-files-more");
  expect(more).toHaveTextContent("5 more files");
  await user().click(more);
  expect(files.getAllByTestId("task-panel-file")).toHaveLength(10);
  expect(files.queryByTestId("task-panel-files-more")).toBeNull();
  // The first file the fold row gave way to takes its focus.
  expect(files.getByRole("button", { name: "Open file-5.pdf" })).toHaveFocus();

  await user().click(files.getByRole("button", { name: "Open file-1.pdf" }));
  expect(onOpenFile).toHaveBeenCalledWith(file(1));
});

it("shows a short list whole, and hides or shows the list from its heading", async () => {
  await renderPanel(() => ready([8, 7, 6, 5, 4, 3, 2, 1].map(file)));
  const files = within(screen.getByTestId("task-panel-files"));
  expect(files.getAllByTestId("task-panel-file")).toHaveLength(8);
  expect(files.queryByTestId("task-panel-files-more")).toBeNull();

  // The heading itself is the disclosure.
  const heading = files.getByRole("button", { name: "Files" });
  expect(heading).toHaveAttribute("aria-expanded", "true");
  await user().click(heading);
  expect(files.queryAllByTestId("task-panel-file")).toHaveLength(0);
  expect(heading).toHaveAttribute("aria-expanded", "false");
  await user().click(heading);
  expect(files.getAllByTestId("task-panel-file")).toHaveLength(8);
  expect(heading).toHaveAttribute("aria-expanded", "true");
});

it("shows nothing for a Task without files, and says when Comma still indexes them", async () => {
  await renderPanel(() => ready([]));
  expect(screen.queryByTestId("task-panel-files")).toBeNull();

  await renderPanel(() => ({ status: "indexing", files: [], nextCursor: null }));
  expect(screen.getByTestId("task-panel-files-unavailable")).toHaveTextContent(
    "Files show here once Comma has indexed them."
  );
});

/** A file row, by its file's name. */
const row = (name: string) => screen.getByRole("button", { name: `Open ${name}` });

it("previews a file on hover: an image from its stream, a text file's first lines read once, another file's details", async () => {
  const notes: TaskFile = {
    ...file(3),
    file_name: "notes.md",
    mime_type: "text/markdown",
    size: 18,
  };
  const chart: TaskFile = {
    ...file(2),
    file_name: "chart.png",
    mime_type: "image/png",
  };
  const archive: TaskFile = {
    ...file(1),
    type: "file",
    file_name: "archive.zip",
    mime_type: "application/zip",
  };
  const { core } = await renderPanel(() => ready([notes, chart, archive]), {
    calls: (name) =>
      name === "files.readRange"
        ? {
            bytes: new TextEncoder().encode("# Notes\nfirst line"),
            size: 18,
            type: "text/markdown",
          }
        : null,
    values: (topic) =>
      topic.topic === "fileStream" ? { status: "ready", url: "blob:chart" } : undefined,
  });
  const u = user();

  await u.hover(row("notes.md"));
  await advance(250);
  await flush();
  let card = screen.getByRole("tooltip");
  expect(within(card).getByTestId("task-file-preview-text").textContent).toBe(
    "# Notes\nfirst line"
  );
  expect(card).toHaveTextContent(/# Notes first linenotes\.mdMD · 18 B · /);
  // Only the head the card shows is read.
  expect(core.sentTo("files.readRange")).toEqual([
    {
      source: {
        source: "attachment",
        group: "grp_1",
        conversation: "cnv_1",
        message: "msg_3",
        index: 0,
      },
      offset: 0,
      length: 2048,
    },
  ]);

  await u.unhover(row("notes.md"));
  await advance(250);
  await u.hover(row("notes.md"));
  await advance(250);
  await flush();
  expect(screen.getByTestId("task-file-preview-text")).toHaveTextContent("first line");
  // A second hover reads nothing.
  expect(core.sentTo("files.readRange")).toHaveLength(1);

  await u.hover(row("chart.png"));
  await advance(250);
  await flush();
  card = screen.getByRole("tooltip");
  expect(card.querySelector("img")).toHaveAttribute("src", "blob:chart");
  expect(card).toHaveTextContent("chart.png");

  await u.hover(row("archive.zip"));
  await advance(250);
  await flush();
  card = screen.getByRole("tooltip");
  expect(card).toHaveTextContent(/^archive\.zipZIP · 2 KB · /);
  expect(within(card).queryByTestId("task-file-preview-media")).toBeNull();
  expect(within(card).queryByTestId("task-file-preview-text")).toBeNull();
  expect(core.sentTo("files.readRange")).toHaveLength(1);
});

it("acts on a file from its context menu: adds it to the message, copies its name, and offers a download", async () => {
  // user-event puts its own clipboard on the navigator; this one replaces it.
  const u = user();
  const writeText = vi.fn().mockResolvedValue(undefined);
  stubProperty(navigator, "clipboard", { configurable: true, value: { writeText } });
  const { onAttachFile } = await renderPanel(() => ready([file(2), file(1)]));
  const target = row("file-2.pdf");

  await u.pointer({ keys: "[MouseRight]", target });
  let menu = screen.getByRole("menu", { name: "Actions for file-2.pdf" });
  // A browser cannot put a file on the clipboard or reveal one: it copies the name and downloads the file.
  expect(
    within(menu)
      .getAllByRole("menuitem")
      .map((item) => item.textContent)
  ).toEqual(["Add to Context", "Copy name", "Download"]);
  expect(target).toHaveAttribute("data-menu-open", "true");
  await u.click(within(menu).getByRole("menuitem", { name: "Add to Context" }));
  expect(onAttachFile).toHaveBeenCalledWith(file(2));
  expect(screen.queryByRole("menu")).toBeNull();

  await u.pointer({ keys: "[MouseRight]", target });
  menu = screen.getByRole("menu", { name: "Actions for file-2.pdf" });
  await u.click(within(menu).getByRole("menuitem", { name: "Copy name" }));
  await flush();
  expect(writeText).toHaveBeenCalledWith("file-2.pdf");
});

it("offers the macOS desktop's file copy, Open in and Reveal in Finder from the context menu", async () => {
  const copyDownload = vi.fn(async () => ({ status: "copied" as const }));
  const openDownload = vi.fn(async () => ({ status: "opened" as const }));
  const revealDownload = vi.fn(async () => ({ status: "revealed" as const }));
  installNativeBridgeMock({
    platform: "electron",
    os: "macos",
    files: {
      copyDownload,
      openDownload,
      revealDownload,
      listOpenApplications: async () => ({
        status: "available",
        applications: [{ id: "com.apple.Preview", name: "Preview", isDefault: true }],
      }),
    },
  });
  const { core } = await renderPanel(() => ready([file(2), file(1)]), {
    calls: (name) =>
      name === "files.save" ? { downloadRef: "dl_1", fileName: "file-2.pdf" } : null,
    chat: true,
  });
  const u = user();
  const menuOn = async () => {
    await u.pointer({
      keys: "[MouseRight]",
      target: await screen.findByRole("button", { name: "Open file-2.pdf" }),
    });
    return screen.getByRole("menu", { name: "Actions for file-2.pdf" });
  };

  let menu = await menuOn();
  expect(
    within(menu)
      .getAllByRole("menuitem")
      .map((item) => item.textContent)
  ).toEqual(["Add to Context", "Copy", "Open in", "Reveal in Finder"]);
  await u.click(within(menu).getByRole("menuitem", { name: "Copy" }));
  const copy = await screen.findByRole("menu", { name: "Copy" });
  expect(
    within(copy)
      .getAllByRole("menuitem")
      .map((item) => item.textContent)
  ).toEqual(["Copy file", "Copy name"]);
  await u.click(within(copy).getByRole("menuitem", { name: "Copy file" }));
  // The file is saved as it arrives and its saved copy goes on the clipboard: the window never holds it.
  await waitFor(() =>
    expect(copyDownload).toHaveBeenCalledWith({ downloadRef: "dl_1" })
  );

  menu = await menuOn();
  await u.click(within(menu).getByRole("menuitem", { name: "Open in" }));
  const apps = await screen.findByRole("menu", { name: "Open in" });
  await u.click(await within(apps).findByRole("menuitem", { name: "Preview" }));
  await waitFor(() =>
    expect(openDownload).toHaveBeenCalledWith({
      downloadRef: "dl_1",
      applicationId: "com.apple.Preview",
    })
  );

  menu = await menuOn();
  await u.click(within(menu).getByRole("menuitem", { name: "Reveal in Finder" }));
  await waitFor(() =>
    expect(revealDownload).toHaveBeenCalledWith({ downloadRef: "dl_1" })
  );
  expect(core.sentTo("files.save")[0]).toEqual({
    source: {
      source: "attachment",
      group: "grp_1",
      conversation: "cnv_1",
      message: "msg_2",
      index: 0,
    },
    name: "file-2.pdf",
  });
});

it("previews a PDF's first page on hover, drawn once from the start of the file and kept while the panel shows", async () => {
  const page = {
    getViewport: ({ scale }: { scale: number }) => ({
      width: 360 * scale,
      height: 504 * scale,
    }),
    render: vi.fn((_: { canvas: HTMLCanvasElement }) => ({
      promise: Promise.resolve(),
      cancel: vi.fn(),
    })),
  };
  const destroy = vi.fn();
  pdfjs.getDocument
    .mockReturnValueOnce({
      promise: Promise.resolve({ getPage: vi.fn().mockResolvedValue(page) }),
      destroy,
    })
    .mockImplementationOnce(() => ({
      promise: Promise.reject(new Error("Not a PDF")),
      destroy: vi.fn(),
    }));
  stubProperty(HTMLCanvasElement.prototype, "toBlob", {
    configurable: true,
    value(this: HTMLCanvasElement, done: BlobCallback) {
      done(new Blob(["cover"], { type: "image/jpeg" }));
    },
  });
  const createObjectURL = vi.fn(() => "blob:cover");
  const revokeObjectURL = vi.fn();
  stubProperty(URL, "createObjectURL", { configurable: true, value: createObjectURL });
  stubProperty(URL, "revokeObjectURL", { configurable: true, value: revokeObjectURL });
  const { core, unmount } = await renderPanel(() => ready([file(3), file(2)]), {
    calls: (name) =>
      name === "files.readRange"
        ? { bytes: new Uint8Array(8), size: 2_048, type: "application/pdf" }
        : null,
  });
  const u = user();

  await u.hover(row("file-3.pdf"));
  await advance(250);
  await flush();
  await flush();
  const cover = within(screen.getByRole("tooltip")).getByTestId(
    "task-file-preview-cover"
  );
  expect(cover.querySelector("img")).toHaveAttribute("src", "blob:cover");
  // pdf.js opens the file from its first span and reads only what the first page needs, in the shared worker.
  expect(core.sentTo("files.readRange")[0]).toMatchObject({ offset: 0 });
  expect(pdfjs.getDocument).toHaveBeenCalledWith(
    expect.objectContaining({
      disableAutoFetch: true,
      worker: expect.any(pdfjs.PDFWorker),
    })
  );
  // The page is drawn at the card's width, and the document closes once it is.
  expect(page.render).toHaveBeenCalledOnce();
  expect(page.render.mock.calls[0]![0].canvas.height).toBe(320);
  expect(destroy).toHaveBeenCalled();

  await u.unhover(row("file-3.pdf"));
  await advance(250);
  await u.hover(row("file-3.pdf"));
  await advance(250);
  await flush();
  expect(
    screen.getByTestId("task-file-preview-cover").querySelector("img")
  ).toHaveAttribute("src", "blob:cover");
  // A second hover draws nothing and shows the same image.
  expect(pdfjs.getDocument).toHaveBeenCalledOnce();
  expect(page.render).toHaveBeenCalledOnce();
  expect(createObjectURL).toHaveBeenCalledOnce();
  expect(revokeObjectURL).not.toHaveBeenCalled();

  // A PDF that cannot be drawn shows its details alone.
  await u.hover(row("file-2.pdf"));
  await advance(250);
  await flush();
  await flush();
  const card = screen.getByRole("tooltip");
  expect(within(card).queryByTestId("task-file-preview-cover")).toBeNull();
  expect(card).toHaveTextContent(/^file-2\.pdfPDF · 2 KB · /);

  // The panel's covers go with it.
  unmount();
  expect(revokeObjectURL).toHaveBeenCalledWith("blob:cover");
});
