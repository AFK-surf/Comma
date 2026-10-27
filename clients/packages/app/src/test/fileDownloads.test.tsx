import type { CommaLocale } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { chatAttachmentUploadMaxBytes } from "@comma/chat-contract";
import type { FilesSaveDownloadResult } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { Toaster, toast } from "@comma/ui/components/toast";
import { type ChatPanelMediaDownloadResult } from "@comma/ui/components/chat-panel";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CoreError } from "@comma/core-client";
import {
  createFileDownloadCapability,
  downloadFile,
  type FileDownloadRequest,
} from "../runtime-files/fileDownloads";

// `TextEncoder` answers with a typed array from Node's realm while a jsdom
// `Blob` reads back through the document's; `Uint8Array.from` puts the fixture
// on the same constructor the module builds its payload with.
const reportBytes = Uint8Array.from(new TextEncoder().encode("quarterly figures"));
const reportBlob = () => new Blob([reportBytes], { type: "text/csv" });
const resolveReport = async () => reportBlob();

/**
 * Main answers with the name the file actually landed under — here a
 * collision-suffixed one, so every assertion on the toast proves the user is
 * told where the file really is rather than what was asked for.
 */
const savedReport: Extract<FilesSaveDownloadResult, { status: "saved" }> = {
  downloadRef: "dnl1_9Sm2XQ0pW7hVn4Lr8Tc6Jd1Fb3Zy5Ku0Ae7Ri2Ot4Gx",
  fileName: "report (1).csv",
  status: "saved",
};

function renderToasts(locale: CommaLocale = "en") {
  return render(
    <CommaI18nProvider locale={locale}>
      <Toaster />
    </CommaI18nProvider>
  );
}

async function runDownload(request: FileDownloadRequest, locale: CommaLocale = "en") {
  let result: ChatPanelMediaDownloadResult | undefined;
  await act(async () => {
    result = await downloadFile(request, { locale });
  });
  return result;
}

describe("file downloads", () => {
  afterEach(() => {
    toast.dismissAll();
    document.querySelectorAll("iframe").forEach((frame) => frame.remove());
    Reflect.deleteProperty(globalThis, "commaNative");
    vi.restoreAllMocks();
  });

  it("saves the resolved bytes through Main and names the file Main wrote", async () => {
    const saveDownload = vi.fn(async () => savedReport);
    installNativeBridgeMock({
      files: { saveDownload },
      os: "macos",
      platform: "electron",
    });
    renderToasts();

    await expect(
      runDownload({ fileName: "report.csv", resolve: resolveReport })
    ).resolves.toEqual({ status: "success" });

    expect(saveDownload).toHaveBeenCalledWith({
      content: reportBytes,
      fileName: "report.csv",
    });
    expect(await screen.findByText("Download complete")).toBeInTheDocument();
    expect(
      screen.getByText("report (1).csv was saved to your Downloads folder.")
    ).toBeInTheDocument();
    expect(
      screen.queryByText("report.csv was saved to your Downloads folder.")
    ).not.toBeInTheDocument();
  });

  it("preserves an empty file through the Electron adapter", async () => {
    const saveDownload = vi.fn(async () => savedReport);
    installNativeBridgeMock({
      files: { saveDownload },
      os: "macos",
      platform: "electron",
    });
    renderToasts();

    await expect(
      runDownload({
        fileName: "empty.txt",
        resolve: async () => new Blob([]),
      })
    ).resolves.toEqual({ status: "success" });

    expect(saveDownload).toHaveBeenCalledWith({
      content: new Uint8Array(),
      fileName: "empty.txt",
    });
  });

  it.each(["electron", "web"] as const)(
    "rejects a response above the shared ceiling before the %s save adapter",
    async (platform) => {
      const saveDownload = vi.fn(async () => savedReport);
      installNativeBridgeMock({
        files: { saveDownload },
        os: "macos",
        platform,
      });
      const createObjectUrl = vi.spyOn(URL, "createObjectURL");
      renderToasts();

      await expect(
        runDownload({
          fileName: "over-limit.bin",
          resolve: async () =>
            new Blob([new Uint8Array(chatAttachmentUploadMaxBytes + 1)]),
        })
      ).resolves.toEqual({ code: "too-large", retryable: false, status: "error" });

      expect(saveDownload).not.toHaveBeenCalled();
      expect(createObjectUrl).not.toHaveBeenCalled();
      expect(await screen.findByText("Download failed")).toBeInTheDocument();
      expect(
        screen.getByText(
          "over-limit.bin exceeds the 10 MB download limit. Ask the sender for a smaller file."
        )
      ).toBeInTheDocument();
    }
  );

  it("turns the toast's actions into reveal and open calls for the saved file", async () => {
    const revealDownload = vi.fn(async () => ({ status: "revealed" as const }));
    const openDownload = vi.fn(async () => ({ status: "opened" as const }));
    installNativeBridgeMock({
      files: {
        openDownload,
        revealDownload,
        saveDownload: vi.fn(async () => savedReport),
      },
      os: "macos",
      platform: "electron",
    });
    renderToasts();

    await runDownload({ fileName: "report.csv", resolve: resolveReport });
    expect(await screen.findByText("Download complete")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Reveal in Finder" }));
    await waitFor(() =>
      expect(revealDownload).toHaveBeenCalledWith({
        downloadRef: savedReport.downloadRef,
      })
    );

    fireEvent.click(screen.getByRole("button", { name: "Open file" }));
    await waitFor(() =>
      expect(openDownload).toHaveBeenCalledWith({
        downloadRef: savedReport.downloadRef,
      })
    );
  });

  it("names the file manager the desktop actually ships", async () => {
    installNativeBridgeMock({
      files: { saveDownload: vi.fn(async () => savedReport) },
      os: "windows",
      platform: "electron",
    });
    renderToasts();

    await runDownload({ fileName: "report.csv", resolve: resolveReport });

    expect(
      await screen.findByRole("button", { name: "Show in Folder" })
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Reveal in Finder" })
    ).not.toBeInTheDocument();
  });

  it.each([
    {
      name: "says the file has moved when it can no longer be revealed",
      refused: { revealDownload: async () => ({ status: "unavailable" as const }) },
      button: "Reveal in Finder",
      title: "That file has moved",
      body: "report (1).csv is no longer in your Downloads folder.",
    },
    {
      name: "says the file could not be opened when the system refuses it",
      refused: { openDownload: async () => ({ status: "unavailable" as const }) },
      button: "Open file",
      title: "Could not open the file",
      body: "report (1).csv could not be opened on this device.",
    },
  ])("$name", async ({ body, button, refused, title }) => {
    installNativeBridgeMock({
      files: {
        ...refused,
        saveDownload: vi.fn(async () => savedReport),
      },
      os: "macos",
      platform: "electron",
    });
    renderToasts();

    await runDownload({ fileName: "report.csv", resolve: resolveReport });
    expect(await screen.findByText("Download complete")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: button }));

    expect(await screen.findByText(title)).toBeInTheDocument();
    expect(screen.getByText(body)).toBeInTheDocument();
    expect(screen.queryByText("Download complete")).not.toBeInTheDocument();
  });

  it.each([
    {
      name: "reports a save Main declines as a retryable failure",
      saveDownload: async () => ({ status: "unavailable" as const }),
    },
    {
      name: "reports a save that throws as the same retryable failure",
      saveDownload: async (): Promise<never> => {
        throw new Error("the disk is full");
      },
    },
  ])("$name", async ({ saveDownload }) => {
    installNativeBridgeMock({
      files: { saveDownload: vi.fn(saveDownload) },
      os: "macos",
      platform: "electron",
    });
    renderToasts();

    await expect(
      runDownload({ fileName: "report.csv", resolve: resolveReport })
    ).resolves.toEqual({ code: "unknown", retryable: true, status: "error" });

    expect(await screen.findByText("Download failed")).toBeInTheDocument();
    expect(
      screen.getByText("report.csv could not be saved to your Downloads folder.")
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Reveal in Finder" })
    ).not.toBeInTheDocument();
  });

  it("never reaches Main when the bytes cannot be resolved", async () => {
    const saveDownload = vi.fn(async () => savedReport);
    installNativeBridgeMock({
      files: { saveDownload },
      os: "macos",
      platform: "electron",
    });
    renderToasts();

    await expect(
      runDownload({
        fileName: "report.csv",
        resolve: async () => {
          throw new Error("the transport refused the request");
        },
      })
    ).resolves.toEqual({ code: "network", retryable: true, status: "error" });

    expect(saveDownload).not.toHaveBeenCalled();
    expect(await screen.findByText("Download failed")).toBeInTheDocument();
    expect(
      screen.getByText(
        "report.csv could not be retrieved. The network or service may be unavailable; try again shortly."
      )
    ).toBeInTheDocument();
  });

  it.each([
    [
      404,
      "not_found",
      "not-found",
      false,
      "report.csv is unavailable. Ask the sender to attach the file again.",
    ],
    [
      401,
      "unauthorized",
      "unauthorized",
      false,
      "Sign in again to download report.csv.",
    ],
    [
      403,
      "forbidden",
      "forbidden",
      false,
      "You do not have access to report.csv. Check your access to this conversation and file.",
    ],
    [
      409,
      "session_changed",
      "unauthorized",
      false,
      "Sign in again to download report.csv.",
    ],
    [
      413,
      "too_large",
      "too-large",
      false,
      "report.csv exceeds the 10 MB download limit. Ask the sender for a smaller file.",
    ],
    [
      400,
      "invalid_attachment",
      "unsupported",
      false,
      "report.csv could not be downloaded. Ask the sender to attach the file again.",
    ],
    [
      503,
      "workspace_unavailable",
      "network",
      true,
      "report.csv could not be retrieved. The network or service may be unavailable; try again shortly.",
    ],
  ] as const)(
    "preserves HTTP %s as a retrieval failure without attempting a native save",
    async (httpStatus, error, code, retryable, description) => {
      const saveDownload = vi.fn(async () => savedReport);
      installNativeBridgeMock({
        files: { saveDownload },
        platform: "electron",
        os: "macos",
      });
      renderToasts();

      await expect(
        runDownload({
          fileName: "report.csv",
          resolve: () =>
            Promise.reject(
              new CoreError({ code: error, message: error, status: httpStatus })
            ),
        })
      ).resolves.toEqual({ status: "error", code, retryable, httpStatus });
      expect(saveDownload).not.toHaveBeenCalled();
      expect(await screen.findByText(description)).toBeInTheDocument();
      expect(
        screen.queryByText(/could not be saved to your Downloads folder/)
      ).not.toBeInTheDocument();
    }
  );

  it("hands the file to the browser and offers no actions the web cannot perform", async () => {
    installNativeBridgeMock({ platform: "web" });
    const createObjectUrl = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:saved-report");
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined);
    const clickAnchor = vi
      .spyOn(HTMLAnchorElement.prototype, "click")
      .mockImplementation(() => undefined);
    renderToasts();

    const blob = reportBlob();
    await expect(
      runDownload({ fileName: "report.csv", resolve: async () => blob })
    ).resolves.toEqual({ status: "started" });

    expect(createObjectUrl).toHaveBeenCalledWith(blob);
    expect(clickAnchor).toHaveBeenCalledOnce();
    const anchor = clickAnchor.mock.instances[0] as HTMLAnchorElement;
    expect(anchor.download).toBe("report.csv");
    expect(anchor.href).toBe("blob:saved-report");
    expect(anchor.isConnected).toBe(false);

    expect(await screen.findByText("Download started")).toBeInTheDocument();
    // The browser owns the destination here, so the copy must not name one.
    expect(
      screen.getByText("Check your browser for the progress of report.csv.")
    ).toBeInTheDocument();
    expect(
      screen.queryByText("report.csv was saved to your Downloads folder.")
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Reveal in Finder" })
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Show in Folder" })
    ).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Open file" })).not.toBeInTheDocument();
  });

  it("starts a linked browser download even when pop-ups are blocked", async () => {
    installNativeBridgeMock({ platform: "web" });
    vi.spyOn(window, "open").mockReturnValue(null);
    const resolve = vi.fn(async () => reportBlob());
    renderToasts();

    await expect(
      runDownload({
        fileName: "deck.pdf",
        resolve,
        link: async () => "http://localhost/files/deck.pdf",
      })
    ).resolves.toEqual({ status: "started" });
    expect(resolve).not.toHaveBeenCalled();
    expect(await screen.findByText("Download started")).toBeInTheDocument();
  });

  it("gives each linked download a frame of its own, so a later one never replaces an earlier one", async () => {
    installNativeBridgeMock({ platform: "web" });
    renderToasts();
    const urls = [1, 2, 3, 4, 5].map((n) => `http://localhost/files/report-${n}.pdf`);

    for (const url of urls)
      await expect(
        runDownload({
          fileName: "report.pdf",
          resolve: resolveReport,
          link: async () => url,
        })
      ).resolves.toEqual({ status: "started" });

    const frames = [...document.querySelectorAll("iframe")];
    // The oldest is let go once there are more than four; the rest keep their own navigation.
    expect(frames.map((frame) => frame.src)).toEqual(urls.slice(1));
    expect(frames.every((frame) => frame.hidden)).toBe(true);
    expect(
      frames.every((frame) => frame.getAttribute("sandbox") === "allow-downloads")
    ).toBe(true);
  });

  it("lets the reader retry when the browser cannot start the download", async () => {
    installNativeBridgeMock({ platform: "web" });
    vi.spyOn(HTMLIFrameElement.prototype, "src", "set").mockImplementation(() => {
      throw new DOMException("Navigation denied", "SecurityError");
    });
    renderToasts();

    await expect(
      runDownload({
        fileName: "report.pdf",
        resolve: resolveReport,
        link: async () => "http://localhost/files/report.pdf",
      })
    ).resolves.toMatchObject({ status: "error", retryable: true });
    expect(await screen.findByText("Download failed")).toBeInTheDocument();
    expect(
      screen.getByText("The browser could not start downloading report.pdf. Try again.")
    ).toBeInTheDocument();
    expect(screen.queryByText("Download started")).not.toBeInTheDocument();
  });

  it("preserves the retrieval error when the browser link cannot be minted", async () => {
    installNativeBridgeMock({ platform: "web" });
    renderToasts();

    await expect(
      runDownload({
        fileName: "deck.pdf",
        resolve: resolveReport,
        link: async () => {
          throw new CoreError({
            code: "attachment_not_found",
            message: "gone",
            status: 404,
          });
        },
      })
    ).resolves.toMatchObject({ status: "error", code: "not-found" });
    expect(
      await screen.findByText(
        "deck.pdf is unavailable. Ask the sender to attach the file again."
      )
    ).toBeInTheDocument();
  });

  it("reads a file with no link to it a part at a time, at any size, and hands it to the browser", async () => {
    installNativeBridgeMock({ platform: "web" });
    const createObjectUrl = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:station-file");
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined);
    const clickAnchor = vi
      .spyOn(HTMLAnchorElement.prototype, "click")
      .mockImplementation(() => undefined);
    const resolve = vi.fn(async () => reportBlob());
    // Larger than a whole read may be.
    const big = new Blob([new Uint8Array(chatAttachmentUploadMaxBytes + 1)]);
    renderToasts();

    await expect(
      runDownload({
        fileName: "run.mp4",
        resolve,
        link: async () => {
          throw new CoreError({ code: "no_link", message: "A file on a machine." });
        },
        parts: async () => big,
      })
    ).resolves.toEqual({ status: "started" });
    expect(resolve).not.toHaveBeenCalled();
    expect(createObjectUrl).toHaveBeenCalledWith(big);
    expect((clickAnchor.mock.instances[0] as HTMLAnchorElement).download).toBe(
      "run.mp4"
    );
  });

  it("drives the same path from a chat card's download capability", async () => {
    const saveDownload = vi.fn(async () => savedReport);
    installNativeBridgeMock({
      files: { saveDownload },
      os: "macos",
      platform: "electron",
    });
    renderToasts();

    const capability = createFileDownloadCapability(resolveReport, { locale: "en" });
    let result: ChatPanelMediaDownloadResult | undefined;
    await act(async () => {
      result = await capability.execute({ fileName: "report.csv", kind: "file" });
    });

    expect(result).toEqual({ status: "success" });
    expect(saveDownload).toHaveBeenCalledWith({
      content: reportBytes,
      fileName: "report.csv",
    });
    expect(await screen.findByText("Download complete")).toBeInTheDocument();
  });

  it("reports a completed download in Simplified Chinese", async () => {
    installNativeBridgeMock({
      files: { saveDownload: vi.fn(async () => savedReport) },
      os: "macos",
      platform: "electron",
    });
    renderToasts("zh-CN");

    await runDownload({ fileName: "report.csv", resolve: resolveReport }, "zh-CN");

    expect(await screen.findByText("下载完成")).toBeInTheDocument();
    expect(screen.getByText("report (1).csv 已保存到下载文件夹。")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "在访达中显示" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "打开文件" })).toBeInTheDocument();
    expect(screen.queryByText("Download complete")).not.toBeInTheDocument();
  });
});
