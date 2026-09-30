import userEvent from "@testing-library/user-event";
import type { SideChatShortcut } from "@comma/native-bridge";
import { render, screen, waitFor } from "@comma/test-utils/render";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  CommaSideChatShortcutProvider,
  useCommaSideChatShortcut,
} from "../components/commaSideChatShortcut";
import {
  CommaWebClientSettingsProvider,
  commaClientSettingsStorageKey,
} from "../components/commaClientSettings";
import { legacyCommaSideChatShortcutStorageKey } from "../components/readLegacyCommaClientSettings";
import { updateNativeSideChatShortcut } from "../runtime-side-chat/nativeSideChat";

vi.mock("../runtime-side-chat/nativeSideChat", () => ({
  isElectronSideChatRuntime: vi.fn(() => true),
  updateNativeSideChatShortcut: vi.fn(async (shortcut) => shortcut),
}));

const mockedUpdateNativeSideChatShortcut = vi.mocked(updateNativeSideChatShortcut);

const renderShortcutProvider = (children: React.ReactNode) =>
  render(
    <CommaWebClientSettingsProvider>
      <CommaSideChatShortcutProvider>{children}</CommaSideChatShortcutProvider>
    </CommaWebClientSettingsProvider>
  );

const readStoredShortcut = () =>
  JSON.parse(localStorage.getItem(commaClientSettingsStorageKey)!).sideChatShortcut;

function Consumer() {
  const { setShortcut, shortcut } = useCommaSideChatShortcut();
  return (
    <button
      onClick={() =>
        setShortcut({
          key: "k",
          modifiers: {
            alt: false,
            control: true,
            meta: false,
            shift: true,
          },
        })
      }
      type="button"
    >
      {shortcut?.key ?? "unset"}
    </button>
  );
}

function ConcurrentConsumer() {
  const { registrationFailed, registrationPending, setShortcut, shortcut } =
    useCommaSideChatShortcut();
  return (
    <>
      <output aria-label="Current shortcut">{shortcut?.key ?? "unset"}</output>
      <output aria-label="Registration state">
        {registrationPending ? "pending" : registrationFailed ? "failed" : "idle"}
      </output>
      <button onClick={() => void setShortcut(null)} type="button">
        Clear
      </button>
      <button onClick={() => void setShortcut(shortcutFor("k"))} type="button">
        Set K
      </button>
      <button onClick={() => void setShortcut(shortcutFor("l"))} type="button">
        Set L
      </button>
    </>
  );
}

describe("CommaSideChatShortcutProvider", () => {
  it("persists a cleared shortcut and keeps it clear when a later registration fails", async () => {
    const first = renderShortcutProvider(<ConcurrentConsumer />);
    await waitFor(() =>
      expect(screen.getByLabelText("Registration state")).toHaveTextContent("idle")
    );
    await userEvent.click(screen.getByRole("button", { name: "Clear" }));
    await waitFor(() => expect(readStoredShortcut()).toBeNull());
    expect(mockedUpdateNativeSideChatShortcut).toHaveBeenLastCalledWith(null);
    first.unmount();
    renderShortcutProvider(<ConcurrentConsumer />);
    await waitFor(() =>
      expect(screen.getByLabelText("Registration state")).toHaveTextContent("idle")
    );
    expect(screen.getByLabelText("Current shortcut")).toHaveTextContent("unset");
    mockedUpdateNativeSideChatShortcut.mockRejectedValueOnce(new Error("Occupied"));
    await userEvent.click(screen.getByRole("button", { name: "Set K" }));
    await waitFor(() =>
      expect(screen.getByLabelText("Registration state")).toHaveTextContent("failed")
    );
    expect(readStoredShortcut()).toBeNull();
    expect(screen.getByLabelText("Current shortcut")).toHaveTextContent("unset");
  });

  afterEach(() => {
    localStorage.clear();
    vi.clearAllMocks();
  });

  it("defaults to Control-Z and synchronizes it to the native helper", async () => {
    renderShortcutProvider(<Consumer />);

    expect(screen.getByRole("button", { name: "z" })).toBeInTheDocument();
    await waitFor(() => {
      expect(mockedUpdateNativeSideChatShortcut).toHaveBeenCalledWith({
        key: "z",
        modifiers: {
          alt: false,
          control: true,
          meta: false,
          shift: false,
        },
      });
    });
    expect(readStoredShortcut()).toEqual(shortcutForDefault());
  });

  it("persists changes and sends the replacement shortcut", async () => {
    renderShortcutProvider(<Consumer />);

    await userEvent.click(screen.getByRole("button", { name: "z" }));

    expect(screen.getByRole("button", { name: "k" })).toBeInTheDocument();
    expect(readStoredShortcut()).toEqual({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: true,
      },
    });
    await waitFor(() => {
      expect(mockedUpdateNativeSideChatShortcut).toHaveBeenLastCalledWith({
        key: "k",
        modifiers: {
          alt: false,
          control: true,
          meta: false,
          shift: true,
        },
      });
    });
  });

  it("applies an acknowledged serialized update when a later update is rejected", async () => {
    renderShortcutProvider(<ConcurrentConsumer />);
    await waitFor(() => {
      expect(mockedUpdateNativeSideChatShortcut).toHaveBeenCalledOnce();
    });

    const firstUpdate = deferred<SideChatShortcut>();
    const secondUpdate = deferred<SideChatShortcut>();
    mockedUpdateNativeSideChatShortcut
      .mockImplementationOnce(() => firstUpdate.promise)
      .mockImplementationOnce(() => secondUpdate.promise);

    await userEvent.click(screen.getByRole("button", { name: "Set K" }));
    await userEvent.click(screen.getByRole("button", { name: "Set L" }));
    firstUpdate.resolve(shortcutFor("k"));

    await waitFor(() => {
      expect(
        screen.getByRole("status", { name: "Current shortcut" })
      ).toHaveTextContent("k");
    });
    secondUpdate.reject(new Error("The L shortcut is unavailable."));

    await waitFor(() => {
      expect(
        screen.getByRole("status", { name: "Registration state" })
      ).toHaveTextContent("failed");
    });
    expect(screen.getByRole("status", { name: "Current shortcut" })).toHaveTextContent(
      "k"
    );
    expect(readStoredShortcut()).toEqual(shortcutFor("k"));
  });

  it("restores the last acknowledged value when initial sync and a later update fail", async () => {
    localStorage.setItem(
      legacyCommaSideChatShortcutStorageKey,
      JSON.stringify(shortcutFor("k"))
    );
    const initialSync = deferred<SideChatShortcut>();
    const laterUpdate = deferred<SideChatShortcut>();
    mockedUpdateNativeSideChatShortcut
      .mockImplementationOnce(() => initialSync.promise)
      .mockImplementationOnce(() => laterUpdate.promise);

    renderShortcutProvider(<ConcurrentConsumer />);
    expect(screen.getByRole("status", { name: "Current shortcut" })).toHaveTextContent(
      "k"
    );
    await userEvent.click(screen.getByRole("button", { name: "Set L" }));

    initialSync.reject(new Error("The stored K shortcut is unavailable."));
    laterUpdate.reject(new Error("The L shortcut is unavailable."));

    await waitFor(() => {
      expect(
        screen.getByRole("status", { name: "Current shortcut" })
      ).toHaveTextContent("z");
    });
    expect(
      screen.getByRole("status", { name: "Registration state" })
    ).toHaveTextContent("failed");
    expect(readStoredShortcut()).toEqual(shortcutForDefault());
  });
});

function shortcutFor(key: "k" | "l"): SideChatShortcut {
  return {
    key,
    modifiers: {
      alt: false,
      control: true,
      meta: false,
      shift: false,
    },
  };
}

function shortcutForDefault(): SideChatShortcut {
  return {
    key: "z",
    modifiers: {
      alt: false,
      control: true,
      meta: false,
      shift: false,
    },
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}
