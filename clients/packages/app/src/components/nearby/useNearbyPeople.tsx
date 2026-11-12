import { useCall } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge, type NearbyState } from "@comma/native-bridge";
import { toast } from "@comma/ui/components/toast";
import { useEffect, useState, type ReactNode } from "react";
import { NearbyPeopleDialog, type NearbyPerson } from "./NearbyPeopleDialog";

/** “Ada’s Comma” is Ada; a name the person chose stays as it is. */
const owner = (airDropName: string) =>
  airDropName.replace(/’s Comma$/, "") || airDropName;

/**
 * Settings › Task requests › Add › Someone nearby (macOS). `open` shows the
 * list and scans for Comma nearby (`nearby.find`); picking someone makes an
 * invite for this workspace in the core and sends it to their Mac
 * (`nearby.ask`), whose connect card answers it. `available` is false where
 * this computer cannot look.
 */
export function useNearbyPeople(workspace: string | undefined): {
  available: boolean;
  open: () => void;
  dialog: ReactNode;
} {
  const bridge = getNativeBridge();
  const call = useCall();
  const m = useCommaMessages();
  const [state, setState] = useState<NearbyState | null>(null);
  const [isOpen, setOpen] = useState(false);

  useEffect(() => {
    if (bridge.platform !== "electron") return;
    return bridge.nearby.state.subscribe((snapshot) =>
      setState((current) =>
        current && current.revision > snapshot.revision ? current : snapshot
      )
    );
  }, [bridge]);

  if (!state?.available || !workspace)
    return { available: false, open: () => undefined, dialog: null };

  const people: NearbyPerson[] = state.peers.map((peer) => {
    const ask = state.asks.find((candidate) => candidate.peerId === peer.id);
    return {
      id: peer.id,
      name: owner(peer.name),
      via: peer.via,
      status:
        ask?.status === "asking"
          ? "asking"
          : ask?.status === "accepted"
            ? "connected"
            : ask?.status === "unanswered"
              ? "unanswered"
              : "idle",
    };
  });
  const find = () => void bridge.nearby.find().catch(() => undefined);
  const pick = (peerId: string) => {
    call("taskRequests.createInvite", { workspace, mode: "review" })
      .then(({ inviteUrl }) => bridge.nearby.ask({ inviteUrl, peerId }))
      .catch(() => toast.error(m.task_requests_failed()));
  };

  return {
    available: true,
    open: () => {
      setOpen(true);
      find();
    },
    dialog: (
      <NearbyPeopleDialog
        isOpen={isOpen}
        onClose={() => setOpen(false)}
        onPick={pick}
        onRescan={find}
        people={people}
        scan={state.scan}
      />
    ),
  };
}
