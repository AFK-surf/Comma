import { expect, it } from "vitest";
import { agentPointerPlace } from "../ScreenAgentPresence";

const video = (
  box: { left: number; top: number; width: number; height: number },
  picture: { width: number; height: number }
) => ({
  offsetLeft: box.left,
  offsetTop: box.top,
  clientWidth: box.width,
  clientHeight: box.height,
  videoWidth: picture.width,
  videoHeight: picture.height,
});

it("places an agent's press on the picture as it is fitted in its box, not on the bars beside it", () => {
  // A tall phone's picture in a wider box: it fills the height, with a bar each side.
  const shown = video(
    { left: 10, top: 20, width: 400, height: 600 },
    { width: 300, height: 600 }
  );
  expect(agentPointerPlace(shown, { x: 0, y: 0 })).toEqual({ left: 60, top: 20 });
  expect(agentPointerPlace(shown, { x: 0.5, y: 0.5 })).toEqual({ left: 210, top: 320 });
  expect(agentPointerPlace(shown, { x: 1, y: 1 })).toEqual({ left: 360, top: 620 });
});

it("has no place for it until the picture has a size", () => {
  expect(
    agentPointerPlace(
      video({ left: 0, top: 0, width: 400, height: 600 }, { width: 0, height: 0 }),
      { x: 0.5, y: 0.5 }
    )
  ).toBeNull();
});
