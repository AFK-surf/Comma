import type { CommaLocale } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { chatAttachmentUploadMaxBytes } from "@comma/chat-contract";
import type { FilesSaveDownloadResult } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { Toaster, toast, type ChatPanelMediaDownloadResult } from "@comma/ui";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createCommaApi } from "../api";
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

  it("says the file has moved when it can no longer be revealed", async () => {
    installNativeBridgeMock({
      files: {
        revealDownload: vi.fn(async () => ({ status: "unavailable" as const })),
        saveDownload: vi.fn(async () => savedReport),
      },
      os: "macos",
      platform: "electron",
    });
    renderToasts();

    await runDownload({ fileName: "report.csv", resolve: resolveReport });
    expect(await screen.findByText("Download complete")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Reveal in Finder" }));

    expect(await screen.findByText("That file has moved")).toBeInTheDocument();
    expect(
      screen.getByText("report (1).csv is no longer in your Downloads folder.")
    ).toBeInTheDocument();
    expect(screen.queryByText("Download complete")).not.toBeInTheDocument();
  });

  it("says the file could not be opened when the system refuses it", async () => {
    installNativeBridgeMock({
      files: {
        openDownload: vi.fn(async () => ({ status: "unavailable" as const })),
        saveDownload: vi.fn(async () => savedReport),
      },
      os: "macos",
      platform: "electron",
    });
    renderToasts();

    await runDownload({ fileName: "report.csv", resolve: resolveReport });
    expect(await screen.findByText("Download complete")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Open file" }));

    expect(await screen.findByText("Could not open the file")).toBeInTheDocument();
    expect(
      screen.getByText("report (1).csv could not be opened on this device.")
    ).toBeInTheDocument();
    expect(screen.queryByText("Download complete")).not.toBeInTheDocument();
  });

  it("reports a save Main declines as a retryable failure", async () => {
    installNativeBridgeMock({
      files: { saveDownload: vi.fn(async () => ({ status: "unavailable" as const })) },
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

  it("reports a save that throws as the same retryable failure", async () => {
    installNativeBridgeMock({
      files: {
        saveDownload: vi.fn(async () => {
          throw new Error("the disk is full");
        }),
      },
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
      410,
      "gone",
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
      408,
      "request_timeout",
      "network",
      true,
      "report.csv could not be retrieved. The network or service may be unavailable; try again shortly.",
    ],
    [
      429,
      "rate_limited",
      "network",
      true,
      "report.csv could not be retrieved. The network or service may be unavailable; try again shortly.",
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
      const api = createCommaApi({
        baseUrl: "https://comma.example",
        token: "test-token",
        fetch: vi.fn(
          async () =>
            new Response(JSON.stringify({ error }), {
              status: httpStatus,
              headers: { "content-type": "application/json" },
            })
        ),
      });
      renderToasts();

      await expect(
        runDownload({
          fileName: "report.csv",
          resolve: () => api.fetchConversationAttachment("grp_1", "cnv_1", "msg_1", 1),
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
    ).resolves.toEqual({ status: "success" });

    expect(createObjectUrl).toHaveBeenCalledWith(blob);
    expect(clickAnchor).toHaveBeenCalledOnce();
    const anchor = clickAnchor.mock.instances[0] as HTMLAnchorElement;
    expect(anchor.download).toBe("report.csv");
    expect(anchor.href).toBe("blob:saved-report");
    expect(anchor.isConnected).toBe(false);

    expect(await screen.findByText("Download complete")).toBeInTheDocument();
    // The browser owns the destination here, so the copy must not name one.
    expect(screen.getByText("report.csv was downloaded.")).toBeInTheDocument();
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
