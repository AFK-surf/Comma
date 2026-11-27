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

/**
 * Where reading an invite stands: `reading` until the core has read whose it is (Connect waits), `unreadable` when it
 * could not (the card only closes). Absent: read.
 */
export type NearbyInviteRead = "reading" | "unreadable";

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
  read,
}: {
  /** Connect is accepting: neither it nor closing can be pressed. */
  busy?: boolean;
  /** Connected only one way: this person may send them requests, not back (`reciprocal: false`). */
  oneWay?: boolean;
  open: boolean;
  phase: NearbyPhase;
  peer: NearbyPeer;
  read?: NearbyInviteRead | undefined;
  onAccept: () => void;
  onSendFirst: () => void;
  onClose: () => void;
}) {
  const m = useCommaMessages();
  const connected = phase === "connected";
  const unreadable = !connected && read === "unreadable";
  const title = connected
    ? m.nearby_connected_title()
    : peer.name
      ? m.nearby_invited_title({ name: peer.name })
      : // The sender's computer gave no name and the invite is not read yet.
        m.nearby_invited_title_unnamed();
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
        <p className="comma-nearby__detail" data-error={unreadable || undefined}>
          {connected
            ? oneWay
              ? m.nearby_connected_subtitle_one_way({ name: peer.name })
              : m.nearby_connected_subtitle()
            : unreadable
              ? m.nearby_invite_unreadable()
              : // The line keeps its height while the invite is read.
                peer.email || "\u00a0"}
        </p>
        <Button
          className="comma-nearby__action"
          hierarchy={unreadable ? "secondary-gray" : "primary"}
          isDisabled={busy || (!connected && read === "reading")}
          onPress={connected ? onSendFirst : unreadable ? onClose : onAccept}
          size="lg"
        >
          {connected
            ? m.nearby_send_first()
            : unreadable
              ? m.nearby_close()
              : m.nearby_connect()}
        </Button>
      </dialog>
    </div>
  );
}
