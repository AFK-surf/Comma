/**
 * @vitest-environment jsdom
 */
import { CommaI18nProvider } from "@comma/i18n/react";
import { render, screen, waitFor } from "@comma/test-utils/render";
import { toast } from "@comma/ui/components/toast";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { downloadFile } from "../../../../runtime-files/fileDownloads";
import { copyImageBlob } from "../../../../runtime-files/imageClipboard";
import { resolveShareCardFontFamily } from "../renderShareCardCanvas";
import { TextShareImageDialog } from "../TextShareImageDialog";

vi.mock("../../../../runtime-files/fileDownloads", () => ({
  downloadFile: vi.fn().mockResolvedValue({ status: "success" }),
}));

vi.mock("../../../../runtime-files/imageClipboard", () => ({
  copyImageBlob: vi.fn().mockResolvedValue(undefined),
}));

function renderDialog(
  props: Parameters<typeof TextShareImageDialog>[0],
  locale: "en" | "zh-CN" = "zh-CN"
) {
  return render(
    <CommaI18nProvider locale={locale}>
      <TextShareImageDialog {...props} />
    </CommaI18nProvider>
  );
}

describe("TextShareImageDialog", () => {
  beforeEach(() => {
    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue(null);
    vi.spyOn(HTMLCanvasElement.prototype, "toBlob").mockImplementation((cb) => {
      cb(new Blob(["png-bytes"], { type: "image/png" }));
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("renders a single Swiss share card for normal selections and saves/copies PNG", async () => {
    const user = userEvent.setup();
    renderDialog({
      isOpen: true,
      onClose: vi.fn(),
      sourceTitle: "陶哲轩访谈笔记",
      payload: {
        beforeContext: "提到，他的一些博士生很焦虑，担心 OpenAI 或 Anth",
        selectedText: "ropic 可能已经在内部做出了他们手里的题，却没有公开。",
        afterContext: "完全不同。公司是在解数学题。",
        beforeJoin: "inline",
        afterJoin: "inline",
        authorRole: "assistant",
      },
    });

    expect(await screen.findByTestId("text-share-image-dialog")).toBeInTheDocument();
    expect(screen.queryByTestId("text-share-length-bar")).not.toBeInTheDocument();
    expect(screen.queryByTestId("text-share-export-size")).not.toBeInTheDocument();
    expect(screen.getByTestId("text-share-image-canvas")).toBeInTheDocument();

    const toastSuccess = vi.spyOn(toast, "success");

    await user.click(screen.getByTestId("text-share-save-btn"));
    await waitFor(() => expect(downloadFile).toHaveBeenCalledTimes(1));

    await user.click(screen.getByTestId("text-share-copy-btn"));
    await waitFor(() => expect(copyImageBlob).toHaveBeenCalledTimes(1));
    await waitFor(() =>
      expect(toastSuccess).toHaveBeenCalledWith("已复制图片", {
        id: "share-image-copied",
        testId: "share-image-copied",
      })
    );
  });

  it("handles 10,000-character selections with excerpt cap and paginated multi-card mode", async () => {
    const user = userEvent.setup();
    const tenThousand = "国际主义平面设计强调网格秩序、清晰层级与客观信息传达。".repeat(
      400
    );

    renderDialog({
      isOpen: true,
      onClose: vi.fn(),
      sourceTitle: "长文测试",
      payload: {
        beforeContext: "前文背景内容",
        selectedText: tenThousand,
        afterContext: "后文补充内容",
        beforeJoin: "paragraph",
        afterJoin: "paragraph",
        authorRole: "assistant",
      },
    });

    expect(await screen.findByTestId("text-share-length-bar")).toBeInTheDocument();
    expect(screen.getByTestId("text-share-length-notice")).toHaveTextContent(
      "已按单图上限节选"
    );

    await user.click(screen.getByTestId("text-share-mode-pages"));
    expect(await screen.findByTestId("text-share-pager")).toBeInTheDocument();
    expect(screen.getByTestId("text-share-page-indicator")).toHaveTextContent(
      "01 / 09"
    );

    await user.click(screen.getByRole("button", { name: "下一张" }));
    expect(screen.getByTestId("text-share-page-indicator")).toHaveTextContent(
      "02 / 09"
    );

    await user.click(screen.getByTestId("text-share-save-all-btn"));
    await waitFor(() => expect(downloadFile).toHaveBeenCalledTimes(9));
  });

  it("follows Comma client font-family overrides on documentElement", () => {
    const root = document.createElement("html");
    expect(resolveShareCardFontFamily(root)).toContain("Inter Variable");

    root.dataset.commaFontFamily = "Noto Serif CJK SC";
    expect(resolveShareCardFontFamily(root)).toMatch(/^"Noto Serif CJK SC", /);

    root.style.setProperty("--font-sans", '"LXGW WenKai", sans-serif');
    expect(resolveShareCardFontFamily(root)).toBe('"LXGW WenKai", sans-serif');
  });
});
