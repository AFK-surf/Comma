import userEvent from "@testing-library/user-event";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { ChatPanelFile, type ChatPanelFileOpenInAction } from "../ChatPanelMedia";
import { ChatPanelFileOpenInMenu } from "../ChatPanelFileOpenInMenu";

const application = { id: "preview", name: "Preview", isDefault: true };
const createAction = (): ChatPanelFileOpenInAction => ({
  listApplications: vi.fn().mockResolvedValue([application]),
  openApplication: vi.fn().mockResolvedValue(undefined),
  reveal: { label: "Show in Finder", run: vi.fn().mockResolvedValue(undefined) },
});

describe("file card preview and Open in", () => {
  it("supports keyboard preview and Open in without an inline download control", async () => {
    const user = userEvent.setup();
    const preview = vi.fn();
    const action = createAction();
    render(<ChatPanelFile fileName="Apple.pdf" onPreview={preview} openIn={action} />);
    expect(action.listApplications).not.toHaveBeenCalled();
    await user.tab();
    expect(screen.getByRole("button", { name: "Preview Apple.pdf" })).toHaveFocus();
    await user.keyboard("{Enter} ");
    expect(preview).toHaveBeenCalledTimes(2);

    await user.click(screen.getByRole("button", { name: "Open in" }));
    await user.click(await screen.findByRole("menuitem", { name: "Preview" }));
    await waitFor(() => expect(action.openApplication).toHaveBeenCalledOnce());
    expect(action.openApplication).toHaveBeenCalledWith(
      "preview",
      expect.any(AbortSignal)
    );
    expect(preview).toHaveBeenCalledTimes(2);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Download" })).not.toBeInTheDocument();
  });

  it("loads applications only while open and ignores a late response after dismissal", async () => {
    const user = userEvent.setup();
    let resolveList!: (applications: (typeof application)[]) => void;
    let firstSignal: AbortSignal | undefined;
    const action = createAction();
    action.listApplications = vi
      .fn()
      .mockImplementationOnce((signal?: AbortSignal) => {
        firstSignal = signal;
        return new Promise((resolve) => {
          resolveList = resolve;
        });
      })
      .mockResolvedValue([{ id: "reader", name: "Reader" }]);
    render(<ChatPanelFile fileName="Apple.pdf" openIn={action} />);
    await user.click(screen.getByRole("button", { name: "Open in" }));
    expect(
      await screen.findByRole("menuitem", { name: "Finding apps…" })
    ).toBeInTheDocument();
    await user.keyboard("{Escape}");
    expect(firstSignal?.aborted).toBe(true);
    await user.click(screen.getByRole("button", { name: "Open in" }));
    expect(await screen.findByRole("menuitem", { name: "Reader" })).toBeInTheDocument();
    await act(async () => resolveList([application]));
    expect(screen.queryByRole("menuitem", { name: "Preview" })).not.toBeInTheDocument();
  });

  it("retries discovery explicitly and keeps Finder available for an empty app list", async () => {
    const user = userEvent.setup();
    const action = createAction();
    action.listApplications = vi
      .fn()
      .mockRejectedValueOnce(new Error("OS unavailable"))
      .mockResolvedValue([]);
    render(<ChatPanelFile fileName="Apple.pdf" openIn={action} />);
    await user.click(screen.getByRole("button", { name: "Open in" }));
    expect(
      await screen.findByRole("menuitem", { name: "Could not load apps" })
    ).toBeInTheDocument();
    await user.click(screen.getByRole("menuitem", { name: "Try again" }));
    expect(
      await screen.findByRole("menuitem", { name: "No compatible apps found" })
    ).toBeInTheDocument();
    expect(action.listApplications).toHaveBeenCalledTimes(2);
    await user.click(screen.getByRole("menuitem", { name: "Show in Finder" }));
    await waitFor(() => expect(action.reveal!.run).toHaveBeenCalledOnce());
  });

  it("does not cancel a selected app when the menu closes, but cancels on source change", async () => {
    const user = userEvent.setup();
    let signal: AbortSignal | undefined;
    let finish!: () => void;
    const action = createAction();
    action.openApplication = vi.fn((_id, nextSignal) => {
      signal = nextSignal;
      return new Promise<void>((resolve) => {
        finish = resolve;
      });
    });
    const { rerender } = render(<ChatPanelFile fileName="Apple.pdf" openIn={action} />);
    await user.click(screen.getByRole("button", { name: "Open in" }));
    await user.click(await screen.findByRole("menuitem", { name: "Preview" }));
    await waitFor(() => expect(action.openApplication).toHaveBeenCalledOnce());
    expect(signal?.aborted).toBe(false);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Opening…" })).toBeDisabled();
    const nextAction = createAction();
    rerender(<ChatPanelFile fileName="Other.pdf" openIn={nextAction} />);
    expect(signal?.aborted).toBe(true);
    await act(async () => finish());
    expect(screen.getByRole("button", { name: "Open in" })).toBeEnabled();
    expect(nextAction.openApplication).not.toHaveBeenCalled();
  });

  it("shows an open failure and permits another explicit selection", async () => {
    const user = userEvent.setup();
    const action = createAction();
    action.openApplication = vi
      .fn()
      .mockRejectedValueOnce(new Error("File missing"))
      .mockResolvedValue(undefined);
    render(<ChatPanelFile fileName="Apple.pdf" openIn={action} />);
    await user.click(screen.getByRole("button", { name: "Open in" }));
    await user.click(await screen.findByRole("menuitem", { name: "Preview" }));
    expect(await screen.findByText("Could not open the file.")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Open in" }));
    await user.click(await screen.findByRole("menuitem", { name: "Preview" }));
    await waitFor(() =>
      expect(screen.queryByText("Could not open the file.")).not.toBeInTheDocument()
    );
    expect(action.openApplication).toHaveBeenCalledTimes(2);
  });

  it("aborts an outstanding app operation when the card unmounts", async () => {
    const user = userEvent.setup();
    let signal: AbortSignal | undefined;
    const action = createAction();
    action.openApplication = vi.fn((_id, nextSignal) => {
      signal = nextSignal;
      return new Promise<void>(() => {});
    });
    const { unmount } = render(<ChatPanelFile fileName="Apple.pdf" openIn={action} />);
    await user.click(screen.getByRole("button", { name: "Open in" }));
    await user.click(await screen.findByRole("menuitem", { name: "Preview" }));
    await waitFor(() => expect(action.openApplication).toHaveBeenCalledOnce());
    unmount();
    expect(signal?.aborted).toBe(true);
  });
});

const firstApplication = {
  id: "reader",
  name: "Reader",
  iconDataUrl:
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6SAAAAABJRU5ErkJggg==",
  isDefault: false,
};
const secondApplication = {
  ...application,
  iconDataUrl:
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
};
const createSplitAction = (): ChatPanelFileOpenInAction => ({
  ...createAction(),
  listApplications: vi.fn().mockResolvedValue([firstApplication, secondApplication]),
});

describe("active preview split Open control", () => {
  it("preloads the first application icon and opens that exact first app directly", async () => {
    const user = userEvent.setup();
    const action = createSplitAction();
    render(<ChatPanelFileOpenInMenu action={action} presentation="split" />);
    const open = screen.getByRole("button", { name: "Open" });
    await waitFor(() => expect(open).toBeEnabled());
    expect(action.listApplications).toHaveBeenCalledOnce();
    expect(open.querySelector("img")).toHaveAttribute(
      "src",
      firstApplication.iconDataUrl
    );
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    // The OS list owns ordering; a later isDefault flag does not replace its first item.
    await user.click(open);
    await waitFor(() =>
      expect(action.openApplication).toHaveBeenCalledWith(
        "reader",
        expect.any(AbortSignal)
      )
    );
    expect(action.openApplication).toHaveBeenCalledOnce();
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("uses a separate arrow for application choices and keeps the folder action below them", async () => {
    const user = userEvent.setup();
    const action = createSplitAction();
    render(<ChatPanelFileOpenInMenu action={action} presentation="split" />);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Open" })).toBeEnabled()
    );
    await user.click(screen.getByRole("button", { name: "Choose application" }));
    expect(await screen.findByRole("menuitem", { name: "Reader" })).toBeVisible();
    expect(screen.getAllByRole("menuitem").map((item) => item.textContent)).toEqual([
      "Reader",
      "Preview",
      "Reveal in Folder",
    ]);
    expect(action.openApplication).not.toHaveBeenCalled();
    expect(action.listApplications).toHaveBeenCalledOnce();
    await user.click(screen.getByRole("menuitem", { name: "Preview" }));
    await waitFor(() =>
      expect(action.openApplication).toHaveBeenCalledWith(
        "preview",
        expect.any(AbortSignal)
      )
    );
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Open" })).toBeEnabled()
    );
    await user.click(screen.getByRole("button", { name: "Choose application" }));
    await user.click(screen.getByRole("menuitem", { name: "Reveal in Folder" }));
    await waitFor(() =>
      expect(action.reveal!.run).toHaveBeenCalledWith(expect.any(AbortSignal))
    );
    expect(action.openApplication).toHaveBeenCalledOnce();
    expect(action.listApplications).toHaveBeenCalledOnce();
  });

  it("immediately clears the previous source's app while the next source is loading", async () => {
    const user = userEvent.setup();
    const action = createSplitAction();
    const nextAction = createSplitAction();
    let resolveNext!: (apps: (typeof secondApplication)[]) => void;
    nextAction.listApplications = vi.fn(
      () =>
        new Promise<(typeof secondApplication)[]>((resolve) => {
          resolveNext = resolve;
        })
    );
    const { rerender } = render(
      <ChatPanelFileOpenInMenu action={action} presentation="split" />
    );
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Open" })).toBeEnabled()
    );
    expect(
      screen.getByRole("button", { name: "Open" }).querySelector("img")
    ).toHaveAttribute("src", firstApplication.iconDataUrl);
    rerender(<ChatPanelFileOpenInMenu action={nextAction} presentation="split" />);
    const open = screen.getByRole("button", { name: "Open" });
    expect(open).toBeDisabled();
    expect(open.querySelector("img")).toBeNull();
    await waitFor(() => expect(nextAction.listApplications).toHaveBeenCalledOnce());
    await act(async () => resolveNext([secondApplication]));
    expect(open.querySelector("img")).toHaveAttribute(
      "src",
      secondApplication.iconDataUrl
    );
    await user.click(open);
    await waitFor(() =>
      expect(nextAction.openApplication).toHaveBeenCalledWith(
        "preview",
        expect.any(AbortSignal)
      )
    );
    expect(action.openApplication).not.toHaveBeenCalled();
  });

  it("aborts old-source discovery and ignores its late response after the new source is ready", async () => {
    const user = userEvent.setup();
    const action = createSplitAction();
    let resolveOld!: (apps: (typeof firstApplication)[]) => void;
    let oldSignal: AbortSignal | undefined;
    action.listApplications = vi.fn((signal) => {
      oldSignal = signal;
      return new Promise<(typeof firstApplication)[]>((resolve) => {
        resolveOld = resolve;
      });
    });
    const nextAction = createSplitAction();
    nextAction.listApplications = vi.fn().mockResolvedValue([secondApplication]);
    const { rerender } = render(
      <ChatPanelFileOpenInMenu action={action} presentation="split" />
    );
    await waitFor(() => expect(action.listApplications).toHaveBeenCalledOnce());
    rerender(<ChatPanelFileOpenInMenu action={nextAction} presentation="split" />);
    expect(oldSignal?.aborted).toBe(true);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Open" })).toBeEnabled()
    );
    await act(async () => resolveOld([firstApplication]));
    const open = screen.getByRole("button", { name: "Open" });
    expect(open.querySelector("img")).toHaveAttribute(
      "src",
      secondApplication.iconDataUrl
    );
    await user.click(open);
    await waitFor(() =>
      expect(nextAction.openApplication).toHaveBeenCalledWith(
        "preview",
        expect.any(AbortSignal)
      )
    );
    expect(action.openApplication).not.toHaveBeenCalled();
  });

  it("allows dismissing the menu and explicitly retrying failed discovery without opening a file", async () => {
    const user = userEvent.setup();
    const action = createSplitAction();
    action.listApplications = vi
      .fn()
      .mockRejectedValueOnce(new Error("OS unavailable"))
      .mockResolvedValue([firstApplication]);
    render(<ChatPanelFileOpenInMenu action={action} presentation="split" />);
    await waitFor(() => expect(action.listApplications).toHaveBeenCalledOnce());
    const open = screen.getByRole("button", { name: "Open" });
    await user.click(screen.getByRole("button", { name: "Choose application" }));
    expect(
      await screen.findByRole("menuitem", { name: "Could not load apps" })
    ).toBeVisible();
    expect(open).toBeDisabled();
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(action.openApplication).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Choose application" }));
    await user.click(screen.getByRole("menuitem", { name: "Try again" }));
    expect(await screen.findByRole("menuitem", { name: "Reader" })).toBeVisible();
    await user.keyboard("{Escape}");
    expect(screen.getByRole("button", { name: "Open" })).toBeEnabled();
    expect(action.listApplications).toHaveBeenCalledTimes(2);
    expect(action.openApplication).not.toHaveBeenCalled();
  });

  it("shows a direct-open failure and retries only on another explicit Open press", async () => {
    const user = userEvent.setup();
    const action = createSplitAction();
    action.openApplication = vi
      .fn()
      .mockRejectedValueOnce(new Error("App unavailable"))
      .mockResolvedValue(undefined);
    render(<ChatPanelFileOpenInMenu action={action} presentation="split" />);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Open" })).toBeEnabled()
    );
    await user.click(screen.getByRole("button", { name: "Open" }));
    expect(await screen.findByText("Could not open the file.")).toBeVisible();
    expect(action.openApplication).toHaveBeenCalledOnce();
    await user.click(screen.getByRole("button", { name: "Open" }));
    await waitFor(() =>
      expect(screen.queryByText("Could not open the file.")).not.toBeInTheDocument()
    );
    expect(action.openApplication).toHaveBeenCalledTimes(2);
    expect(action.listApplications).toHaveBeenCalledOnce();
  });
});
