import type { Meta, StoryObj } from "@storybook/react-vite";
import { useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import "../../../styles.css";
import { ScreenDeviceButtons } from "../ScreenDeviceFrame";
import DuoStage, { type DuoStageHandle } from "./DuoStage";
import {
  duoModelTurn,
  type DuoPoint,
  type DuoPosture,
  type DuoPostureId,
} from "./duoScreens";

// The six postures as the core lists them (clients/packages/core/src/screen-postures.ts).
const POSTURES: readonly DuoPosture[] = [
  {
    id: "coverPortrait",
    screen: "cover",
    opening: 0,
    stand: "upright",
    orientation: 0,
    pose: "closed",
  },
  {
    id: "coverLandscape",
    screen: "cover",
    opening: 0,
    stand: "upright",
    orientation: 90,
    pose: "closed",
  },
  {
    id: "tent",
    screen: "cover",
    opening: 75,
    stand: "tent",
    orientation: 90,
    pose: "closed",
  },
  {
    id: "laptop",
    screen: "inner",
    opening: 105,
    stand: "laptop",
    orientation: 0,
    pose: "open",
  },
  {
    id: "innerLandscape",
    screen: "inner",
    opening: 180,
    stand: "upright",
    orientation: 90,
    pose: "open",
  },
  {
    id: "innerPortrait",
    screen: "inner",
    opening: 180,
    stand: "upright",
    orientation: 0,
    pose: "open",
  },
];

/**
 * What the simulator sends for a screen turned so: an upright picture (for the viewer) whose corners, top and centre
 * say which way it lies on the model, and a dot where the last press landed.
 */
function drawPattern(
  canvas: HTMLCanvasElement,
  posture: DuoPosture,
  pressed: DuoPoint | undefined
) {
  const [short, long] = posture.screen === "cover" ? [1398, 2034] : [2007, 2853];
  const wide = posture.orientation === 90;
  canvas.width = wide ? long : short;
  canvas.height = wide ? short : long;
  const draw = canvas.getContext("2d");
  if (!draw) return;
  const { width, height } = canvas;
  const sky = draw.createLinearGradient(0, 0, 0, height);
  sky.addColorStop(0, "#2b6cf0");
  sky.addColorStop(1, "#7c3aed");
  draw.fillStyle = sky;
  draw.fillRect(0, 0, width, height);
  draw.strokeStyle = "rgba(255,255,255,0.25)";
  draw.lineWidth = 4;
  for (let x = 0; x <= width; x += 200) draw.strokeRect(x, 0, 0, height);
  for (let y = 0; y <= height; y += 200) draw.strokeRect(0, y, width, 0);
  const corner = 260;
  const corners: [number, number, string][] = [
    [0, 0, "#ef4444"],
    [width - corner, 0, "#22c55e"],
    [0, height - corner, "#3b82f6"],
    [width - corner, height - corner, "#facc15"],
  ];
  for (const [x, y, color] of corners) {
    draw.fillStyle = color;
    draw.fillRect(x, y, corner, corner);
  }
  draw.fillStyle = "#ffffff";
  draw.textAlign = "center";
  draw.textBaseline = "middle";
  draw.font = "700 180px system-ui";
  draw.fillText("TOP ↑", width / 2, 240);
  draw.font = "600 120px system-ui";
  draw.fillText(`${posture.screen} · ${posture.orientation}°`, width / 2, height / 2);
  draw.font = "500 90px system-ui";
  draw.fillText(posture.id, width / 2, height / 2 + 160);
  if (pressed) {
    draw.fillStyle = "#ffffff";
    draw.beginPath();
    draw.arc(pressed.x * width, pressed.y * height, 60, 0, Math.PI * 2);
    draw.fill();
  }
}

function Harness({ start, controls }: { start: DuoPostureId; controls: boolean }) {
  const [id, setId] = useState<DuoPostureId>(start);
  const [pressed, setPressed] = useState<DuoPoint>();
  const [version, setVersion] = useState(0);
  const posture = POSTURES.find((one) => one.id === id)!;
  const canvas = useMemo(() => document.createElement("canvas"), []);
  const source = useRef<HTMLCanvasElement | null>(canvas);
  const handle = useRef<DuoStageHandle>(null);
  useLayoutEffect(() => {
    drawPattern(canvas, posture, pressed);
    setVersion((was) => was + 1);
  }, [canvas, posture, pressed]);
  return (
    <div
      className="comma-remote-screen-stage"
      data-device
      style={
        {
          height: "100vh",
          background: "var(--color-main-panel-bg)",
          // (the panel's, which sizes the device's buttons and the room kept for them)
          "--comma-remote-screen-button": "var(--spacing-4xl)",
        } as CSSProperties
      }
    >
      <div className="comma-remote-screen-device-area">
        <div className="comma-remote-screen-duo" data-lays="wide" data-posture={id}>
          <div
            className="comma-remote-screen-duo-input"
            data-testid="duo-input"
            onPointerDown={(event) =>
              setPressed(handle.current?.pick(event.clientX, event.clientY))
            }
          >
            <DuoStage
              handle={handle}
              modelTurn={duoModelTurn(posture, posture.orientation)}
              pictureTurn={posture.orientation}
              posture={posture}
              screen={posture.screen}
              source={source}
              sourceVersion={version}
            />
          </div>
          {controls ? (
            <ScreenDeviceButtons
              actions={[]}
              macos
              onAction={() => undefined}
              placement="bottom"
              postures={{ list: POSTURES, shown: id, onChoose: setId }}
            />
          ) : null}
        </div>
      </div>
      <output
        data-testid="duo-pressed"
        style={{ position: "absolute", top: 8, left: 8, font: "12px monospace" }}
      >
        {pressed ? `${pressed.x.toFixed(3)}, ${pressed.y.toFixed(3)}` : "—"}
      </output>
    </div>
  );
}

const meta = {
  title: "Remote screen/iPhone Duo (3D)",
  component: Harness,
  // (WebGL: drawn in a browser to look at, not run as a test)
  tags: ["!test"],
  parameters: { layout: "fullscreen" },
  args: { start: "coverPortrait", controls: true },
} satisfies Meta<typeof Harness>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Interactive: Story = {};
export const CoverPortrait: Story = {
  args: { start: "coverPortrait", controls: false },
};
export const CoverLandscape: Story = {
  args: { start: "coverLandscape", controls: false },
};
export const Tent: Story = { args: { start: "tent", controls: false } };
export const Laptop: Story = { args: { start: "laptop", controls: false } };
export const InnerLandscape: Story = {
  args: { start: "innerLandscape", controls: false },
};
export const InnerPortrait: Story = {
  args: { start: "innerPortrait", controls: false },
};
