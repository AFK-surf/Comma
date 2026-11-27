import { CommaI18nProvider } from "@comma/i18n/react";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import jsQR from "jsqr";
import { afterEach, describe, expect, it } from "vitest";
import { page } from "vitest/browser";
import "@comma/app/styles.css";
import { TextShareImageDialog } from "../TextShareImageDialog";
import { shareCardQrRects } from "../renderShareCardCanvas";

describe("TextShareImageDialog (Chromium canvas & QR verification)", () => {
  afterEach(() => {
    cleanup();
  });

  it("renders a share card whose dotted iOS and Android store codes decode to the store links", async () => {
    await page.viewport(1280, 900);

    render(
      <CommaI18nProvider locale="zh-CN">
        <TextShareImageDialog
          isOpen
          onClose={() => {}}
          payload={{
            beforeContext: "提到，他的一些博士生很焦虑，担心 OpenAI 或 Anth",
            selectedText:
              "ropic 可能已经在内部做出了他们手里的题，却没有公开。可成果一公布，又往往会因为质量受到学界质疑。\n\n陶哲轩：理想情况下，科技公司应该在让机器自动生成证明之前，就和数学界合作。",
            afterContext:
              "完全不同。公司是在解数学题，可它们主要想做的是训练自己的模型。",
            beforeJoin: "inline",
            afterJoin: "inline",
            authorRole: "assistant",
          }}
          sourceTitle="整理陶哲轩访谈：AI 证明与数学界合作要点"
        />
      </CommaI18nProvider>
    );

    const canvas = (await screen.findByTestId(
      "text-share-image-canvas"
    )) as HTMLCanvasElement;
    expect(canvas.width).toBe(1320); // 440pt @ 3x
    expect(canvas.height).toBeGreaterThan(1200);

    const ctx = canvas.getContext("2d");
    expect(ctx).not.toBeNull();

    const scale = 3;
    const rects = shareCardQrRects(canvas.height / scale);
    const decode = (rect: { x: number; y: number; side: number }) => {
      // Four modules of quiet zone around the code, all inside the white plate.
      const pad = 6 * scale;
      const image = ctx!.getImageData(
        Math.round(rect.x * scale) - pad,
        Math.round(rect.y * scale) - pad,
        Math.round(rect.side * scale) + pad * 2,
        Math.round(rect.side * scale) + pad * 2
      );
      return jsQR(image.data, image.width, image.height)?.data;
    };

    await waitFor(() => {
      expect(decode(rects.ios)).toBe("https://apps.apple.com/app/id6817786267");
      expect(decode(rects.android)).toBe(
        "https://play.google.com/store/apps/details?id=surf.comma.android"
      );
    });
  });
});
