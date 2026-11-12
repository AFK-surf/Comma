import { act, cleanup, fireEvent, render } from "@comma/test-utils/render";
import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { afterEach, expect, it } from "vitest";
import { useScreenDeviceStanding } from "../useScreenDeviceStanding";
import { fakeDeviceCapabilities, fakePhone } from "./fakeScreenDevice";

const capabilities = fakeDeviceCapabilities(fakePhone);
let child: Window | null = null;

afterEach(() => {
  cleanup();
  child?.close();
  child = null;
});

function TurningScreen({ stream }: { stream: MediaStream }) {
  const video = useRef<HTMLVideoElement>(null);
  const still = useRef<HTMLCanvasElement>(null);
  const [ratio, setRatio] = useState<number>();
  const { holdForTurn } = useScreenDeviceStanding({
    capabilities,
    pictureRatio: ratio,
    reported: 0,
    video,
    still,
  });
  useEffect(() => {
    video.current!.srcObject = stream;
  }, [stream]);
  return (
    <div>
      <video
        autoPlay
        muted
        onLoadedMetadata={() =>
          setRatio(video.current!.videoWidth / video.current!.videoHeight)
        }
        ref={video}
      />
      <canvas ref={still} />
      <button onClick={holdForTurn} type="button">
        Rotate
      </button>
    </div>
  );
}

it.each(["main", "child"] as const)(
  "keeps the decoded picture visible while a device turns in the %s window",
  async (where) => {
    const picture = document.createElement("canvas");
    picture.width = 390;
    picture.height = 840;
    const draw = picture.getContext("2d")!;
    draw.fillStyle = "#205bff";
    draw.fillRect(0, 0, picture.width, picture.height);
    const stream = picture.captureStream(0);
    if (where === "child")
      child = window.open("about:blank", "screen-turn-test", "popup");
    const own = where === "child" ? child!.document : document;
    render(createPortal(<TurningScreen stream={stream} />, own.body));
    const video = own.querySelector("video")!;
    try {
      await new Promise<void>((resolve) => {
        video.requestVideoFrameCallback(() => resolve());
        draw.fillRect(0, 0, picture.width, picture.height);
        (stream.getVideoTracks()[0] as CanvasCaptureMediaStreamTrack).requestFrame();
      });
      await act(async () => undefined);
      const decoded = document.createElement("canvas");
      decoded.width = video.videoWidth;
      decoded.height = video.videoHeight;
      const sample = decoded.getContext("2d")!;
      sample.drawImage(video, 0, 0);
      const expectedPixel = [...sample.getImageData(195, 420, 1, 1).data];
      expect(expectedPixel[3]).toBe(255);
      fireEvent.click(own.querySelector("button")!);
      const held = own.querySelector("canvas")!;
      expect([held.width, held.height]).toEqual([picture.width, picture.height]);
      expect([...held.getContext("2d")!.getImageData(195, 420, 1, 1).data]).toEqual(
        expectedPixel
      );
    } finally {
      stream.getTracks().forEach((track) => track.stop());
    }
  }
);
