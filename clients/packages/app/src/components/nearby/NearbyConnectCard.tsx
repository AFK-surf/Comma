import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { CheckIcon, CrossLargeIcon } from "@comma/ui/components/icons";
import { MeshAvatar } from "./MeshAvatar";

/** The person who picked this one in their nearby list. */
export interface NearbyPeer {
  name: string;
  /** What tells the person it is who they think: their account's email. */
  email: string;
}

/** `invited`: the other person picked this one and waits; `connected`: this one accepted. */
export type NearbyPhase = "invited" | "connected";

const initials = (name: string) =>
  name
    .split(" ")
    .slice(0, 2)
    .map((part) => part[0] ?? "")
    .join("")
    .toUpperCase();

/**
 * What comes up on this computer when someone nearby picks this person in their list: the Comma window is the
 * iPhone and this is the AirPods card. It rises from the window's bottom edge with the other person's face where
 * AirPods show their picture, one line and one action. Accepted, a check lands on the face.
 */
export function NearbyConnectCard({
  busy = false,
  oneWay = false,
  onAccept,
  onClose,
  onSendFirst,
  open,
  peer,
  phase,
}: {
  /** Connect is accepting: neither it nor closing can be pressed. */
  busy?: boolean;
  /** Connected only one way: this person may send them requests, not back (`reciprocal: false`). */
  oneWay?: boolean;
  open: boolean;
  phase: NearbyPhase;
  peer: NearbyPeer;
  onAccept: () => void;
  onSendFirst: () => void;
  onClose: () => void;
}) {
  const m = useCommaMessages();
  const connected = phase === "connected";
  const title = connected
    ? m.nearby_connected_title()
    : m.nearby_invited_title({ name: peer.name });
  return (
    <div className="comma-nearby" data-open={open || undefined} data-phase={phase}>
      <div aria-hidden="true" className="comma-nearby__veil" onClick={onClose} />
      <dialog aria-label={title} className="comma-nearby__card" open>
        <button
          aria-label={m.nearby_close()}
          className="comma-nearby__close"
          disabled={busy}
          onClick={onClose}
          type="button"
        >
          <CrossLargeIcon />
        </button>
        <div aria-hidden="true" className="comma-nearby__hero">
          <span className="comma-nearby__face">
            {open ? <MeshAvatar initials={initials(peer.name)} size={132} /> : null}
          </span>
          <span className="comma-nearby__check">
            <CheckIcon />
          </span>
        </div>
        <h2 className="comma-nearby__title">{title}</h2>
        <p className="comma-nearby__detail">
          {connected
            ? oneWay
              ? m.nearby_connected_subtitle_one_way({ name: peer.name })
              : m.nearby_connected_subtitle()
            : peer.email}
        </p>
        <Button
          className="comma-nearby__action"
          hierarchy="primary"
          isDisabled={busy}
          onPress={connected ? onSendFirst : onAccept}
          size="lg"
        >
          {connected ? m.nearby_send_first() : m.nearby_connect()}
        </Button>
      </dialog>
    </div>
  );
}
