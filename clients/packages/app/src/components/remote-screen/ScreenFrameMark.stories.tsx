import type { Meta, StoryObj } from "@storybook/react-vite";
import { useMemo } from "react";
import { fn } from "storybook/test";
import "../../styles.css";
import { ScreenFrameMark } from "./ScreenFrameMark";

/** A made-up app's screen: a list with one row that shows the error someone wants to ask about. */
function fakeFrame(): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = 1170;
  canvas.height = 2532;
  // (no 2D context in the stories' jsdom run: an empty frame, for the rendering test)
  const draw = canvas.getContext("2d");
  if (!draw) return canvas;
  draw.fillStyle = "#f7f7f8";
  draw.fillRect(0, 0, 1170, 2532);
  draw.fillStyle = "#1a1a1f";
  draw.font = "600 72px system-ui";
  draw.fillText("Orders", 80, 260);
  for (let row = 0; row < 7; row += 1) {
    const top = 340 + row * 300;
    draw.fillStyle = "#ffffff";
    draw.fillRect(60, top, 1050, 260);
    draw.fillStyle = "#1a1a1f";
    draw.font = "500 48px system-ui";
    draw.fillText(`Order ${1042 + row}`, 110, top + 100);
    draw.fillStyle = row === 2 ? "#d92d20" : "#6b6b73";
    draw.font = "400 40px system-ui";
    draw.fillText(
      row === 2 ? "Payment failed: try again" : "Delivered",
      110,
      top + 180
    );
  }
  return canvas;
}

function Harness({ width, height }: { width: number; height: number }) {
  const frame = useMemo(fakeFrame, []);
  return (
    <div
      className="comma-remote-screen-panel"
      data-state="live"
      style={{ width, height }}
    >
      <ScreenFrameMark frame={frame} onCancel={fn()} onAsk={fn()} top={0} />
    </div>
  );
}

const meta: Meta<typeof Harness> = {
  title: "App/Remote screen/Mark a frame",
  component: Harness,
  args: { width: 420, height: 720 },
};
export default meta;

export const Phone: StoryObj<typeof Harness> = {};
export const NarrowPanel: StoryObj<typeof Harness> = {
  args: { width: 240, height: 360 },
};
