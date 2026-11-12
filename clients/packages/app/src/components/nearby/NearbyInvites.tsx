import { useCall } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge, type NearbyState } from "@comma/native-bridge";
import { uiClock } from "@comma/ui/clock";
import { toast } from "@comma/ui/components/toast";
import { useEffect, useRef, useState } from "react";
import { useWorkspacePreference } from "../activeWorkspace";
import {
  NearbyConnectCard,
  type NearbyPeer,
  type NearbyPhase,
} from "./NearbyConnectCard";

type Offer = NearbyState["offers"][number];

/** Whose invite an offer is and what accepting it here gives them, as `taskRequests.invitePreview` reads it. */
interface Read {
  requestId: string;
  peer: NearbyPeer;
  /** The workspace accepting it in lets them send back to; absent, they cannot. */
  back: string | undefined;
}

/**
 * The connect card for an invite someone nearby sent this Mac over AirDrop
 * (`nearby` in Main). The card shows whose invite it is once the core read it;
 * Connect accepts it in the core, then answers the held offer, so the sender's
 * row turns connected. Closing the card declines the offer.
 */
export function NearbyInvites() {
  const bridge = getNativeBridge();
  const isDesktop = bridge.platform === "electron";
  const call = useCall();
  const m = useCommaMessages();
  const [state, setState] = useState<NearbyState | null>(null);
  const [read, setRead] = useState<Read>();
  /** Who accepting connected, and whether they can send back (`reciprocal`). */
  const [connected, setConnected] = useState<{
    peer: NearbyPeer;
    reciprocal: boolean;
  }>();
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!isDesktop) return;
    return bridge.nearby.state.subscribe((snapshot) =>
      setState((current) =>
        current && current.revision > snapshot.revision ? current : snapshot
      )
    );
  }, [bridge, isDesktop]);

  const offer: Offer | undefined = state?.offers.find(
    (candidate) =>
      candidate.surfaceId === undefined || candidate.surfaceId === bridge.self.windowId
  );
  const offerId = offer?.requestId;
  // The workspace is read only while an offer waits, so a window without one asks the core nothing.
  const prefer = useWorkspacePreference(offerId !== undefined);
  const invite = offer?.invite;
  const senderName = offer?.senderName;

  useEffect(() => {
    if (!offerId || !invite || prefer === undefined) return undefined;
    let live = true;
    call("taskRequests.invitePreview", {
      invite,
      ...(prefer ? { workspace: prefer } : {}),
    }).then(
      (from) => {
        if (!live) return;
        // Their own invite comes back from another of their Macs: nothing to connect.
        if (from.own) {
          void bridge.nearby.answer({ accept: false, requestId: offerId });
          return;
        }
        const owner = from.workspace.owner;
        setRead({
          requestId: offerId,
          peer: {
            name:
              owner?.name || owner?.email || from.workspace.name || senderName || "",
            email: owner?.email ?? "",
          },
          back: from.back?.workspace.id,
        });
      },
      () => {
        if (live) void bridge.nearby.answer({ accept: false, requestId: offerId });
      }
    );
    return () => {
      live = false;
    };
  }, [bridge, call, invite, offerId, prefer, senderName]);

  const shown = read && read.requestId === offerId ? read : undefined;
  const accept = () => {
    if (!shown || !invite || busy) return;
    setBusy(true);
    call("taskRequests.acceptInvite", {
      invite,
      ...(shown.back ? { workspace: shown.back } : {}),
    })
      .then(
        ({ reciprocal }) => {
          setConnected({ peer: shown.peer, reciprocal });
          return bridge.nearby.answer({ accept: true, requestId: shown.requestId });
        },
        () => {
          toast.error(m.task_requests_failed());
          return bridge.nearby.answer({ accept: false, requestId: shown.requestId });
        }
      )
      .catch(() => undefined)
      .finally(() => setBusy(false));
  };
  const close = () => {
    // While Connect is accepting, its answer is the offer's; closing waits for it.
    if (busy) return;
    if (connected) setConnected(undefined);
    else if (shown)
      void bridge.nearby
        .answer({ accept: false, requestId: shown.requestId })
        .catch(() => undefined);
  };

  const peer = connected?.peer ?? shown?.peer;
  // The card rises a frame after it mounts and sinks with the last person on it.
  const last = useRef<{ peer: NearbyPeer; phase: NearbyPhase; oneWay: boolean }>(
    undefined
  );
  if (peer)
    last.current = {
      peer,
      phase: connected ? "connected" : "invited",
      oneWay: connected?.reciprocal === false,
    };
  const [open, setOpen] = useState(false);
  const present = peer !== undefined;
  useEffect(() => {
    if (!present) {
      setOpen(false);
      return undefined;
    }
    return uiClock.frame(() => setOpen(true));
  }, [present]);
  if (!last.current) return null;
  return (
    <NearbyConnectCard
      busy={busy}
      oneWay={last.current.oneWay}
      onAccept={accept}
      onClose={close}
      onSendFirst={() => {
        setConnected(undefined);
        window.location.hash = "/settings?category=task-requests";
      }}
      open={open && present}
      peer={last.current.peer}
      phase={last.current.phase}
    />
  );
}
