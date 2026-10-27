import type { DriveFile, DriveSpace, DriveValue } from "@comma/core/contract";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { render, screen, waitFor, within } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { Toaster } from "@comma/ui/components/toast";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { resetDriveStoreForTest } from "../driveStore";

// Drive's page over a scripted core: what it shows of the core's `drive` and which calls it makes.
// What those calls do — the node, the hosted Drive, System Files — is tested in packages/core/test/drive-files.test.ts.

vi.mock("@tanstack/react-router", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@tanstack/react-router")>()),
  useNavigate: () => vi.fn(),
  useSearch: () => ({}),
}));
vi.mock("../../chat/ChatProvider", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../../chat/ChatProvider")>()),
  useChatRegistry: () => ({}),
}));
vi.mock("../../chat-sidebar/ChatSidebarContext", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../../chat-sidebar/ChatSidebarContext")>()),
  useChatSidebarActions: () => ({
    closeDrivePreview: vi.fn(),
    openDrivePreview: vi.fn(),
  }),
  useRegisterChatSidebarHost: () => {},
}));

const { DriveRoute } = await import("../DriveRoute");
const { DrivePreviewPanel } = await import("../DrivePreviewPanel");

const file = (
  id: string,
  name: string,
  sizeBytes: number,
  extra: Partial<DriveFile> = {}
) =>
  ({
    contentsHash: `hash-${id}`,
    deviceId: "this-mac",
    id,
    modifiedAt: 1_750_000_000_000,
    name,
    sizeBytes,
    spaceId: "space-a",
    ...extra,
  }) satisfies DriveFile;

const folderA: DriveSpace = {
  id: "space-a",
  name: "Folder A",
  originPath: "/Users/me/Folder A",
  synced: false,
  writable: true,
};
const shared: DriveSpace = { id: "space-shared", name: "Shared", writable: false };

function deviceDrive(): DriveValue {
  return {
    node: { status: "ready" },
    devices: [{ id: "this-mac", label: "This Mac", current: true }],
    spaces: [folderA, shared],
    files: [
      file("pdf", "Openai.pdf", 900_000),
      file("logo", "logo.svg", 300),
      file("shot", "Screenshot.png", 40_000),
    ],
    originDeviceId: "this-mac",
    versionPolicy: "newest",
    localSyncEnabled: false,
    localSyncRoot: "/Users/me/Drive",
    syncHistory: [],
    transfers: [],
  };
}

/** The page over a core holding `drive`; `answer` answers each call and may change `drive`, which the page is then sent. */
function renderDrive(
  drive: DriveValue,
  answer: (name: string, params: Record<string, unknown>) => unknown = () => null
) {
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "drive" ? drive : undefined),
    calls: async (name, params) => {
      const result = await answer(name, params as Record<string, unknown>);
      core.changed("drive");
      return result;
    },
  });
  const user = userEvent.setup();
  render(
    core.wrap(
      <>
        <DriveRoute />
        <Toaster />
      </>
    )
  );
  return { core, user };
}

beforeEach(() => {
  // jsdom has no layout; the virtualized file list renders rows for an 800px viewport.
  vi.spyOn(HTMLElement.prototype, "clientHeight", "get").mockReturnValue(800);
  vi.spyOn(HTMLElement.prototype, "clientWidth", "get").mockReturnValue(800);
  installNativeBridgeMock({ platform: "electron" });
  resetDriveStoreForTest();
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

const openMenu = (user: ReturnType<typeof userEvent.setup>, target: Element) =>
  user.pointer({ keys: "[MouseRight]", target });

const menuItems = async () =>
  within(await screen.findByRole("menu"))
    .getAllByRole("menuitem")
    .map((item) => item.textContent);

const fileRows = () => screen.getAllByTestId(/^drive-file-(pdf|logo|shot)$/);

it("sorts by the header, and deletes the selection through the core", async () => {
  const drive = deviceDrive();
  const { core, user } = renderDrive(drive, (name, params) => {
    if (name === "drive.delete") {
      const gone = new Set(params.files as string[]);
      drive.files = drive.files.filter((entry) => !gone.has(entry.id));
    }
    return null;
  });
  const byName = await screen.findByTestId("drive-sort-name");
  // Name ascending is the resting sort, case-insensitive and natural.
  expect(byName).toHaveAttribute("data-sort-direction", "asc");
  await waitFor(() =>
    expect(fileRows()[0]).toHaveAttribute("data-testid", "drive-file-logo")
  );
  await user.click(screen.getByTestId("drive-sort-size"));
  await user.click(screen.getByTestId("drive-sort-size"));
  expect(screen.getByTestId("drive-sort-size")).toHaveAttribute(
    "data-sort-direction",
    "desc"
  );
  expect(fileRows()[0]).toHaveAttribute("data-testid", "drive-file-pdf");

  await user.click(screen.getByRole("checkbox", { name: "Select all files" }));
  expect(await screen.findByTestId("drive-selection-bar")).toHaveTextContent(
    "3 selected"
  );
  await user.click(await screen.findByTestId("drive-delete-selected"));
  // The selection is confirmed as a list, so "3 files" is never a guess.
  const dialog = await screen.findByRole("dialog", { name: "Delete 3 files?" });
  expect(
    within(within(dialog).getByTestId("drive-delete-files")).getAllByRole("listitem")
  ).toHaveLength(3);
  await user.click(within(dialog).getByRole("button", { name: "Delete" }));
  expect(await screen.findByText("Folder is empty")).toBeInTheDocument();
  expect(core.sentTo("drive.delete")).toEqual([{ files: ["pdf", "logo", "shot"] }]);
  expect(screen.queryByTestId("drive-selection-bar")).toBeNull();
});

it("keeps files offline and deletes one from its row menu", async () => {
  const drive = deviceDrive();
  const { core, user } = renderDrive(drive, (name, params) => {
    const ids = new Set(params.files as string[]);
    if (name === "drive.keepOffline")
      drive.files = drive.files.map((entry) =>
        ids.has(entry.id)
          ? { ...entry, keepOffline: params.keepOffline as boolean }
          : entry
      );
    if (name === "drive.delete")
      drive.files = drive.files.filter((entry) => !ids.has(entry.id));
    return null;
  });
  await openMenu(user, await screen.findByTestId("drive-file-pdf"));
  expect(await menuItems()).toEqual([
    "Ask Comma",
    "Download",
    "Keep Offline",
    "Delete",
  ]);

  // Keep Offline pins the file; the menu then offers to undo it.
  await user.click(screen.getByRole("menuitem", { name: "Keep Offline" }));
  expect(await screen.findByTestId("drive-file-pinned-pdf")).toBeInTheDocument();
  await openMenu(user, screen.getByTestId("drive-file-pdf"));
  expect(
    await screen.findByRole("menuitem", { name: "Stop Keeping Offline" })
  ).toBeInTheDocument();
  await user.keyboard("{Escape}");

  // Delete asks first; Escape keeps the file, and only the sheet's Delete removes it.
  await openMenu(user, screen.getByTestId("drive-file-pdf"));
  await user.click(await screen.findByRole("menuitem", { name: "Delete" }));
  await screen.findByRole("dialog", { name: "Delete “Openai.pdf”?" });
  await user.keyboard("{Escape}");
  await waitFor(() =>
    expect(screen.queryByRole("dialog", { name: "Delete “Openai.pdf”?" })).toBeNull()
  );
  expect(core.sentTo("drive.delete")).toEqual([]);
  await openMenu(user, screen.getByTestId("drive-file-pdf"));
  await user.click(await screen.findByRole("menuitem", { name: "Delete" }));
  const dialog = await screen.findByRole("dialog", { name: "Delete “Openai.pdf”?" });
  await user.click(within(dialog).getByRole("button", { name: "Delete" }));
  await waitFor(() => expect(screen.queryByTestId("drive-file-pdf")).toBeNull());
  expect(await screen.findByTestId("comma-drive-delete")).toHaveTextContent(
    "“Openai.pdf” was removed from the space."
  );

  // A selected row's menu acts on the whole selection.
  await user.click(within(screen.getByTestId("drive-file-shot")).getByRole("checkbox"));
  await user.click(within(screen.getByTestId("drive-file-logo")).getByRole("checkbox"));
  await openMenu(user, screen.getByTestId("drive-file-shot"));
  expect(await menuItems()).toEqual([
    "Ask Comma",
    "Download all",
    "Keep Offline",
    "Delete",
  ]);
  await user.click(screen.getByRole("menuitem", { name: "Keep Offline" }));
  expect(
    await screen.findByTestId("comma-drive-keep-offline-selection")
  ).toHaveTextContent("2 files stay on this");
  expect(core.sentTo("drive.keepOffline")).toEqual([
    { files: ["pdf"], keepOffline: true },
    { files: ["logo", "shot"], keepOffline: true },
  ]);
});

it("deletes a space only after its name is typed", async () => {
  const drive = deviceDrive();
  const { core, user } = renderDrive(drive, (name, params) => {
    if (name === "drive.removeSpace")
      drive.spaces = drive.spaces.filter((space) => space.id !== params.space);
    return null;
  });
  await openMenu(user, await screen.findByTestId("drive-space-space-shared"));
  await user.click(await screen.findByRole("menuitem", { name: "Delete" }));
  const dialog = await screen.findByRole("dialog", { name: "Delete “Shared”?" });
  const field = within(dialog).getByRole("textbox");
  await user.type(field, "Share");
  expect(within(dialog).getByRole("button", { name: "Delete" })).toBeDisabled();
  await user.type(field, "d");
  await user.click(within(dialog).getByRole("button", { name: "Delete" }));
  await waitFor(() =>
    expect(screen.queryByTestId("drive-space-space-shared")).toBeNull()
  );
  expect(core.sentTo("drive.removeSpace")).toEqual([{ space: "space-shared" }]);
  expect(await screen.findByTestId("comma-drive-stop-sharing")).toBeInTheDocument();
});

it("adds a folder picked on this device as a space, and shows it", async () => {
  const drive = deviceDrive();
  const { core, user } = renderDrive(drive, (name) => {
    if (name !== "drive.addSpace") return null;
    drive.spaces = [
      ...drive.spaces,
      { id: "space-photos", name: "Photos", writable: true },
    ];
    return { space: "space-photos", name: "Photos", path: "/Users/me/Photos" };
  });
  await openMenu(user, await screen.findByTestId("drive-space-rail"));
  expect(await menuItems()).toEqual(["New folder", "Upload folder"]);
  await user.click(screen.getByRole("menuitem", { name: "New folder" }));
  await waitFor(() =>
    expect(screen.getByTestId("drive-space-space-photos")).toHaveAttribute(
      "data-selected",
      "true"
    )
  );
  expect(core.sentTo("drive.addSpace")).toEqual([{}]);
  expect(await screen.findByTestId("comma-drive-space-added")).toHaveTextContent(
    "/Users/me/Photos"
  );
});

it("renames a space and turns its sync on through the core", async () => {
  const drive = deviceDrive();
  const { core, user } = renderDrive(drive, (name, params) => {
    const change = (update: Partial<DriveSpace>) =>
      (drive.spaces = drive.spaces.map((space) =>
        space.id === params.space ? { ...space, ...update } : space
      ));
    if (name === "drive.renameSpace") change({ name: params.name as string });
    if (name === "drive.setSpaceSynced") {
      change({ synced: params.synced as boolean });
      return { adopt: 1, keep: 0, conflict: 0 };
    }
    return null;
  });
  const space = await screen.findByTestId("drive-space-space-a");
  await openMenu(user, space);
  expect(await menuItems()).toEqual(["Rename", "Delete"]);
  await user.click(screen.getByRole("menuitem", { name: "Rename" }));
  const rename = await screen.findByRole("dialog", { name: "Rename folder" });
  expect(within(rename).getByRole("textbox")).toHaveValue("Folder A");
  await user.clear(within(rename).getByRole("textbox"));
  await user.type(within(rename).getByRole("textbox"), "Folder B");
  await user.click(within(rename).getByRole("button", { name: "Rename" }));
  await waitFor(() => expect(space).toHaveTextContent("Folder B"));
  expect(core.sentTo("drive.renameSpace")).toEqual([
    { space: "space-a", name: "Folder B" },
  ]);

  await openMenu(user, space);
  await user.click(
    within(screen.getByTestId("drive-space-sync-row-space-a")).getByRole("switch")
  );
  expect(await screen.findByTestId("comma-drive-space-sync-space-a")).toHaveTextContent(
    "1 files copied to this"
  );
  expect(core.sentTo("drive.setSpaceSynced")).toEqual([
    { space: "space-a", synced: true },
  ]);
});

const GROUP = "grp_1";
const system = (path: string, writable: boolean, hash?: string): DriveFile => {
  const slash = path.lastIndexOf("/");
  return {
    contentsHash: hash ?? path,
    deviceId: "",
    id: `system:${path}`,
    modifiedAt: 1_750_000_000_000,
    name: path.slice(slash + 1),
    sizeBytes: 10,
    spaceId: "comma-system-files",
    system: { kind: "vfs", group: GROUP, path: `/${path}`, hash },
    writable,
    ...(slash === -1 ? {} : { folderPath: path.slice(0, slash) }),
  };
};

function webDrive(): DriveValue {
  return {
    ...deviceDrive(),
    node: { status: "off" },
    devices: [],
    localSyncRoot: "",
    spaces: [
      { id: "comma-drive", name: "Drive", remote: true, writable: false, synced: true },
      { id: "comma-system-files", name: "", remote: true, writable: false },
    ],
    files: [
      file("comma-drive:a.txt", "a.txt", 3, {
        deviceId: "",
        spaceId: "comma-drive",
        writable: false,
      }),
      file("comma-drive:b.txt", "b.txt", 3, {
        deviceId: "",
        spaceId: "comma-drive",
        writable: false,
      }),
      file("comma-drive:c.txt", "c.txt", 3, {
        deviceId: "",
        spaceId: "comma-drive",
        writable: false,
      }),
      system("memory/semantic/user.md", true, "u1"),
      system("imports/REPORT.md", false, "r1"),
    ],
  };
}

it("shows the Workspace's Drive read-only on the web, and downloads through the core", async () => {
  installNativeBridgeMock({ platform: "web" });
  vi.stubGlobal("URL", Object.assign(URL, { createObjectURL: () => "blob:drive" }));
  vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
  const saved = vi.spyOn(HTMLAnchorElement.prototype, "download", "set");
  const { core, user } = renderDrive(webDrive(), (name, params) => {
    if (name !== "drive.download") return null;
    if (params.file === "comma-drive:b.txt") throw new Error("gone");
    return {
      transfer: `t-${String(params.file)}`,
      bytes: new TextEncoder().encode("abc"),
      mediaType: "text/plain",
    };
  });
  await screen.findByTestId("drive-file-comma-drive:a.txt");
  // Nothing is uploaded, synced or removed here.
  expect(screen.getByRole("button", { name: "Add files" })).toBeDisabled();
  expect(screen.queryByTestId("drive-space-sync-row-comma-drive")).toBeNull();
  await openMenu(user, screen.getByTestId("drive-file-comma-drive:a.txt"));
  expect(await menuItems()).toEqual(["Ask Comma", "Download"]);
  await user.keyboard("{Escape}");

  await user.click(screen.getByRole("checkbox", { name: "Select all files" }));
  await user.click(await screen.findByTestId("drive-download-selected"));
  await waitFor(() =>
    expect(screen.getByTestId("comma-drive-download-all")).toHaveTextContent(
      "2 files were downloaded; 1 could not be."
    )
  );
  expect(core.sentTo("drive.download")).toEqual([
    { file: "comma-drive:a.txt" },
    { file: "comma-drive:b.txt" },
    { file: "comma-drive:c.txt" },
  ]);
  // The browser saves the bytes the core handed over.
  expect(saved.mock.calls.map(([name]) => name)).toEqual(["a.txt", "c.txt"]);
  expect(screen.queryByTestId("drive-selection-bar")).toBeNull();
});

it("stages picked files with Main and has the core upload them; the panel shows the core's transfers", async () => {
  const bridge = installNativeBridgeMock({ platform: "electron" });
  bridge.synchronicity.stageImport = vi.fn(async ({ source }: { source: unknown }) => {
    const picked = source as File;
    return picked.name === "gone.txt"
      ? { status: "unavailable" as const }
      : {
          status: "staged" as const,
          ref: `ref-${picked.name}`,
          name: picked.name,
          size: 1,
        };
  });
  const drive = deviceDrive();
  drive.transfers = [
    {
      id: "t1",
      direction: "upload",
      fileName: "old.txt",
      spaceId: "space-a",
      status: "error",
    },
  ];
  const { core, user } = renderDrive(drive, () => null);
  await screen.findByTestId("drive-file-pdf");
  const input = document.querySelector<HTMLInputElement>(
    'input[type="file"]:not([data-testid])'
  )!;
  await user.upload(input, [
    new File(["a"], "a.txt"),
    new File(["b"], "b.txt"),
    new File(["c"], "gone.txt"),
  ]);
  await waitFor(() =>
    expect(core.sentTo("drive.upload")).toEqual([
      {
        space: "space-a",
        files: [
          { ref: "ref-a.txt", name: "a.txt" },
          { ref: "ref-b.txt", name: "b.txt" },
        ],
      },
    ])
  );
  // A file Main could not keep is said at once; it never became a transfer.
  expect(await screen.findByTestId("comma-drive-upload-failed")).toBeInTheDocument();

  const row = await screen.findByTestId("drive-transfer-t1");
  expect(row).toHaveAttribute("data-status", "error");
  await user.click(within(row).getByRole("button", { name: "Retry" }));
  expect(core.sentTo("drive.retryTransfer")).toEqual([{ transfer: "t1" }]);

  // Closed, the finished rows go as the panel opens next.
  await user.click(screen.getByTestId("drive-transfer-close"));
  expect(core.sentTo("drive.dismissTransfers")).toEqual([]);
  await user.upload(input, [new File(["d"], "d.txt")]);
  await waitFor(() => expect(core.sentTo("drive.dismissTransfers")).toEqual([{}]));
});

it("deletes a memory file in System Files, and asks again when the Router changed it", async () => {
  installNativeBridgeMock({ platform: "web" });
  const drive = webDrive();
  let changed = true;
  const { core, user } = renderDrive(drive, (name, params) => {
    if (name !== "drive.delete") return null;
    if (changed) {
      changed = false;
      throw Object.assign(new Error("changed"), { code: "changed" });
    }
    const gone = new Set(params.files as string[]);
    drive.files = drive.files.filter((entry) => !gone.has(entry.id));
    return null;
  });
  await user.click(await screen.findByTestId("drive-space-comma-system-files"));
  await user.click(await screen.findByTestId("drive-folder-imports"));
  await openMenu(
    user,
    await screen.findByTestId("drive-file-system:imports/REPORT.md")
  );
  expect(await menuItems()).toEqual(["Ask Comma", "Download"]);
  await user.keyboard("{Escape}");

  await user.click(screen.getByTestId("drive-space-comma-system-files"));
  await user.click(await screen.findByTestId("drive-folder-memory"));
  await user.click(await screen.findByTestId("drive-folder-semantic"));
  const row = await screen.findByTestId("drive-file-system:memory/semantic/user.md");
  await openMenu(user, row);
  expect(await menuItems()).toEqual(["Ask Comma", "Download", "Delete"]);
  await user.click(screen.getByRole("menuitem", { name: "Delete" }));
  await user.click(
    within(await screen.findByRole("dialog", { name: "Delete “user.md”?" })).getByRole(
      "button",
      { name: "Delete" }
    )
  );
  expect(await screen.findByTestId("comma-drive-delete")).toHaveTextContent(
    "was not deleted"
  );
  expect(
    screen.getByTestId("drive-file-system:memory/semantic/user.md")
  ).toBeInTheDocument();

  await openMenu(user, screen.getByTestId("drive-file-system:memory/semantic/user.md"));
  await user.click(await screen.findByRole("menuitem", { name: "Delete" }));
  await user.click(
    within(await screen.findByRole("dialog", { name: "Delete “user.md”?" })).getByRole(
      "button",
      { name: "Delete" }
    )
  );
  await waitFor(() =>
    expect(screen.queryByTestId("drive-file-system:memory/semantic/user.md")).toBeNull()
  );
  expect(core.sentTo("drive.delete")).toEqual([
    { files: ["system:memory/semantic/user.md"] },
    { files: ["system:memory/semantic/user.md"] },
  ]);
});

it("edits a memory file in the preview, and saves over what the Router wrote once told", async () => {
  installNativeBridgeMock({ platform: "web" });
  const drive = webDrive();
  const { core, user } = renderDrive(drive, (name) => {
    if (name === "drive.read")
      return {
        bytes: new TextEncoder().encode("Old day.\n"),
        mediaType: "text/markdown",
      };
    if (name !== "drive.write") return null;
    // The Router appended while the user typed: the first save is refused with the version now there.
    if (core.sentTo("drive.write").length === 1)
      throw Object.assign(new Error("changed"), {
        code: "changed",
        detail: { hash: "u2" },
      });
    return { file: "system:memory/semantic/user.md" };
  });
  await screen.findByTestId("drive-space-comma-system-files");
  render(
    core.wrap(
      <DrivePreviewPanel
        fileId="system:memory/semantic/user.md"
        onOpenBrowser={() => {}}
        panelId="memory"
      />
    )
  );
  const edit = await screen.findByTestId("drive-preview-edit");
  await waitFor(() => expect(edit).toBeEnabled());
  await user.click(edit);
  const text = await screen.findByTestId("drive-file-editor-text");
  expect(text).toHaveValue("Old day.\n");
  await user.clear(text);
  await user.type(text, "Rewritten.");
  await user.click(screen.getByTestId("drive-file-editor-save"));
  expect(
    await screen.findByTestId("comma-drive-save-system:memory/semantic/user.md")
  ).toHaveTextContent("changed since you opened it");
  expect(screen.getByTestId("drive-file-editor-text")).toHaveValue("Rewritten.");

  await waitFor(() =>
    expect(screen.getByTestId("drive-file-editor-save")).toBeEnabled()
  );
  await user.click(screen.getByTestId("drive-file-editor-save"));
  await waitFor(() =>
    expect(
      screen.getByTestId("comma-drive-save-system:memory/semantic/user.md")
    ).toHaveTextContent("Saved")
  );
  const bytes = new TextEncoder().encode("Rewritten.");
  const write = {
    space: "comma-system-files",
    folderPath: "memory/semantic",
    name: "user.md",
    bytes,
  };
  expect(core.sentTo("drive.write")).toEqual([
    { ...write, expectedHash: "u1" },
    { ...write, expectedHash: "u2" },
  ]);
});
