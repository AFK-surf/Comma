import { uiClock } from "@comma/ui/clock";
import type { ScreenStreamInput } from "./screenStreamInput";

/** Sends the offer to the computer and returns its answer and the stream's id. */
export type ScreenStreamSignal = (
  offer: string,
  iceServers: RTCIceServer[]
) => Promise<{ sdp: string; stream: string }>;

export type ScreenStreamState = "connecting" | "live" | "failed";

export type ScreenStreamPeer = {
  /** Sends one input event; dropped until the channel opens. */
  send(input: ScreenStreamInput): void;
  close(): void;
};

// Candidates still missing after this long are left out of the offer.
const GATHER_MS = 2000;

/**
 * Opens a receive-only WebRTC view of a computer's screen. Signaling is one
 * exchange: the offer carries this side's candidates and the answer the
 * computer's. The `input` data channel carries pointer and keyboard events.
 */
export function openScreenStream(options: {
  /** The ICE servers for both peers; `signal` passes the same ones to the computer. */
  iceServers(): Promise<RTCIceServer[]>;
  signal: ScreenStreamSignal;
  onStream(stream: MediaStream): void;
  onState(state: ScreenStreamState): void;
  /** Runs once with the stream's id, so the owner can ask the computer to stop it. */
  onStarted(stream: string): void;
}): ScreenStreamPeer {
  let peer: RTCPeerConnection | undefined;
  let channel: RTCDataChannel | undefined;
  let closed = false;

  void (async () => {
    const iceServers = await options.iceServers();
    if (closed) return;
    const opened = new RTCPeerConnection({ iceServers });
    peer = opened;
    const receiver = opened.addTransceiver("video", { direction: "recvonly" }).receiver;
    // A screen is watched live: show each frame as it arrives.
    if ("jitterBufferTarget" in receiver) receiver.jitterBufferTarget = 0;
    channel = opened.createDataChannel("input");
    opened.ontrack = (event) =>
      options.onStream(event.streams[0] ?? new MediaStream([event.track]));
    opened.onconnectionstatechange = () => {
      if (closed) return;
      if (opened.connectionState === "connected") options.onState("live");
      else if (opened.connectionState === "failed") options.onState("failed");
    };

    await opened.setLocalDescription(await opened.createOffer());
    await gathered(opened);
    if (closed) return;
    const answer = await options.signal(opened.localDescription!.sdp, iceServers);
    options.onStarted(answer.stream);
    if (closed) return;
    await opened.setRemoteDescription({ type: "answer", sdp: answer.sdp });
  })().catch(() => {
    if (!closed) options.onState("failed");
  });

  return {
    send(input) {
      if (channel?.readyState === "open") channel.send(JSON.stringify(input));
    },
    close() {
      closed = true;
      peer?.close();
    },
  };
}

function gathered(peer: RTCPeerConnection): Promise<void> {
  if (peer.iceGatheringState === "complete") return Promise.resolve();
  return new Promise((resolve) => {
    const cancel = uiClock.after(GATHER_MS, done);
    function done() {
      cancel();
      peer.removeEventListener("icegatheringstatechange", check);
      resolve();
    }
    function check() {
      if (peer.iceGatheringState === "complete") done();
    }
    peer.addEventListener("icegatheringstatechange", check);
  });
}
