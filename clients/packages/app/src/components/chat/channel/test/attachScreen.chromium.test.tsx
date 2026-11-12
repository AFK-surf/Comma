import { isPictureOf, sharedScreenFileName } from "@comma/core/chat";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { getNativeBridge } from "@comma/native-bridge";
import { expect, it } from "vitest";
import { testProductLease } from "../../../../test/productInboxProjectionHarness";
import { CoreConversationChannel } from "../CoreConversationChannel";

/** A frame too large for the server as a PNG: noise does not compress. */
async function noisyPng(side: number) {
  const canvas = new OffscreenCanvas(side, side);
  const context = canvas.getContext("2d")!;
  const pixels = context.createImageData(side, side);
  let seed = 17;
  for (let i = 0; i < pixels.data.length; i += 4) {
    for (let c = 0; c < 3; c++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      pixels.data[i + c] = seed >>> 24;
    }
    pixels.data[i + 3] = 255;
  }
  context.putImageData(pixels, 0, 0);
  return canvas.convertToBlob({ type: "image/png" });
}

it("hands the core a frame made to fit with the type it now is, which the core names it by", async () => {
  installNativeBridgeMock({
    platform: "web",
    self: { role: "main-window", windowId: "win_main" },
  });
  const core = createScriptedCore({
    values: () => undefined,
    calls: () => ({ revision: 1 }),
  });
  const channel = new CoreConversationChannel({
    bridge: getNativeBridge(),
    client: core.client,
    conversationId: "cnv_1",
    groupId: "grp_1",
    locale: "en",
    session: testProductLease,
    workspaceId: "wsp_1",
  });
  channel.start();
  const png = await noisyPng(2500);
  expect(png.size).toBeGreaterThan(10_000_000);

  await channel.attachScreen({ device: "mac", screen: "display", picture: png });

  const [sent] = core.sentTo("chatView.attachScreen") as {
    picture: Uint8Array;
    pictureType: "image/png" | "image/jpeg" | "image/webp";
  }[];
  // An opaque frame too large as a PNG goes as a JPEG, said so, and readable as one.
  expect(sent!.pictureType).toBe("image/jpeg");
  expect(Array.from(sent!.picture.subarray(0, 3))).toEqual([0xff, 0xd8, 0xff]);
  expect(sent!.picture.byteLength).toBeLessThanOrEqual(10_000_000);
  expect(isPictureOf(sent!.picture, sent!.pictureType)).toBe(true);
  expect(sharedScreenFileName(0, sent!.pictureType)).toMatch(/\.jpg$/);
  const bitmap = await createImageBitmap(
    new Blob([new Uint8Array(sent!.picture)], { type: sent!.pictureType })
  );
  expect(bitmap.width).toBeGreaterThan(0);
  channel.stop();
});
