import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { CheckIcon } from "@comma/ui/components/icons";
import type { CSSProperties } from "react";

/** Someone nearby who has Comma open and can be connected with. */
export interface NearbyPerson {
  id: string;
  /** The name their Comma shows nearby. */
  name: string;
  /** Found over AirDrop, right beside this Mac, or on the same Wi-Fi. */
  via: "airdrop" | "wifi";
  /**
   * `idle` until picked; `asking` once picked, until they answer; `connected` once they accept; `unanswered` when
   * they declined or did not answer, and can be asked again.
   */
  status: "idle" | "asking" | "connected" | "unanswered";
}

const initials = (name: string) =>
  name
    .split(" ")
    .slice(0, 2)
    .map((part) => part[0] ?? "")
    .join("")
    .toUpperCase();

/**
 * Settings › Task requests › Add someone nearby: the people near this computer with Comma open, as they are
 * found. Picking one asks them: their computer shows the connect card, and the row waits until they accept.
 */
export function NearbyPeopleDialog({
  isOpen,
  onClose,
  onPick,
  onRescan,
  people,
  scan,
}: {
  isOpen: boolean;
  people: readonly NearbyPerson[];
  /** Main's scan: the list says it looks while `scanning`, and offers to look again after. */
  scan: "idle" | "scanning" | "done" | "failed";
  onPick: (id: string) => void;
  onRescan: () => void;
  onClose: () => void;
}) {
  const m = useCommaMessages();
  return (
    <Dialog
      actions={[
        // Look again sits beside Done once a scan found people; with no one found it is the empty state's action.
        ...(scan !== "scanning" && people.length
          ? [
              {
                label: m.nearby_dialog_rescan(),
                hierarchy: "secondary-gray" as const,
                onPress: onRescan,
                // Esc is Done's.
                shortcut: false as const,
              },
            ]
          : []),
        { label: m.nearby_done(), hierarchy: "secondary-gray", onPress: onClose },
      ]}
      description={m.nearby_dialog_description()}
      isDismissable
      isOpen={isOpen}
      onOpenChange={(open) => !open && onClose()}
      title={m.nearby_dialog_title()}
    >
      <div className="comma-nearby-list">
        {scan === "scanning" ? (
          <p className="comma-nearby-list__scan">
            <span aria-hidden="true" className="comma-nearby-list__radar" />
            {m.nearby_dialog_scanning()}
          </p>
        ) : people.length ? null : (
          <div className="comma-nearby-list__empty">
            <p>{m.nearby_dialog_empty()}</p>
            <Button hierarchy="secondary-gray" onPress={onRescan} size="sm">
              {m.nearby_dialog_rescan()}
            </Button>
          </div>
        )}
        <ul aria-live="polite" className="comma-nearby-list__rows">
          {people.map((person, i) => (
            <li
              className="comma-nearby-list__row"
              data-status={person.status}
              key={person.id}
              style={{ "--nearby-row": i } as CSSProperties}
            >
              <span aria-hidden="true" className="comma-nearby-list__face">
                {initials(person.name)}
              </span>
              <span className="comma-nearby-list__who">
                <span className="comma-nearby-list__name">{person.name}</span>
                <span className="comma-nearby-list__email">
                  {person.status === "asking"
                    ? m.nearby_dialog_waiting()
                    : person.status === "connected"
                      ? m.nearby_connected_title()
                      : person.status === "unanswered"
                        ? m.nearby_dialog_unanswered()
                        : person.via === "wifi"
                          ? m.nearby_dialog_same_wifi()
                          : m.nearby_dialog_nearby()}
                </span>
              </span>
              {person.status === "connected" ? (
                <span className="comma-nearby-list__done">
                  <CheckIcon />
                </span>
              ) : (
                <Button
                  hierarchy="secondary-gray"
                  isDisabled={person.status === "asking"}
                  onPress={() => onPick(person.id)}
                  size="sm"
                >
                  {m.nearby_connect()}
                </Button>
              )}
            </li>
          ))}
        </ul>
      </div>
    </Dialog>
  );
}
