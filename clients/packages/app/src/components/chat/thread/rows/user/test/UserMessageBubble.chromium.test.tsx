import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import { initializeCommaI18n } from "@comma/i18n";
import { cleanup, render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, beforeAll, expect, it } from "vitest";
import { commands } from "vitest/browser";
import { userMessageContentWithMentions } from "../../../inline/MessageInlineElements";
import { UserMessageBubble } from "../UserMessageBubble";

beforeAll(() => {
  initializeCommaI18n(["en"]);
});

// Unmount on the test clock: the bubble's resize observer stops with it.
afterEach(() => {
  cleanup();
  document.body.replaceChildren();
});

/** A picture of `clip` (frame pixels): the colour drawn at a pixel of the frame. */
async function picture(clip: { x: number; y: number; width: number; height: number }) {
  const image = new Image();
  image.src = `data:image/png;base64,${await commands.screenshot(clip)}`;
  await image.decode();
  const canvas = document.createElement("canvas");
  canvas.width = image.width;
  canvas.height = image.height;
  const context = canvas.getContext("2d")!;
  context.drawImage(image, 0, 0);
  const scale = image.width / clip.width;
  return (x: number, y: number) =>
    Array.from(
      context
        .getImageData(
          Math.floor((x - clip.x + 0.5) * scale),
          Math.floor((y - clip.y + 0.5) * scale),
          1,
          1
        )
        .data.slice(0, 3)
    );
}

/** How far apart two colours are, in their most different channel. */
function apart(a: number[], b: number[]) {
  return Math.max(...a.map((channel, index) => Math.abs(channel - b[index]!)));
}

it("draws the ring of a person's avatar that starts the message", async () => {
  const core = createScriptedCore();
  const view = render(
    core.wrap(
      // The bubble at the frame's start, so its text starts on a whole pixel.
      <div style={{ display: "flex" }}>
        <UserMessageBubble
          renderContent={(body) =>
            userMessageContentWithMentions(body, {
              groupId: "grp_1",
              workspaceId: "wsp_1",
            })
          }
          text="[CatsJuice](comma:request/trg_1) 看下 iOS 最新的包"
        />
      </div>
    )
  );
  const bubble = view.container
    .querySelector(".comma-chat-user-bubble")!
    .getBoundingClientRect();
  const avatar = view.container
    .querySelector(".comma-chat-user-mention-icon")!
    .getBoundingClientRect();
  const color = await picture({
    x: bubble.x,
    y: avatar.y,
    width: avatar.right + 1 - bubble.x,
    height: avatar.height,
  });
  const middle = avatar.y + avatar.height / 2;

  // The ring's pixel on the avatar's right stands out from the bubble; the one
  // on its left, at the text's edge, is drawn the same.
  const right = color(avatar.right, middle);
  expect(apart(right, color(bubble.x + 6, middle))).toBeGreaterThan(100);
  expect(apart(color(avatar.x - 1, middle), right)).toBeLessThan(16);
});
